#!/usr/bin/env bash
set -euo pipefail

# --- Root dir of project ---
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Load environment variables from .env if present ---
if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a
else
  # Defaults (fallback if .env not present)
  GPU="${GPU:-auto}"
  DM="${DM:-greetd}"
  TARGET_USER="${TARGET_USER:-$SUDO_USER}"
  DEFAULT_SHELL="${DEFAULT_SHELL:-bash}"
  TERMINAL="${TERMINAL:-foot}"

  INSTALL_DEV="${INSTALL_DEV:-1}"
  INSTALL_GAMING="${INSTALL_GAMING:-1}"
  REMOVE_PLYMOUTH="${REMOVE_PLYMOUTH:-0}"

  NVIDIA_USE_AKMOD="${NVIDIA_USE_AKMOD:-1}"
  NVIDIA_ALLOW_WL="${NVIDIA_ALLOW_WL:-1}"

  INSTALL_CUDA="${INSTALL_CUDA:-1}"
  CUDA_REPO="${CUDA_REPO:-official}"
  INSTALL_ROCM="${INSTALL_ROCM:-1}"
  ROCM_REPO="${ROCM_REPO:-amd}"
  INSTALL_OPENGL_DEV="${INSTALL_OPENGL_DEV:-1}"

  DOTS_REPO="${DOTS_REPO:-}"
  DOTS_BRANCH="${DOTS_BRANCH:-main}"
  DOTS_SETUP_SCRIPT="${DOTS_SETUP_SCRIPT:-install.fish}"
fi

# --- Helpers ---
die() { echo "ERROR: $*" >&2; exit 1; }

# Deprecated: prefer as_root inside scripts instead of running whole script as root
need_root() { [[ $EUID -eq 0 ]] || die "Run as root (use sudo)."; }

# Ensure sudo exists (most Fedora installs have it, but just in case)
ensure_sudo() { command -v sudo >/dev/null 2>&1 || die "sudo not found. Install sudo first."; }
ensure_sudo

# Run a command with root privileges (keeps user's env as needed)
as_root() {
  # use a login-like shell so PATH for root is sane; -lc preserves quoting
  sudo bash -lc "$*"
}

# Get home directory of a given user
user_home() {
  local u="${1:?user}"
  getent passwd "$u" | cut -d: -f6
}

# Run command as target user (non-root)
as_user() {
  local u="${TARGET_USER:?}"
  sudo -H -u "$u" bash -lc "$*"
}

# Detect GRUB config path (EFI vs BIOS)
detect_grub_cfg() {
  if [[ -d /sys/firmware/efi ]]; then
    echo "/boot/efi/EFI/fedora/grub.cfg"
  else
    echo "/boot/grub2/grub.cfg"
  fi
}

# Check if rpm package is installed
pkg_installed() { rpm -q "$1" &>/dev/null; }

# Enable/disable services safely (root required)
enable_service() { as_root "systemctl enable --now '$1' 2>/dev/null || true"; }
disable_service() { as_root "systemctl disable --now '$1' 2>/dev/null || true"; }
enable_service_reboot() { as_root "systemctl enable --now '$1' 2>/dev/null || true"; }
disable_service_reboot() { as_root "systemctl disable '$1' 2>/dev/null || true"; }

# Apply a list file (ignores comments and blanks)
apply_list() {
  local file="${1:?}"
  [[ -f "$file" ]] || return 0
  grep -E '^\s*[^#]' "$file" | sed 's/#.*//' | sed '/^\s*$/d'
}
