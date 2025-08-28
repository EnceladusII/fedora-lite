#!/usr/bin/env bash
set -euo pipefail
# Step 6 — Switch from gdm to Ly with graceful Zig handling (try release w/ system zig first)

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set}"
: "${ROOT_DIR:?ROOT_DIR must be set}"
: "${THEME:?Missing THEME in .env}"

echo "[INFO] Switching to Ly Display Manager"
echo "[INFO] TARGET_USER=${TARGET_USER}"

# 1) Disable other DMs (gdm or greetd)
echo "[INFO] Disabling conflicting display managers…"
disable_service gdm.service || true
as_root "systemctl disable --now greetd.service" || true
as_root "dnf -y remove greetd tuigreet" || true

# 2) Installing dependencies
echo "[INFO] Installing build/runtime dependencies…"
# add curl, tar, xz, file for portable Zig handling
as_root "dnf -y install kbd kernel-devel pam-devel libxcb-devel zig xorg-x11-xauth xorg-x11-server-common brightnessctl curl tar xz file git"

# 3) Clone Ly (optionally pin to release/tag/commit via LY_REF)
REPO_URL="${REPO_URL:-https://codeberg.org/fairyglade/ly.git}"
BUILD_DIR="${BUILD_DIR:-/tmp/ly}"
LY_REF="${LY_REF:v1.0.3}"   # e.g. export LY_REF=v1.0.5 to force a 1.0.x release

if [[ ! -d ${BUILD_DIR} ]]; then
  echo "[INFO] Cloning Ly into ${BUILD_DIR}…"
  git clone "${REPO_URL}" "${BUILD_DIR}"
else
  echo "[INFO] Updating Ly in ${BUILD_DIR}…"
  git -C "${BUILD_DIR}" fetch --all
  git -C "${BUILD_DIR}" reset --hard origin/master
fi

if [[ -n "${LY_REF}" ]]; then
  echo "[INFO] Checking out Ly ref: ${LY_REF}"
  git -C "${BUILD_DIR}" fetch --tags --all
  git -C "${BUILD_DIR}" checkout --force "${LY_REF}"
fi

# --- helper: portable Zig 0.15 shim (only if needed) ---
install_portable_zig_if_needed() {
  local ZIG_REQUIRED="${ZIG_REQUIRED:-0.15.0}"     # change to 0.15.1/0.15.2 if needed
  local ARCH ZIG_ARCH ZIG_ROOT ZIG_BIN
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)   ZIG_ARCH="x86_64" ;;
    aarch64)  ZIG_ARCH="aarch64" ;;
    *) echo "[ERROR] Unsupported arch: $ARCH"; return 1 ;;
  esac
  ZIG_ROOT="/opt/zig-${ZIG_REQUIRED}"
  ZIG_BIN="${ZIG_ROOT}/zig"

  if [[ -x "${ZIG_BIN}" ]]; then
    export PATH="$(dirname "${ZIG_BIN}"):${PATH}"
    echo "[INFO] Using cached portable Zig at ${ZIG_BIN}: $(${ZIG_BIN} version)"
    return 0
  fi

  download_and_install_zig() {
    local ver="$1" arch="$2" dest_root="$3"
    local tmpdir tgz inner urls ok=false
    tmpdir="$(mktemp -d)"
    tgz="${tmpdir}/zig-linux-${arch}-${ver}.tar.xz"
    urls=(
      "https://ziglang.org/download/${ver}/zig-linux-${arch}-${ver}.tar.xz"
      "https://github.com/ziglang/zig/releases/download/${ver}/zig-linux-${arch}-${ver}.tar.xz"
    )
    for url in "${urls[@]}"; do
      echo "[INFO] Fetching ${url} …"
      if ! curl -fL --retry 3 --retry-delay 2 -o "${tgz}" "${url}"; then
        echo "[WARN] Download failed from ${url}"
        continue
      fi
      if file "${tgz}" | grep -qi 'HTML'; then
        echo "[WARN] Got HTML instead of archive from ${url}"
        continue
      fi
      if ! xz -t "${tgz}" >/dev/null 2>&1; then
        echo "[WARN] xz test failed for ${tgz}"
        continue
      fi
      mkdir -p "${tmpdir}/extract"
      if ! tar -C "${tmpdir}/extract" -xf "${tgz}"; then
        echo "[WARN] tar extraction failed for ${tgz}"
        continue
      fi
      inner="$(find "${tmpdir}/extract" -maxdepth 1 -type d -name 'zig-*' | head -n1)"
      if [[ -z "${inner}" || ! -x "${inner}/zig" ]]; then
        echo "[WARN] Could not find zig binary inside archive"
        continue
      fi
      as_root "mkdir -p '${dest_root}'"
      as_root "cp -a '${inner}/.' '${dest_root}/'"
      as_root "chmod -R a+rX '${dest_root}'"
      ok=true; break
    done
    rm -rf "${tmpdir}"
    $ok
  }

  echo "[INFO] Installing portable Zig ${ZIG_REQUIRED} to ${ZIG_ROOT}…"
  if ! download_and_install_zig "${ZIG_REQUIRED}" "${ZIG_ARCH}" "${ZIG_ROOT}"; then
    echo "[ERROR] Failed to download/install Zig ${ZIG_REQUIRED} (checked ziglang.org and GitHub)."
    return 1
  fi
  export PATH="$(dirname "${ZIG_BIN}"):${PATH}"
  echo "[INFO] Using portable Zig at ${ZIG_BIN}: $(${ZIG_BIN} version)"
}

