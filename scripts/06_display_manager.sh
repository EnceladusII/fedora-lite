#!/usr/bin/env bash
set -euo pipefail
# Install and enable Ly (from source: https://github.com/fairyglade/ly)
# Works as user; uses as_root for privileged steps.

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set}"
UHOME="$(user_home "$TARGET_USER")"
BUILD_DIR="$UHOME/.local/src/ly"

echo "[INFO] Installing build dependencies for Ly"
# Minimal set known to be needed; xorg-xauth helps X/Wayland sessions auth
as_root "dnf -y install kernel-devel pam-devel libxcb-devel zig xorg-x11-xauth xorg-x11-server-common brightnessctl"

# Clone or update source as the target user
if [[ -d "$BUILD_DIR/.git" ]]; then
  echo "[INFO] Updating Ly source in $BUILD_DIR"
  as_user "git -C '$BUILD_DIR' fetch --all --prune && git -C '$BUILD_DIR' checkout master && git -C '$BUILD_DIR' pull --ff-only"
else
  echo "[INFO] Cloning Ly into $BUILD_DIR"
  as_user "mkdir -p '$(dirname "$BUILD_DIR")'"
  as_user "git clone https://github.com/fairyglade/ly.git '$BUILD_DIR'"
fi

# Build as user
echo "[INFO] Building Ly"
as_user "cd ~/.local/src/ly && zig build"

# Install binaries and systemd service as root
echo "[INFO] Installing Ly (binaries + systemd unit)"
as_root "cd ~/.local/src/ly && zig build installexe -Dinit_system=systemdl"

# Deploy config if provided in repo
if [[ -f "$ROOT_DIR/config/ly/config.ini" ]]; then
  echo "[INFO] Installing /etc/ly/config.ini from project config"
  as_root "mkdir -p /etc/ly"
  as_root "install -m 0644 '$ROOT_DIR/config/ly/config.ini' /etc/ly/config.ini"
fi

# Switch DM: disable GDM, enable Ly
echo "[INFO] Enabling Ly and disabling GDM"
disable_service gdm.service
enable_service ly.service

# Ensure we boot to graphical target
as_root "systemctl set-default graphical.target"

# Sanity checks
echo "[INFO] Verifying installation"
as_root "test -f /usr/bin/ly && echo ' - ly binary OK' || echo ' - ly binary MISSING'"
as_root "systemctl status ly.service --no-pager -l || true"
as_root "test -f /etc/pam.d/ly && echo ' - PAM config OK' || echo ' - PAM config MISSING (install target should have created it)'"

echo "[OK] Ly installed from source and enabled as Display Manager."
