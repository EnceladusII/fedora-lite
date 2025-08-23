#!/usr/bin/env bash
set -euo pipefail
# Detect GPU and install appropriate drivers + Vulkan/OpenGL basics.
# Runs as normal user; uses as_root for system actions.

. "$(dirname "$0")/00_helpers.sh"

detect_gpu() {
  # respect .env override first
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
echo "[INFO] Detected GPU: $gpu"

# Common graphics stack (safe for all vendors)
as_root "dnf -y install mesa-dri-drivers mesa-vulkan-drivers vulkan-tools"

case "$gpu" in
  amd)
    # RADV (default) + AMD Vulkan
    #as_root "dnf -y install vulkan-radeon"
    ;;
  intel)
    as_root "dnf -y install intel-media-driver"
    ;;
  nvidia)
    # RPMFusion driver (akmods by default), Wayland-friendly KMS
    as_root "dnf -y install akmods kernel-devel || true"
    if [[ "${NVIDIA_USE_AKMOD:-1}" == "1" ]]; then
      as_root "dnf -y install xorg-x11-drv-nvidia xorg-x11-drv-nvidia-power xorg-x11-drv-nvidia-cuda || true"
      # Build akmod for current kernel (best-effort)
      as_root "akmods --force --kernels \$(uname -r) || true"
    else
      as_root "dnf -y install kmod-nvidia xorg-x11-drv-nvidia-cuda || true"
    fi

    if [[ "${NVIDIA_ALLOW_WL:-1}" == "1" ]]; then
      as_root "bash -lc 'mkdir -p /etc/modprobe.d;
        cat >/etc/modprobe.d/nvidia-kms.conf <<EOF
options nvidia-drm modeset=1
EOF
        dracut --force
      '"
    fi

    # Vulkan loader for NVIDIA
    as_root "dnf -y install vulkan"
    ;;
  *)
    echo "[WARN] Unknown GPU — installed generic Mesa/Vulkan only."
    ;;
esac

# Optional: dev headers for OpenGL if requested
if [[ "${INSTALL_OPENGL_DEV:-1}" == "1" ]]; then
  as_root "dnf -y install mesa-libGL-devel mesa-libEGL-devel mesa-libgbm-devel mesa-libGLU-devel \
                        libX11-devel libXext-devel libXrandr-devel libXrender-devel libXfixes-devel"
fi

echo "[OK] GPU driver base setup done for: $gpu"
echo "[HINT] For AI stacks (CUDA/ROCm), run: bash scripts/10_ai_stack.sh"
