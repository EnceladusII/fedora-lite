#!/usr/bin/env bash
set -euo pipefail
# AI dev stack (userland only): CUDA toolkit, ROCm userland, OpenCL loader/outils.
# NOTE: Les pilotes (drivers) sont gérés par un autre script. Ici on installe uniquement les libs/outils userspace.

. "$(dirname "$0")/00_helpers.sh"

# ---- helpers ----
is_ostree() { command -v rpm-ostree >/dev/null 2>&1; }
in_container() { [[ -f /.dockerenv ]] || grep -qaE 'container|toolbox' /proc/1/environ 2>/dev/null; }
need_dnf_plugins() { as_root "dnf -y install dnf-plugins-core"; }

# Vérification d’installation de paquets
ensure_pkg() {
  local pkgs=("$@")
  for p in "${pkgs[@]}"; do
    echo "[INFO] Installing $p"
    as_root "dnf -y install $p || true"
    if rpm -q "$p" >/dev/null 2>&1; then
      echo "[OK] $p installé"
    else
      echo "[FAIL] $p non installé (peut ne pas exister pour cette version Fedora)"
    fi
  done
}

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

# ---- guards ----
if is_ostree; then
  echo "[ERROR] rpm-ostree détecté (Silverblue/Kinoite). Utilise 'rpm-ostree install'. Abandon."; exit 1
fi
if in_container; then
  echo "[INFO] Container/Toolbox détecté: OK pour libs userland; pas de pilotes ici (normal)."
fi
need_dnf_plugins

# ---- GPU detection ----
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
ensure_pkg OpenCL-ICD-Loader OpenCL-ICD-Loader-devel clinfo opencl-headers

# ---- CUDA toolkit ----
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
  rpm -q cuda-toolkit cuda >/dev/null 2>&1 && echo "[OK] CUDA toolkit installé" || echo "[WARN] CUDA toolkit non trouvé"
}
install_cuda_rpmfusion() {
  echo "[INFO] CUDA toolkit (RPM Fusion)"
  ensure_rpmfusion
  ensure_pkg cuda-toolkit cuda
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

# ---- ROCm userland ----
install_rocm_amd_repo() {
  echo "[INFO] ROCm (AMD upstream; Fedora variable)"
  ensure_pkg rocminfo rocm-smi rocm-opencl rocm-opencl-runtime hip-runtime-amd hip-devel rocblas rocrand miopen-hip
}
install_rocm_copr() {
  echo "[INFO] ROCm (COPR; suppose un COPR déjà activé)"
  ensure_pkg rocminfo rocm-smi rocm-opencl rocm-opencl-runtime hip-runtime-amd hip-devel
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

# ---- Intel runtimes ----
if [[ "$gpu" == "intel" ]]; then
  echo "[INFO] Intel GPU: runtimes Level Zero / OpenCL"
  ensure_pkg level-zero intel-level-zero-gpu intel-compute-runtime mesa-libOpenCL intel-ocloc
fi

# ---- /etc/profile.d exports ----
echo "[INFO] /etc/profile.d/ai-env.sh"
as_root "bash -lc '
cat >/etc/profile.d/ai-env.sh <<EOF
# AI toolchain env (generated; drivers non requis)
[ -d /usr/local/cuda ] && export CUDA_PATH=/usr/local/cuda && export PATH=\$CUDA_PATH/bin:\$PATH && export LD_LIBRARY_PATH=\${LD_LIBRARY_PATH:+\$LD_LIBRARY_PATH:}\$CUDA_PATH/lib64
[ -d /opt/rocm ] && export ROCM_PATH=/opt/rocm && export HIP_PATH=/opt/rocm && export PATH=\$ROCM_PATH/bin:\$PATH && export LD_LIBRARY_PATH=\${LD_LIBRARY_PATH:+\$LD_LIBRARY_PATH:}\$ROCM_PATH/lib
EOF
chmod 0644 /etc/profile.d/ai-env.sh
'"

# ---- Sanity checks ----
echo "[INFO] clinfo (top 30 lignes):"
as_root "command -v clinfo >/dev/null 2>&1 && clinfo | head -n 30 || echo '[INFO] clinfo indisponible'"

echo "[INFO] ICD OpenCL présents:"
as_root "bash -lc '
  shopt -s nullglob
  files=(/etc/OpenCL/vendors/*.icd)
  if (( \${#files[@]} > 0 )); then
    printf \"%s\n\" \"\${files[@]}\"
  else
    echo \"(aucun)\"
  fi
'"

# ---- Post-validation: clinfo doit voir des plateformes ----
platforms=0
if command -v clinfo >/dev/null 2>&1; then
  platforms="$(clinfo 2>/dev/null | awk -F: \"/Number of platforms/ {gsub(/ /,\\\"\\\", \$2); print \$2; exit}\" || echo 0)"
fi

if [[ "$platforms" -eq 0 ]]; then
  echo "[WARN] OpenCL installé mais aucune plateforme détectée."
  case "$gpu" in
    amd)
      echo "  -> Installe ROCm userland (rocm-opencl, rocm-opencl-runtime) et active le driver AMDGPU/ROCr."
      ;;
    nvidia)
      echo "  -> Installe le driver NVIDIA (xorg-x11-drv-nvidia-cuda via RPM Fusion) pour obtenir nvidia.icd."
      ;;
    intel)
      echo "  -> Assure-toi d'avoir intel-compute-runtime ou mesa-libOpenCL (Rusticl)."
      ;;
    *)
      echo "  -> Pas de GPU détecté : normal qu'aucune plateforme ne soit visible."
      ;;
  esac
else
  echo "[OK] OpenCL plateformes détectées: $platforms"
fi

echo "[OK] AI userland installé (best-effort). Drivers gérés par ton autre script."