# --- helper: try to build with current zig on PATH ---
try_build_ly() {
  echo "[INFO] Building Ly with Zig $(zig version) …"
  ( cd "${BUILD_DIR}" && zig build -Doptimize=ReleaseFast )
}

# 4) Build step: try system Zig first, then fallback to portable 0.15 if needed
use_portable=false
if command -v zig >/dev/null 2>&1; then
  echo "[INFO] System Zig detected: $(zig version)"
else
  echo "[WARN] No system Zig found."
fi

if ! try_build_ly; then
  echo "[WARN] Build with current Zig failed. Falling back to portable Zig 0.15…"
  use_portable=true
  install_portable_zig_if_needed
  try_build_ly
fi

# 5) Installing Ly (systemd)
echo "[INFO] Installing Ly (systemd)…"
( cd "${BUILD_DIR}" && as_root "zig build installexe -Dinit_system=systemd" )

# 6) Deploy conf from repo
echo "[INFO] Deploying Ly config + PAM…"
as_root "install -D -m 0644 '${ROOT_DIR}/config/ly/config.${THEME}.ini' /etc/ly/config.ini"
as_root "install -D -m 0644 '${ROOT_DIR}/config/pam.d/ly'      /etc/pam.d/ly"

# Optional autologin (replace placeholder in installed file)
if grep -q "__TARGET_USER__" /etc/ly/config.ini 2>/dev/null; then
  as_root "sed -i 's/__TARGET_USER__/${TARGET_USER}/g' /etc/ly/config.ini"
fi

# 7) Hyprland session fallback if unavailable
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
as_root "systemctl enable ly.service"
as_root "systemctl set-default graphical.target"

cat <<'EOF'

[OK] Ly is installed and enabled.
- Reboot to start Ly, or: sudo systemctl start ly.service
- If SELinux blocks, create a tiny policy from logs:
    sudo ausearch -m avc -ts recent | audit2allow -M ly-local
    sudo semodule -i ly-local.pp
- Logs: journalctl -u ly -b -e

Notes:
- You can pin a specific release/tag/commit with: export LY_REF=v1.0.5
- The script first tries to build with your system Zig (e.g., 0.14.x).
  If that fails, it automatically uses a portable Zig 0.15 to complete the build.
EOF
