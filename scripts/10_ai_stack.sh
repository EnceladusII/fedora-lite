#!/usr/bin/env bash
set -euo pipefail
# AI dev stack (userland only): CUDA toolkit, ROCm userland, OpenCL loader/tools.
# NOTE: Drivers are managed by another script. Here we only install userland libs/tools.

. "$(dirname "$0")/00_helpers.sh"

# ---- helpers ----
is_ostree() { command -v rpm-ostree >/dev/null 2>&1; }
in_container() { [[ -f /.dockerenv ]] || grep -qaE 'container|toolbox' /proc/1/environ 2>/dev/null; }
need_dnf_plugins() { as_root "dnf -y install dnf-plugins-core"; }

# Package installation with verification
ensure_pkg() {
  local pkgs=("$@")
  for p in "${pkgs[@]}"; do
    echo "[INFO] Installing $p"
    as_root "dnf -y install $p || true"
    if rpm -q "$p" >/dev/null 2>&1; then
      echo "[OK] $p installed"
    else
      echo "[FAIL] $p not installed (may not exist for this Fedora release)"
    fi
  done
}

ensure_rpmfusion() {
  as_root "sh -lc '
    set -eu
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
  echo "[ERROR] rpm-ostree detected (Silverblue/Kinoite). Use 'rpm-ostree install'. Aborting."; exit 1
fi
if in_container; then
  echo "[INFO] Container/Toolbox detected: userland libs will be installed, drivers skipped (normal)."
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
echo "[INFO] Detected GPU = $gpu"
echo "[INFO] CUDA via ${CUDA_REPO:-official} (INSTALL_CUDA=${INSTALL_CUDA:-1}) | ROCm via ${ROCM_REPO:-amd} (INSTALL_ROCM=${INSTALL_ROCM:-1})"

# ---- OpenCL ICD loader + headers ----
ensure_pkg OpenCL-ICD-Loader OpenCL-ICD-Loader-devel clinfo opencl-headers

# ---- CUDA toolkit ----
install_cuda_official() {
  echo "[INFO] CUDA toolkit (NVIDIA official repo)"
  as_root "sh -lc '
    set -eu
    ver=\$(rpm -E %fedora)
    repo_url=\"https://developer.download.nvidia.com/compute/cuda/repos/fedora\${ver}/x86_64/cuda-fedora\${ver}.repo\"
    if curl -fsSL \"\$repo_url\" >/dev/null; then
      dnf -y config-manager --add-repo \"\$repo_url\"
      rpm --import https://developer.download.nvidia.com/compute/cuda/repos/fedora\${ver}/x86_64/D42D0685.pub || true
      dnf -y install cuda-toolkit || dnf -y install cuda || true
    else
      echo \"[WARN] No CUDA repo for Fedora \${ver}.\" >&2
      exit 2
    fi
  '"
  rpm -q cuda-toolkit cuda >/dev/null 2>&1 && echo "[OK] CUDA toolkit installed" || echo "[WARN] CUDA toolkit not found"
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
    skip)      echo "[INFO] CUDA skipped (env)";;
    *)         echo "[WARN] Unknown CUDA_REPO='${CUDA_REPO}'. Skipping.";;
  esac
else
  echo "[INFO] CUDA not requested or GPU ≠ NVIDIA."
fi

# ---- ROCm userland ----
install_rocm_amd_repo() {
  echo "[INFO] ROCm (AMD upstream; Fedora support varies)"
  ensure_pkg rocminfo rocm-smi rocm-opencl rocm-opencl-runtime hip-runtime-amd hip-devel rocblas rocrand miopen-hip
}
install_rocm_copr() {
  echo "[INFO] ROCm (COPR; assumes COPR already enabled)"
  ensure_pkg rocminfo rocm-smi rocm-opencl rocm-opencl-runtime hip-runtime-amd hip-devel
}
if [[ "$gpu" == "amd" && "${INSTALL_ROCM:-1}" == "1" ]]; then
  case "${ROCM_REPO:-amd}" in
    amd)  install_rocm_amd_repo ;;
    copr) install_rocm_copr ;;
    skip) echo "[INFO] ROCm skipped (env)";;
    *)    echo "[WARN] Unknown ROCM_REPO='${ROCM_REPO}'. Skipping.";;
  esac
else
  echo "[INFO] ROCm not requested or GPU ≠ AMD."
fi

# ---- Intel runtimes ----
if [[ "$gpu" == "intel" ]]; then
  echo "[INFO] Intel GPU: Level Zero / OpenCL runtimes"
  ensure_pkg level-zero intel-level-zero-gpu intel-compute-runtime mesa-libOpenCL intel-ocloc
fi

# ---- /etc/profile.d exports ----
echo "[INFO] Writing /etc/profile.d/ai-env.sh"
as_root "sh -lc '
cat >/etc/profile.d/ai-env.sh <<EOF
# AI toolchain env (generated; no drivers required)
[ -d /usr/local/cuda ] && export CUDA_PATH=/usr/local/cuda && export PATH=\$CUDA_PATH/bin:\$PATH && export LD_LIBRARY_PATH=\${LD_LIBRARY_PATH:+\$LD_LIBRARY_PATH:}\$CUDA_PATH/lib64
[ -d /opt/rocm ] && export ROCM_PATH=/opt/rocm && export HIP_PATH=/opt/rocm && export PATH=\$ROCM_PATH/bin:\$PATH && export LD_LIBRARY_PATH=\${LD_LIBRARY_PATH:+\$LD_LIBRARY_PATH:}\$ROCM_PATH/lib
EOF
chmod 0644 /etc/profile.d/ai-env.sh
'"

# ---- Sanity checks ----
echo "[INFO] clinfo (top 30 lines):"
as_root "sh -lc 'command -v clinfo >/dev/null 2>&1 && clinfo | head -n 30 || echo \"[INFO] clinfo not available\"'"

echo "[INFO] Installed OpenCL ICD files:"
as_root "sh -lc '
  set -- /etc/OpenCL/vendors/*.icd
  if [ -e \"\$1\" ]; then
    for f in \"\$@\"; do printf \"%s\n\" \"\$f\"; done
  else
    echo \"(none)\"
  fi
'"

# ---- Post-validation: check if clinfo detects platforms ----
platforms=0
if command -v clinfo >/dev/null 2>&1; then
  platforms="$(clinfo 2>/dev/null | awk -F: '/Number of platforms/ {gsub(/ /,"",$2); print $2; exit}' || echo 0)"
fi

if [[ "$platforms" -eq 0 ]]; then
  echo "[WARN] OpenCL installed but no platform detected."
  case "$gpu" in
    amd)
      echo "  -> Install ROCm userland (rocm-opencl, rocm-opencl-runtime) and ensure AMDGPU/ROCr driver is active."
      ;;
    nvidia)
      echo "  -> Install NVIDIA driver (xorg-x11-drv-nvidia-cuda from RPM Fusion) to get nvidia.icd."
      ;;
    intel)
      echo "  -> Ensure intel-compute-runtime or mesa-libOpenCL (Rusticl) is installed."
      ;;
    *)
      echo "  -> No GPU detected: expected that no platforms are visible."
      ;;
  esac
else
  echo "[OK] OpenCL platforms detected: $platforms"
fi

echo "[OK] AI userland installed (best-effort). Drivers are handled by your other script."
