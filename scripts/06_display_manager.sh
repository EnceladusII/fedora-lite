#!/usr/bin/env bash
set -euo pipefail
# Step 6 — Switch from greetd/tuigreet to Ly (Zig build)

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set}"
: "${ROOT_DIR:?ROOT_DIR must be set}"

echo "[INFO] Switching to Ly Display Manager"
echo "[INFO] TARGET_USER=${TARGET_USER}"

# 0) Root required
if [[ "$(id -u)" -ne 0 ]]; then
  echo "[ERROR] Please run via sudo (root required)."
  exit 1
fi

# 1) Disable other DMs + greetd/tuigreet
echo "[INFO] Disabling conflicting display managers…"
as root "systemctl disable_service gdm.service" || true
as_root "systemctl disable --now greetd.service" || true

echo "[INFO] Removing greetd/tuigreet packages if present…"
as_root "dnf -y remove greetd tuigreet" || true

# 2) Fedora dependencies (from upstream README)
echo "[INFO] Installing build/runtime dependencies…"
as_root "dnf -y install kernel-devel pam-devel libxcb-devel zig xorg-x11-xauth xorg-x11-server brightnessctl"

# Warn if Zig major.minor != 0.14 (Ly currently targets 0.14.x)
if command -v zig >/dev/null 2>&1; then
  ZIG_VER="$(zig version || true)"
  case "${ZIG_VER}" in
    0.14.*) echo "[INFO] Zig ${ZIG_VER} OK";;
    *) echo "[WARN] Expected Zig 0.14.x, found ${ZIG_VER}. Build may fail."; ;;
  esac
else
  echo "[ERROR] zig not found after installation."
  exit 1
fi

# 3) Build & install Ly (systemd)
REPO_URL="${REPO_URL:-https://codeberg.org/fairyglade/ly.git}"
BUILD_DIR="${BUILD_DIR:-/tmp/ly}"

if [[ ! -d ${BUILD_DIR} ]]; then
  echo "[INFO] Cloning Ly into ${BUILD_DIR}…"
  as_root "git clone '${REPO_URL}' '${BUILD_DIR}'"
else
  echo "[INFO] Updating Ly in ${BUILD_DIR}…"
  as_root "git -C '${BUILD_DIR}' fetch --all"
  as_root "git -C '${BUILD_DIR}' reset --hard origin/master"
fi

echo "[INFO] Building Ly with Zig…"
as_root "zig build -Doptimize=ReleaseFast -Dinit_system=systemd -fcolor --prefix /usr -C '${BUILD_DIR}'"

echo "[INFO] Installing Ly (systemd)…"
as_root "zig build installexe -Dinit_system=systemd -C '${BUILD_DIR}'"

# 4) Deploy configs from repo
echo "[INFO] Deploying Ly config + PAM…"
as_root "install -D -m 0644 '${ROOT_DIR}/config/ly/config.ini' /etc/ly/config.ini"
as_root "install -D -m 0644 '${ROOT_DIR}/config/pam.d/ly'      /etc/pam.d/ly"

# Optional autologin placeholder replacement
if grep -q "__TARGET_USER__" "${ROOT_DIR}/config/ly/config.ini"; then
  as_root "sed -i 's/__TARGET_USER__/${TARGET_USER}/g' /etc/ly/config.ini"
fi

# 5) Ensure Hyprland session entry exists (only if missing)
if ! test -f /usr/share/wayland-sessions/hyprland.desktop; then
  echo "[INFO] Installing fallback Hyprland session file…"
  as_root "install -D -m 0644 '${ROOT_DIR}/config/wayland-sessions/hyprland.desktop' \
    /usr/share/wayland-sessions/hyprland.desktop"
fi

# 6) SELinux contexts (recommended on Fedora)
echo "[INFO] Restoring SELinux contexts…"
as_root "restorecon -RF /etc/ly /etc/pam.d/ly /usr/share/wayland-sessions || true"

# 7) TTY handling: Ly defaults to TTY 2 — disable getty there
echo "[INFO] Disabling getty@tty2.service (Ly runs on tty2)…"
as_root "systemctl disable --now getty@tty2.service" || true

# 8) Enable Ly + graphical target
echo "[INFO] Enabling Ly…"
as_root "systemctl enable ly.service"
as_root "systemctl set-default graphical.target"

cat <<'EOF'

[OK] Ly is installed and enabled.
 - Reboot to start Ly, or: sudo systemctl start ly.service
 - If you hit SELinux issues, generate a policy from AVC logs:
     sudo ausearch -m avc -ts recent | audit2allow -M ly-local
     sudo semodule -i ly-local.pp
 - Logs: journalctl -u ly -b -e
EOF
