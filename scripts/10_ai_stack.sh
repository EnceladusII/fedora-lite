#!/usr/bin/env bash
set -euo pipefail
# AI dev stack (userland only): CUDA toolkit, ROCm userland, OpenCL loader/tools.
# NOTE: Drivers are handled by a separate script; we only install userland libs here.

. "$(dirname "$0")/00_helpers.sh"

# ---- guards/help ----
is_ostree() { command -v rpm-ostree >/dev/null 2>&1; }
in_container() { [[ -f /.dockerenv ]] || grep -qaE 'container|toolbox' /proc/1/environ 2>/dev/null; }
run() { if [[ "${DRY_RUN:-0}" == "1" ]]; then echo "+ $*"; else eval "$@"; fi; }
need_dnf_plugins() { as_root "dnf -y install dnf-plugins-core || true"; }
ensure_rpmfusion() {
  as_root "bash -lc '
    set -euo pipefail
    if ! dnf repolist | grep -qi rpmfusion; then
      ver=\$(rpm -E %fedora)
      dnf -y install \
        https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-\${ver}.noarch.rpm \
        https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-\${ver}.noarch.rpm || true
    fi
  '"
}

if is_ostree; then
  echo "[ERROR] rpm-ostree détecté (Silverblue/Kinoite). Utilise 'rpm-ostree install' ou un conteneur. Abandon."; exit 1
fi
if in_container; then
  echo "[INFO] Container/Toolbox détecté: OK pour libs userland; pas de pilotes ici (normal)."
fi
need_dnf_plugins

# ---- GPU detection (pas de pilote ici) ----
detect_gpu() {
  if [[ "${GPU:-auto}" != "auto" ]]; then echo "$GPU"; return; fi
  if lspci | grep -qi nvidia; then echo nvidia
  elif lspci | grep -qi 'amd/ati'; then echo amd
  elif lspci | grep -qi 'intel corporation.*graphics'; then echo intel
  else echo unknown
  fi
}
gpu="$(detect_gpu)"
echo "[INFO] GPU détecté = $gpu"
echo "[INFO] CUDA via ${CUDA_REPO:-official} (INSTALL_CUDA=${INSTALL_CUDA:-1}) | ROCm via ${ROCM_REPO:-amd} (INSTALL_ROCM=${INSTALL_ROCM:-1})"

# ---- OpenCL ICD loader + headers ----
echo "[INFO] OpenCL ICD loader + tools + headers"
as_root "dnf -y install ocl-icd clinfo opencl-headers ocl-icd-devel || true"

# ---- CUDA toolkit (sans pilote) ----
install_cuda_official() {
  echo "[INFO] CUDA toolkit (repo NVIDIA officiel)"
  as_root "bash -lc '
    set -euo pipefail
    ver=\$(rpm -E %fedora)
    repo_url=\"https://developer.download.nvidia.com/compute/cuda/repos/fedora\${ver}/x86_64/cuda-fedora\${ver}.repo\"
    if curl -fsSL \"\$repo_url\" >/dev/null; then
      dnf -y config-manager --add-repo \"\$repo_url\"
      rpm --import https://developer.download.nvidia.com/compute/cuda/repos/fedora\${ver}/x86_64/D42D0685.pub || true
      dnf -y install cuda-toolkit || dnf -y install cuda || true
    else
      echo \"[WARN] Pas de repo CUDA pour Fedora \${ver}.\" >&2
      exit 2
    fi
  '"
}
install_cuda_rpmfusion() {
  echo "[INFO] CUDA toolkit (RPM Fusion)"
  ensure_rpmfusion
  as_root "dnf -y install cuda-toolkit || dnf -y install cuda || true"
}
if [[ "$gpu" == "nvidia" && "${INSTALL_CUDA:-1}" == "1" ]]; then
  case "${CUDA_REPO:-official}" in
    official)  install_cuda_official || install_cuda_rpmfusion ;;
    rpmfusion) install_cuda_rpmfusion ;;
    skip)      echo "[INFO] CUDA ignoré (env)";;
    *)         echo "[WARN] CUDA_REPO='${CUDA_REPO}' inconnu. Skip.";;
  esac
else
  echo "[INFO] CUDA non demandé ou GPU ≠ NVIDIA."
fi

