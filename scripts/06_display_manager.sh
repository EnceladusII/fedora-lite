#!/usr/bin/env bash
set -euo pipefail
# Switch from gdm to Ly with smart Zig selection:
# - v1.0.x -> prefer Zig 0.13.x
# - master / v1.1+ -> prefer Zig 0.15.x
# Falls back to portable toolchains in /opt/zig-<ver>

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set}"
: "${ROOT_DIR:?ROOT_DIR must be set}"
: "${THEME:?Missing THEME in .env}"

echo "[INFO] Switching to Ly Display Manager"
echo "[INFO] TARGET_USER=${TARGET_USER}"

# 1) Disable other DMs
echo "[INFO] Disabling conflicting display managers…"
disable_service gdm.service || true
as_root "systemctl disable --now greetd.service" || true
as_root "dnf -y remove greetd tuigreet" || true

# 2) Dependencies (add curl/tar/xz/file/git for portable Zig handling)
echo "[INFO] Installing build/runtime dependencies…"
as_root "dnf -y install kbd kernel-devel pam-devel libxcb-devel zig xorg-x11-xauth xorg-x11-server-common brightnessctl curl tar xz file git"

# 3) Clone Ly (pin with LY_REF=v1.0.3 for example)
REPO_URL="${REPO_URL:-https://codeberg.org/fairyglade/ly.git}"
BUILD_DIR="${BUILD_DIR:-/tmp/ly}"
LY_REF="${LY_REF:-v1.0.3}"   # e.g. export LY_REF=v1.0.3

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

# ---------- Zig toolchain helpers ----------
detect_arch() {
  case "$(uname -m)" in
    x86_64)  echo "x86_64" ;;
    aarch64) echo "aarch64" ;;
    *) echo "[ERROR] Unsupported arch: $(uname -m)" >&2; return 1 ;;
  esac
}

download_and_install_zig() {
  local ver="$1" arch="$2" dest_root="$3"
  local tmpdir tgz inner ok=false
  tmpdir="$(mktemp -d)"
  tgz="${tmpdir}/zig-linux-${arch}-${ver}.tar.xz"

  # Primary + fallback URLs
  local urls=(
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

ensure_zig_on_path() {
  # Arg can be "system" or a concrete version like "0.13.2" / "0.15.2"
  local req="$1" arch dest zigbin
  if [[ "${req}" == "system" ]]; then
    if command -v zig >/dev/null 2>&1; then
      echo "[INFO] Using system Zig $(zig version)"
      return 0
    else
      echo "[WARN] System Zig not found."
      return 1
    fi
  fi
  arch="$(detect_arch)"
  dest="/opt/zig-${req}"
  zigbin="${dest}/zig"
  if [[ ! -x "${zigbin}" ]]; then
    echo "[INFO] Installing portable Zig ${req} to ${dest}…"
    if ! download_and_install_zig "${req}" "${arch}" "${dest}"; then
      echo "[WARN] Failed to install Zig ${req}"
      return 1
    fi
  fi
  export PATH="$(dirname "${zigbin}"):${PATH}"
  echo "[INFO] Using portable Zig ${req}: $("${zigbin}" version)"
  return 0
}

try_build_ly() {
  echo "[INFO] Building Ly with Zig $(zig version)…"
  ( cd "${BUILD_DIR}" && zig build -Doptimize=ReleaseFast )
}

# Decide candidate Zig versions based on LY_REF
ZIG_CANDIDATES=()
if [[ "${LY_REF}" =~ ^v1\.0\. ]]; then
  # v1.0.x prefers Zig 0.13.x
  ZIG_CANDIDATES=( "system" "0.13.2" "0.13.1" "0.13.0" )
else
  # master / v1.1+ prefers Zig 0.15.x (try a few patch versions)
  ZIG_CANDIDATES=( "system" "0.15.2" "0.15.1" "0.15.0" )
fi

# 4) Build: iterate candidates until it works
built=false
for cand in "${ZIG_CANDIDATES[@]}"; do
  echo "[INFO] === Trying Zig candidate: ${cand} ==="
  if ensure_zig_on_path "${cand}"; then
    if try_build_ly; then
      built=true
      break
    else
      echo "[WARN] Build failed with Zig candidate ${cand}"
    fi
  fi
done

if ! $built; then
  echo "[ERROR] All Zig candidates failed. Aborting."
  exit 1
fi

# 5) Install Ly (systemd)
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

Tips:
- Pour forcer la branche 1.0.x (compatible Zig 0.13.x) :
    export LY_REF=v1.0.3   # ou un autre tag 1.0.x
- Si tu veux ignorer complètement 0.15, garde LY_REF en 1.0.x : le script essaiera d'abord le Zig système puis 0.13.x portable.
EOF
