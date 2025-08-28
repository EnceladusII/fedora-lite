#!/usr/bin/env bash
set -euo pipefail
# Step 6 — Switch from gdm to Ly (Zig build)

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
as_root "dnf -y install kbd kernel-devel pam-devel libxcb-devel zig xorg-x11-xauth xorg-x11-server-common brightnessctl curl tar xz file"

# --- Portable Zig 0.15 shim (no system replacement) ---
# If system zig isn't 0.15.x, fetch a portable toolchain into /opt/zig-<ver> and prepend to PATH.
ZIG_REQUIRED="${ZIG_REQUIRED:-0.15.0}"     # change to 0.15.1/0.15.2 if Ly requires it
ZIG_ROOT="/opt/zig-${ZIG_REQUIRED}"
ZIG_BIN="${ZIG_ROOT}/zig"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)   ZIG_ARCH="x86_64" ;;
  aarch64)  ZIG_ARCH="aarch64" ;;
  *) echo "[ERROR] Unsupported arch: $ARCH"; exit 1 ;;
esac

need_portable_zig=true
if command -v zig >/dev/null 2>&1; then
  SYS_ZIG_VER="$(zig version || true)"
  case "${SYS_ZIG_VER}" in
    0.15.*) need_portable_zig=false; ZIG_BIN="$(command -v zig)"; echo "[INFO] System Zig ${SYS_ZIG_VER} OK";;
    *)      echo "[WARN] System Zig ${SYS_ZIG_VER} != 0.15.x — will use portable toolchain.";;
  esac
else
  echo "[WARN] No system zig — will use portable toolchain."
fi

download_and_install_zig() {
  local ver="$1" arch="$2" dest_root="$3"
  local tmpdir tgz inner urls ok=false
  tmpdir="$(mktemp -d)"
  tgz="${tmpdir}/zig-linux-${arch}-${ver}.tar.xz"

  # URLs to try (primary ziglang.org + fallback GitHub)
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

    # Sanity checks: not HTML, valid xz
    if file "${tgz}" | grep -qi 'HTML'; then
      echo "[WARN] Got HTML instead of archive from ${url}"
      continue
    fi
    if ! xz -t "${tgz}" >/dev/null 2>&1; then
      echo "[WARN] xz test failed for ${tgz}"
      continue
    fi

    # Extract
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
    ok=true
    break
  done

  rm -rf "${tmpdir}"
  $ok || return 1
  return 0
}

if $need_portable_zig; then
  if [[ ! -x "${ZIG_BIN}" ]]; then
    echo "[INFO] Installing portable Zig ${ZIG_REQUIRED} to ${ZIG_ROOT}…"
    if ! download_and_install_zig "${ZIG_REQUIRED}" "${ZIG_ARCH}" "${ZIG_ROOT}"; then
      echo "[ERROR] Failed to download/install Zig ${ZIG_REQUIRED} (checked ziglang.org and GitHub)."
      exit 1
    fi
  fi
  echo "[INFO] Using portable Zig at ${ZIG_BIN}: $(${ZIG_BIN} version)"
fi

# Ensure this script prefers the selected zig
export PATH="$(dirname "${ZIG_BIN}"):${PATH}"

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

# 5) Deploy conf from repo
echo "[INFO] Deploying Ly config + PAM…"
as_root "install -D -m 0644 '${ROOT_DIR}/config/ly/config.${THEME}.ini' /etc/ly/config.ini"
as_root "install -D -m 0644 '${ROOT_DIR}/config/pam.d/ly'      /etc/pam.d/ly"

# Optional autologin (replace placeholder in installed file)
if grep -q "__TARGET_USER__" /etc/ly/config.ini 2>/dev/null; then
  as_root "sed -i 's/__TARGET_USER__/${TARGET_USER}/g' /etc/ly/config.ini"
fi

# 6) Hyprland session fallback if unavailable
if ! test -f /usr/share/wayland-sessions/hyprland.desktop; then
  echo "[INFO] Installing fallback Hyprland session file…"
  as_root "install -D -m 0644 '${ROOT_DIR}/config/wayland-sessions/hyprland.desktop' \
    /usr/share/wayland-sessions/hyprland.desktop"
fi

# as_root "install -D -m 0644 '${ROOT_DIR}/config/vtrgb/vtrgb' /etc/vtrgb" || true
# as_root "install -D -m 0644 '${ROOT_DIR}/config/systemd/vt-colors.service' /etc/systemd/system/vt-colors.service" || true
# as_root "systemctl enable vt-colors.service" || true

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