# ---- ROCm userland (sans pilote) ----
install_rocm_amd_repo() {
  echo "[INFO] ROCm (AMD upstream; Fedora variable)"
  as_root "bash -lc '
    set -euo pipefail
    dnf -y install rocminfo rocm-smi || true
    dnf -y install rocm-opencl rocm-opencl-runtime || true
    dnf -y install hip-runtime-amd hip-devel || true
    dnf -y install rocblas rocrand miopen-hip || true
  '"
}
install_rocm_copr() {
  echo "[INFO] ROCm (COPR; suppose un COPR déjà activé)"
  as_root "dnf -y install rocminfo rocm-smi rocm-opencl rocm-opencl-runtime hip-runtime-amd hip-devel || true"
}
if [[ "$gpu" == "amd" && "${INSTALL_ROCM:-1}" == "1" ]]; then
  case "${ROCM_REPO:-amd}" in
    amd)  install_rocm_amd_repo ;;
    copr) install_rocm_copr ;;
    skip) echo "[INFO] ROCm ignoré (env)";;
    *)    echo "[WARN] ROCM_REPO='${ROCM_REPO}' inconnu. Skip.";;
  esac
else
  echo "[INFO] ROCm non demandé ou GPU ≠ AMD."
fi

# ---- Intel userland (OpenCL/Level Zero) ----
if [[ "$gpu" == "intel" ]]; then
  echo "[INFO] Intel GPU: runtimes Level Zero / OpenCL (best-effort)"
  # On tente plusieurs noms de paquets Fedora connus; tout est best-effort.
  as_root "dnf -y install level-zero intel-level-zero-gpu intel-compute-runtime ocl-icd || true"
  as_root "dnf -y install intel-ocloc || true"
fi

# ---- /etc/profile.d exports (non-intrusif, safe si les dossiers existent) ----
echo "[INFO] /etc/profile.d/ai-env.sh"
as_root "bash -lc '
cat >/etc/profile.d/ai-env.sh <<EOF
# AI toolchain env (generated; drivers non requis)
[ -d /usr/local/cuda ] && export CUDA_PATH=/usr/local/cuda && export PATH=\$CUDA_PATH/bin:\$PATH && export LD_LIBRARY_PATH=\${LD_LIBRARY_PATH:+\$LD_LIBRARY_PATH:}\$CUDA_PATH/lib64
[ -d /opt/rocm ] && export ROCM_PATH=/opt/rocm && export HIP_PATH=/opt/rocm && export PATH=\$ROCM_PATH/bin:\$PATH && export LD_LIBRARY_PATH=\${LD_LIBRARY_PATH:+\$LD_LIBRARY_PATH:}\$ROCM_PATH/lib
EOF
chmod 0644 /etc/profile.d/ai-env.sh
'"

# ---- Sanity checks (n'échouent pas si drivers pas encore posés) ----
echo "[INFO] clinfo (top 30 lignes):"
as_root "command -v clinfo >/dev/null 2>&1 && clinfo | head -n 30 || echo '[INFO] clinfo indisponible'"

echo "[INFO] ICD OpenCL présents:"
as_root "bash -lc 'ls -1 /etc/OpenCL/vendors/*.icd 2>/dev/null || echo (aucun)'"

if [[ "$gpu" == "nvidia" && "${INSTALL_CUDA:-1}" == "1" ]]; then
  as_root "command -v nvcc >/dev/null 2>&1 && nvcc --version || echo '[INFO] nvcc non trouvé (toolkit absent/libre), ou PATH non source'"
  as_root "command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi || echo '[INFO] nvidia-smi indisponible (pilote posé ailleurs ou non chargé — OK)'"
fi
if [[ "$gpu" == "amd" && "${INSTALL_ROCM:-1}" == "1" ]]; then
  as_root "command -v rocminfo >/dev/null 2>&1 && rocminfo | head -n 20 || echo '[INFO] rocminfo indisponible (pilote ROCr non actif — OK)'"
  as_root "command -v rocm-smi >/dev/null 2>&1 && rocm-smi || echo '[INFO] rocm-smi indisponible (pilote posé ailleurs — OK)'"
  as_root "command -v hipcc >/dev/null 2>&1 && hipcc --version || true"
fi

echo "[OK] AI userland installé (best-effort). Les drivers seront gérés par ton autre script."
