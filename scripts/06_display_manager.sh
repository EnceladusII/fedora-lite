#!/usr/bin/env bash
set -euo pipefail
# Install Ly v1.1.x (codebranch) using system Zig 0.14.x (Fedora 42)

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set}"
: "${ROOT_DIR:?ROOT_DIR must be set}"
: "${THEME:?Missing THEME in .env}"

echo "[INFO] Installing Ly v1.1.x with system Zig 0.14.x"
echo "[INFO] TARGET_USER=${TARGET_USER}"

# 0) Ensure deps (no portable Zig here)
echo "[INFO] Installing dependencies…"
as_root "dnf -y install git kbd kernel-devel pam-devel libxcb-devel xorg-x11-xauth xorg-x11-server-common brightnessctl zig curl file tar xz"

# 1) Enforce Zig 0.14.x
if ! command -v zig >/dev/null 2>&1; then
  echo "[ERROR] zig not found after installation."
  exit 1
fi
ZIG_VER="$(zig version || true)"
case "${ZIG_VER}" in
  0.14.*) echo "[INFO] Using Zig ${ZIG_VER} (OK for v1.1.x)";;
  *)
    echo "[ERROR] This installer is pinned to Zig 0.14.x, but found ${ZIG_VER}."
    echo "        Install Zig 0.14.x from Fedora repos (or set PATH) and re-run."
    exit 1
    ;;
esac

# 2) Stop other DMs (gdm/greetd)
echo "[INFO] Disabling conflicting display managers…"

is_graphical_session=0
if [[ -n "${XDG_SESSION_ID:-}" ]]; then
  # Si on est dans une session graphique (GNOME, etc.)
  if loginctl show-session "$XDG_SESSION_ID" -p Type -p Desktop 2>/dev/null | grep -qiE 'Type=wayland|Type=x11|Desktop=gnome|Desktop=plasma'; then
    is_graphical_session=1
  fi
fi

if (( is_graphical_session )); then
  echo "[INFO] Detected running graphical session; will not stop GDM now."
  disable_service_reboot gdm.service || true
else
  disable_service_reboot gdm.service || true
  disable_service greetd.service || true
fi

as_root "dnf -y remove greetd tuigreet" || true

# 3) Clone v1.1.x (Codeberg first, GitHub fallback)
REPO_CB="${REPO_CB:-https://codeberg.org/fairyglade/ly.git}"
REPO_GH="${REPO_GH:-https://github.com/fairyglade/ly.git}"
BUILD_DIR="${BUILD_DIR:-/tmp/ly}"
LY_REF="${LY_REF:-v1.1.x}"   # branch or tag

clone_or_update() {
  local url="$1"
  if [[ ! -d ${BUILD_DIR} ]]; then
    echo "[INFO] Cloning ${url} into ${BUILD_DIR}…"
    git clone "${url}" "${BUILD_DIR}"
  else
    echo "[INFO] Updating repo at ${BUILD_DIR} from ${url}…"
    ( cd "${BUILD_DIR}" && git remote set-url origin "${url}" && git fetch --all )
  fi
}

try_checkout_ref() {
  local ref="$1"
  ( cd "${BUILD_DIR}" && git fetch --tags --all && git checkout --force "${ref}" )
}

set +e
clone_or_update "${REPO_CB}"
if ! try_checkout_ref "${LY_REF}"; then
  echo "[WARN] Could not checkout ${LY_REF} from Codeberg. Trying GitHub mirror…"
  rm -rf "${BUILD_DIR}"
  clone_or_update "${REPO_GH}"
  if ! try_checkout_ref "${LY_REF}"; then
    echo "[ERROR] Unable to checkout ${LY_REF} from Codeberg or GitHub."
    exit 1
  fi
fi
set -e

# 4) Build (strictly with Zig 0.14.x on PATH)
echo "[INFO] Building Ly v1.1.x with Zig $(zig version)…"
( cd "${BUILD_DIR}" && zig build -Doptimize=ReleaseFast )

# 5) Install Ly (systemd)
echo "[INFO] Installing Ly (systemd)…"
( cd "${BUILD_DIR}" && as_root "zig build installexe -Dinit_system=systemd" )

# 6) Deploy config + PAM
echo "[INFO] Deploying Ly config + PAM…"
as_root "install -D -m 0644 '${ROOT_DIR}/config/ly/config.${THEME}.ini' /etc/ly/config.ini"
as_root "install -D -m 0644 '${ROOT_DIR}/config/pam.d/ly'      /etc/pam.d/ly"

# Optional autologin (replace placeholder after install)
if grep -q "__TARGET_USER__" /etc/ly/config.ini 2>/dev/null; then
  as_root "sed -i 's/__TARGET_USER__/${TARGET_USER}/g' /etc/ly/config.ini"
fi

# 7) Hyprland session fallback
if ! test -f /usr/share/wayland-sessions/hyprland.desktop; then
  echo "[INFO] Installing fallback Hyprland session file…"
  as_root "install -D -m 0644 '${ROOT_DIR}/config/wayland-sessions/hyprland.desktop' \
    /usr/share/wayland-sessions/hyprland.desktop"
fi

# 8) SELinux contexts
echo "[INFO] Restoring SELinux contexts…"
as_root "restorecon -RF /etc/ly /etc/pam.d/ly /usr/share/wayland-sessions || true"

# 9) tty2 by default → disable getty@tty2
echo "[INFO] Disabling getty@tty2.service (Ly runs on tty2)…"
as_root "systemctl disable --now getty@tty2.service" || true

# 10) Enable Ly + graphical target
echo "[INFO] Enabling Ly…"
enable_service_reboot ly.service
as_root "systemctl set-default graphical.target"

cat <<'EOF'

[OK] Ly v1.1.x is installed and enabled (built with Zig 0.14.x).
- Reboot to start Ly, or: sudo systemctl start ly.service
- If SELinux blocks, create a tiny policy from logs:
    sudo ausearch -m avc -ts recent | audit2allow -M ly-local
    sudo semodule -i ly-local.pp
- Logs: journalctl -u ly -b -e
EOF
