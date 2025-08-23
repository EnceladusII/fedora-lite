#!/usr/bin/env bash
set -euo pipefail
# Install AI stack: CUDA (NVIDIA), ROCm (AMD), and OpenCL ICDs/tools.
# Runs as user; uses as_root for system actions. Best-effort per distro state.

. "$(dirname "$0")/00_helpers.sh"

detect_gpu() {
  if [[ "${GPU:-auto}" != "auto" ]]; then
    echo "$GPU"; return
  fi
  if lspci | grep -qi nvidia; then
    echo nvidia
  elif lspci | grep -qi 'amd/ati'; then
    echo amd
  elif lspci | grep -qi 'intel corporation.*graphics'; then
    echo intel
  else
    echo unknown
  fi
}

gpu="$(detect_gpu)"
echo "[INFO] AI stack: detected GPU = $gpu"
echo "[INFO] CUDA: INSTALL_CUDA=${INSTALL_CUDA:-1} via ${CUDA_REPO:-official} | ROCm: INSTALL_ROCM=${INSTALL_ROCM:-1} via ${ROCM_REPO:-amd}"

# --- Common: OpenCL ICD loader + tools ---
echo "[INFO] Installing OpenCL ICD loader + clinfo"
as_root "dnf -y install ocl-icd clinfo || true"

# --- NVIDIA: CUDA Toolkit (optional) ---
install_cuda_official() {
  echo "[INFO] Installing CUDA (official NVIDIA repo)"
  as_root "bash -lc '
    set -euo pipefail
    ver=\$(rpm -E %fedora)
    # Add NVIDIA CUDA repo (pattern used by NVIDIA; may change across releases)
    repo_url=\"https://developer.download.nvidia.com/compute/cuda/repos/fedora\${ver}/x86_64/cuda-fedora\${ver}.repo\"
    if curl -fsSL \"\$repo_url\" >/dev/null; then
      dnf -y config-manager --add-repo \"\$repo_url\"
      dnf -y install cuda-toolkit || dnf -y install cuda || true
    else
      echo \"[WARN] CUDA repo URL not found for Fedora \$ver. Skipping official CUDA.\" >&2
      exit 0
    fi
  '"
}

install_cuda_rpmfusion() {
  echo "[INFO] Installing CUDA (RPMFusion)"
  # CUDA runtime libs often come with NVIDIA driver pkgs; toolkit may be cuda-toolkit
  as_root "dnf -y install cuda-toolkit || dnf -y install cuda || true"
}

if [[ "$gpu" == "nvidia" && "${INSTALL_CUDA:-1}" == "1" ]]; then
  case "${CUDA_REPO:-official}" in
    official)  install_cuda_official ;;
    rpmfusion) install_cuda_rpmfusion ;;
    skip)      echo "[INFO] Skipping CUDA per .env";;
    *)         echo "[WARN] Unknown CUDA_REPO='${CUDA_REPO}'. Skipping CUDA.";;
  esac
else
  echo "[INFO] CUDA not requested or not on NVIDIA."
fi

# --- AMD: ROCm (optional/best-effort on Fedora) ---
install_rocm_amd_repo() {
  echo "[INFO] Installing ROCm (AMD upstream repo; availability varies on Fedora)"
  as_root "bash -lc '
    set -euo pipefail
    # AMD’s official repos primarily target RHEL/UBI/Ubuntu; Fedora support may be limited.
    # Try common meta packages; fail softly if not present.
    dnf -y install rocminfo rocm-smi || true
    dnf -y install rocm-opencl rocm-opencl-runtime || true
    dnf -y install hip-runtime-amd hip-devel || true
    dnf -y install rocblas rocrand miopen-hip || true
  '"
}

install_rocm_copr() {
  echo "[INFO] Installing ROCm (COPR path; ensure you enabled a suitable COPR in lists/coprs.txt)"
  # We assume the COPR (e.g., a ROCm community build) is already enabled at step 4.
  as_root "dnf -y install rocminfo rocm-smi rocm-opencl rocm-opencl-runtime hip-runtime-amd hip-devel || true"
}

if [[ "$gpu" == "amd" && "${INSTALL_ROCM:-1}" == "1" ]]; then
  case "${ROCM_REPO:-amd}" in
    amd)  install_rocm_amd_repo ;;
    copr) install_rocm_copr ;;
    skip) echo "[INFO] Skipping ROCm per .env" ;;
    *)    echo "[WARN] Unknown ROCM_REPO='${ROCM_REPO}'. Skipping ROCm." ;;
  esac
else
  echo "[INFO] ROCm not requested or not on AMD."
fi

# --- Intel note (no CUDA/ROCm) ---
if [[ "$gpu" == "intel" ]]; then
  echo "[INFO] Intel GPU: consider Level Zero / oneAPI (not installed here)."
fi

# --- Post-install sanity checks ---
echo "[INFO] Running quick sanity checks"
as_root "which clinfo >/dev/null 2>&1 && clinfo | head -n 20 || true"

if [[ "$gpu" == "nvidia" && "${INSTALL_CUDA:-1}" == "1" ]]; then
  as_root "command -v nvcc >/dev/null 2>&1 && nvcc --version || echo '[INFO] nvcc not found (toolkit may be libs-only or install failed softly)'"
fi
if [[ "$gpu" == "amd" && "${INSTALL_ROCM:-1}" == "1" ]]; then
  as_root "command -v rocminfo >/dev/null 2>&1 && rocminfo | head -n 20 || echo '[INFO] rocminfo not available (packages may be missing on Fedora release)'"
fi

echo "[OK] AI stack step completed (best-effort). Review warnings above if any package was unavailable for your Fedora release."
