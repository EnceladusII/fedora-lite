#!/usr/bin/env bash
set -euo pipefail
# Step 6 — Switch from gdm to Ly (Zig build)

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set}"
: "${ROOT_DIR:?ROOT_DIR must be set}"

echo "[INFO] Switching to Ly Display Manager"
echo "[INFO] TARGET_USER=${TARGET_USER}"

# 1) Disable others DMs (gdm or greetd)
echo "[INFO] Disabling conflicting display managers…"
disable_service gdm.service || true
as_root "systemctl disable --now greetd.service" || true
as_root "dnf -y remove greetd tuigreet" || true

# 2) Installing dependencies
echo "[INFO] Installing build/runtime dependencies…"
as_root "dnf -y install kernel-devel pam-devel libxcb-devel zig xorg-x11-xauth xorg-x11-server-common brightnessctl"

# Verify Zig (Ly need 0.14.x)
if command -v zig >/dev/null 2>&1; then
  ZIG_VER="$(zig version || true)"
  case "${ZIG_VER}" in
    0.14.*) echo "[INFO] Zig ${ZIG_VER} OK";;
    *) echo "[WARN] Expected Zig 0.14.x, found ${ZIG_VER}. Build may fail.";;
  esac
else
  echo "[ERROR] zig not found after installation."
  exit 1
fi

# 3) Clone and Build Ly
REPO_URL="${REPO_URL:-https://codeberg.org/fairyglade/ly.git}"
BUILD_DIR="${BUILD_DIR:-/tmp/ly}"

if [[ ! -d ${BUILD_DIR} ]]; then
  echo "[INFO] Cloning Ly into ${BUILD_DIR}…"
  git clone "${REPO_URL}" "${BUILD_DIR}"
else
  echo "[INFO] Updating Ly in ${BUILD_DIR}…"
  git -C "${BUILD_DIR}" fetch --all
  git -C "${BUILD_DIR}" reset --hard origin/master
fi

echo "[INFO] Building Ly with Zig as regular user…"
( cd "${BUILD_DIR}" && zig build -Doptimize=ReleaseFast )

# 4) Installing Ly (systemd)
echo "[INFO] Installing Ly (systemd)…"
( cd "${BUILD_DIR}" && as_root "zig build installexe -Dinit_system=systemd" )

# 5) Déployer conf depuis le repo
echo "[INFO] Deploying Ly config + PAM…"
as_root "install -D -m 0644 '${ROOT_DIR}/config/ly/config.ini' /etc/ly/config.ini"
as_root "install -D -m 0644 '${ROOT_DIR}/config/pam.d/ly'      /etc/pam.d/ly"

# Optional autologin
if grep -q "__TARGET_USER__" "${ROOT_DIR}/config/ly/config.ini"; then
  as_root "sed -i 's/__TARGET_USER__/${TARGET_USER}/g' /etc/ly/config.ini"
fi

# 6) Hyprland session fallback if unavailable
if ! test -f /usr/share/wayland-sessions/hyprland.desktop; then
  echo "[INFO] Installing fallback Hyprland session file…"
  as_root "install -D -m 0644 '${ROOT_DIR}/config/wayland-sessions/hyprland.desktop' \
    /usr/share/wayland-sessions/hyprland.desktop"
fi

# 7) SELinux (pam.d)
echo "[INFO] Restoring SELinux contexts…"
as_root "restorecon -RF /etc/ly /etc/pam.d/ly /usr/share/wayland-sessions || true"

# 8) tty2 by default → disable getty@tty2
echo "[INFO] Disabling getty@tty2.service (Ly runs on tty2)…"
as_root "systemctl disable --now getty@tty2.service" || true

# 9) Enable Ly + graphical target
echo "[INFO] Enabling Ly…"
as_root "systemctl enable ly.service"
as_root "systemctl set-default graphical.target"

cat <<'EOF'

[OK] Ly is installed and enabled.
- Reboot to start Ly, or: sudo systemctl start ly.service
- If SELinux blocks, create a tiny policy from logs:
    sudo ausearch -m avc -ts recent | audit2allow -M ly-local
    sudo semodule -i ly-local.pp
- Logs: journalctl -u ly -b -e
EOF
