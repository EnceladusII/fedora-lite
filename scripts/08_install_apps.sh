#!/usr/bin/env bash
set -euo pipefail
# Install favorite apps from lists/{rpm-packages.txt, flatpaks.txt, appimages.txt}
# Runs as user, elevates only with as_root when required.

. "$(dirname "$0")/00_helpers.sh"

# --- GPU MONITORING ---
: "${GPU:?Missing GPU in .env}"

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

case "$gpu" in
    amd)
    as_root "dnf -y copr enable ilyaz/LACT"
    as_root "dnf -y install lact"
    as_root "systemctl enable --now lact"
    ;;
  nvidia)
    as_root "dnf -y install gwe"
    ;;
esac

echo "[OK] GPU OC software installation completed"

# --- Laptop Configuration ---
: "${SETUP:?Missing SETUP in .env}"
: "${TARGET_USER:?TARGET_USER must be set (from .env or sudo env)}"
UHOME="$(user_home "$TARGET_USER")"

if [[ "$SETUP" == "laptop" ]]; then
  echo "[INFO] Detected setup: $SETUP"

  # Increase battery life
  as_root "dnf -y install tlp tlp-rdw smartmontools"
  as_root "systemctl mask power-profiles-daemon.service"
  as_root "systemctl mask systemd-rfkill.service"
  as_root "systemctl mask systemd-rfkill.socket"
  as_root "systemctl enable --now tlp"
  as_root "sudo tlp start"

  # Add profiles switch selector:
  as_root "dnf -y update"
  TUX_REPO="/etc/yum.repos.d/tuxedo.repo"
  FEDORA_VERSION=$(rpm -E %fedora)
  ts="$(date +%s)"

  as_root "bash -lc '
    set -euo pipefail
    [[ -f \"$TUX_REPO\" ]] || touch \"$TUX_REPO\"
    cp -a \"$TUX_REPO\" \"$TUX_REPO.bak.$ts\"
    cat >> \"$TUX_REPO\" <<EOF
[tuxedo]
name=tuxedo
baseurl=https://rpm.tuxedocomputers.com/fedora/$FEDORA_VERSION/x86_64/base
enabled=1
gpgcheck=1
gpgkey=https://rpm.tuxedocomputers.com/fedora/$FEDORA_VERSION/0x54840598.pub.asc
skip_if_unavailable=False
EOF
  echo \"[OK] dnf.conf tuned (backup: $TUX_REPO.bak.$ts)\"
'"

  wget https://rpm.tuxedocomputers.com/fedora/$FEDORA_VERSION/0x54840598.pub.asc -O /tmp/0x54840598.pub.asc
  as_root "rpm --import /tmp/0x54840598.pub.asc"
  as_root "dnf -y install tuxedo-drivers tuxedo-control-center"

  if [[ "$gpu" == "nvidia" ]]; then
      git clone https://github.com/wildtruc/nvidia-prime-select.git $UHOME/.local/share/nvidia-prime-select
      cd $UHOME/.local/share/nvidia-prime-select
      as_root "make install"
      echo "Nvidia-prime-select successfully installed"
      as_root "flatpak install -y flathub de.z_ray.OptimusUI"
  fi
  echo "[OK] Laptop setup ready"
fi

# --- Packages ---
PKG_LIST="$ROOT_DIR/lists/packages.txt"
if [[ -f "$PKG_LIST" ]]; then
  pkgs=()
  while IFS= read -r p; do
    [[ -z "${p// /}" || "$p" =~ ^# ]] && continue
    if ! pkg_installed "$p"; then
      pkgs+=("$p")
    fi
  done < <(apply_list "$RPM_LIST")

  if ((${#pkgs[@]})); then
    echo "[INFO] Installing packages: ${pkgs[*]}"
    as_root "dnf -y install ${pkgs[*]}"
  else
    echo "[INFO] No new RPM packages to install."
  fi
fi

echo "[OK] Packages installed"

# --- Flatpaks (system-wide install) ---
FLAT_LIST="$ROOT_DIR/lists/flatpaks.txt"

if [[ -f "$FLAT_LIST" ]]; then
  while IFS= read -r app; do
    [[ -z "${app// /}" || "$app" =~ ^# ]] && continue
    if ! flatpak list --system --app --columns=application | grep -Fxq "$app"; then
      echo "[INFO] Installing Flatpak (system): $app"
      as_root "flatpak install -y --noninteractive --system flathub \"$app\""
    fi
  done < <(apply_list "$FLAT_LIST")
fi

echo "[OK] Flatpaks installed"

# --- RPMs ---
RPM_LIST="$ROOT_DIR/lists/rpm_git.txt"

TMPDIR="/tmp/gh-rpms"
mkdir -p "$TMPDIR"

gh_api() {
  local url="$1"
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: gh-rpm-installer" \
    "$url"
}

map_arch() {
  case "$(uname -m)" in
    x86_64)   echo 'x86_64|amd64';;
    aarch64)  echo 'aarch64|arm64';;
    armv7l)   echo 'armv7|armhf';;
    *)        echo 'x86_64|amd64|aarch64|arm64';;
  esac
}

pick_rpm_asset_url() {
  local arch_regex
  arch_regex="$(map_arch)"
  jq -r --arg arch_regex "$arch_regex" '
    .assets // []
    | map(select(.browser_download_url | test("\\.rpm$")))
    | if length == 0 then empty else . end
    | ( map(select(.name  | test($arch_regex;"i")))
        + map(select((.label // "") | test($arch_regex;"i")))
        + . )
    | .[0].browser_download_url
  ' | head -n1
}

install_latest_github_rpm() {
  local repo="$1"

  echo "[INFO] GitHub latest for $repo"

  local latest_json url
  latest_json="$(gh_api "https://api.github.com/repos/$repo/releases/latest" || true)"
  url="$(printf '%s' "$latest_json" | pick_rpm_asset_url || true)"

  if [[ -z "$url" || "$url" == "null" ]]; then
    local rel_json
    rel_json="$(gh_api "https://api.github.com/repos/$repo/releases?per_page=15" || true)"
    url="$(printf '%s' "$rel_json" | jq -c '.[]' | while read -r item; do
            prerelease=$(printf '%s' "$item" | jq -r '.prerelease')
            draft=$(printf '%s' "$item" | jq -r '.draft')
            if [[ "$prerelease" == "false" && "$draft" == "false" ]]; then
              printf '%s' "$item" | pick_rpm_asset_url && break
            fi
          done
         )"
  fi

  if [[ -z "$url" || "$url" == "null" ]]; then
    echo "[WARN] Aucun asset .rpm trouvé pour $repo"
    return 0
  fi

  local rpm_file="$TMPDIR/$(basename "$url")"
  echo "[INFO] Téléchargement -> $rpm_file"
  curl -fL -o "$rpm_file" "$url"

  echo "[INFO] Installation -> $(basename "$rpm_file")"
  as_root "dnf -y install '$rpm_file'"
}

if [[ -f "$RPM_LIST" ]]; then
  while IFS= read -r repo; do
    [[ -z "${repo// /}" || "$repo" =~ ^# ]] && continue
    install_latest_github_rpm "$repo"
  done < <(apply_list "$RPM_LIST")
fi

echo "[OK] External RPMs installed"

# --- AppImages ---
APPIMG_LIST="$ROOT_DIR/lists/appimages.txt"
if [[ -f "$APPIMG_LIST" ]]; then
  APPDIR="$(user_home "$TARGET_USER")/.AppImages"
  as_user "mkdir -p '$APPDIR'"

  # -------- helpers --------
  gh_api() {
    local url="$1"
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: appimage-installer" \
      "$url"
  }

  map_arch_regex() {
    case "$(uname -m)" in
      x86_64)   echo 'x86_64|amd64';;
      aarch64)  echo 'aarch64|arm64';;
      armv7l)   echo 'armv7|armhf';;
      *)        echo 'x86_64|amd64|aarch64|arm64';;
    esac
  }

  pick_appimage_asset_url() {
    local arch_regex
    arch_regex="$(map_arch_regex)"
    jq -r --arg arch_regex "$arch_regex" '
      .assets // []
      | map(select(.browser_download_url | test("\\.AppImage$"; "i")))
      | if length == 0 then empty else . end
      | ( map(select(.name  | test($arch_regex; "i")))
          + map(select((.label // "") | test($arch_regex; "i")))
          + . )
      | .[0].browser_download_url
    ' | head -n1
  }

  resolve_github_appimage_url() {
    local repo="$1"
    local url=""

    local latest_json
    latest_json="$(gh_api "https://api.github.com/repos/$repo/releases/latest" || true)"
    url="$(printf '%s' "$latest_json" | pick_appimage_asset_url || true)"

    if [[ -z "$url" || "$url" == "null" ]]; then
      local rel_json
      rel_json="$(gh_api "https://api.github.com/repos/$repo/releases?per_page=15" || true)"
      url="$(printf '%s' "$rel_json" | jq -c '.[]' | while read -r item; do
              prerelease=$(printf '%s' "$item" | jq -r '.prerelease')
              draft=$(printf '%s' "$item" | jq -r '.draft')
              if [[ "$prerelease" == "false" && "$draft" == "false" ]]; then
                printf '%s' "$item" | pick_appimage_asset_url && break
              fi
            done
           )"
    fi

    [[ -n "$url" && "$url" != "null" ]] && printf '%s' "$url"
  }

  is_github_repo_ref() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]
  }

  download_appimage() {
    local url="$1"
    local target="$2"
    echo "[INFO] Downloading AppImage: $url"
    as_user "wget -O '$target' '$url'"
    as_user "chmod +x '$target'"
  }

  # -------- main loop --------
  while IFS= read -r entry; do
    [[ -z "${entry// /}" || "$entry" =~ ^# ]] && continue

    if is_github_repo_ref "$entry"; then
      echo "[INFO] Resolving GitHub AppImage for: $entry"
      url="$(resolve_github_appimage_url "$entry" || true)"
      if [[ -z "$url" ]]; then
        echo "[WARN] No AppImage found in release of $entry"
        continue
      fi
    else
      url="$entry"
      if [[ ! "$url" =~ \.AppImage($|\?) ]]; then
        echo "[WARN] Unrecognize as AppImage: $url"
        continue
      fi
    fi

    fname="${url##*/}"
    fname="${fname%%\?*}"
    target="$APPDIR/$fname"

    if [[ -f "$target" ]]; then
      echo "[SKIP] Déjà présent: $target"
      continue
    fi

    download_appimage "$url" "$target"
  done < <(apply_list "$APPIMG_LIST")
fi

echo "[OK] External AppImages installed"

echo "[OK] Application installation step complete."
