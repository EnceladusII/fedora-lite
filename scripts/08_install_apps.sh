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

  # Add profiles switch selector (for tuxedo laptops):
  if [[ -f /sys/class/dmi/id/sys_vendor ]] && grep -qi "tuxedo" /sys/class/dmi/id/sys_vendor; then
    echo "[OK] Tuxedo Device found"
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
  else
      echo "[OK] Not a Tuxedo Device, check your system vendor profile selector"
  fi

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
    echo "[WARN] No asset .rpm found in $repo"
    return 0
  fi

  local rpm_file="$TMPDIR/$(basename "$url")"
  echo "[INFO] Downloading -> $rpm_file"
  curl -fL -o "$rpm_file" "$url"

  echo "[INFO] Installing -> $(basename "$rpm_file")"
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

  is_appimage_like_url() {
    local u="${1,,}"
    [[ "$u" =~ \.appimage($|\?|/|%2f|%3f) ]]
  }

  guess_appimage_filename() {
    local url="$1"
    local header final_name

    header="$(curl -sSIL -o /dev/null \
      -w '%header{content-disposition}\n%header{location}\n' "$url" || true)"

    final_name="$(printf '%s' "$header" \
      | awk -F'filename\\*=|filename=' 'NF>1{print $2}' \
      | head -n1 \
      | sed -E "s/^UTF-8''//; s/;.*$//; s/\"//g" \
      | sed -E 's/\r$//' )"

    if [[ -n "$final_name" ]]; then
      final_name="$(printf '%b' "${final_name//%/\\x}")"
    fi

    if [[ -z "$final_name" ]]; then
      local last_loc
      last_loc="$(printf '%s' "$header" | tail -n1 | tr -d '\r')"
      if is_appimage_like_url "${last_loc:-}"; then
        final_name="${last_loc##*/}"
        final_name="${final_name%%\?*}"
      fi
    fi

    if [[ -z "$final_name" ]]; then
      final_name="${url##*/}"
      final_name="${final_name%%\?*}"
    fi

    if [[ -z "$final_name" || "$final_name" == "download" || "$final_name" == "latest" ]]; then
      final_name="AppImage-$(date +%s).AppImage"
    fi

    printf '%s' "$final_name"
  }

  is_appimage_file() {
    local file="$1"
    if head -c 3 "$file" 2>/dev/null | grep -q '^AI'; then
      return 0
    else
      return 1
    fi
  }

  download_appimage() {
    local url="$1"
    local target="$2"
    echo "[INFO] Downloading AppImage: $url"
    as_user "curl -fL --retry 3 --retry-delay 2 -C - -o '$target.part' '$url' || rm -f '$target.part'"
    as_user "test -s '$target.part' && mv -f '$target.part' '$target'"

    if as_user "[ -f '$target' ] && ! [[ '$target' =~ \.AppImage$ ]]"; then
      if is_appimage_file "$target"; then
        new_target="${target}.AppImage"
        as_user "mv -f '$target' '$new_target'"
        target="$new_target"
        echo "[INFO] To --> $target"
      fi
    fi

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

    fname="${url##*/}"
    fname="${fname%%\?*}"
    target="$APPDIR/$fname"

    if [[ -f "$target" ]]; then
      echo "[SKIP] Was present: $target"
      continue
    fi

    download_appimage "$url" "$target"

  else
    url="$entry"
    fname="$(guess_appimage_filename "$url")"
    target="$APPDIR/$fname"

    if [[ -f "$target" ]]; then
      echo "[SKIP] Was present: $target"
      continue
    fi

    download_appimage "$url" "$target"

  fi
done < <(apply_list "$APPIMG_LIST")
fi

# ---- Gear Lever CLI helper (non interactif) --------------------------------
as_root "dnf -y install fuse fuse-libs"
# --- Helpers AppImage -------------------------------------------------------
is_appimage_file() {
  # vrai AppImage: commence par "AI"
  head -c 2 "$1" 2>/dev/null | grep -q '^AI'
}

appimage_pretty_name() {
  # Extrait le Name= depuis le .desktop interne (fallback: basename sans suffixes)
  local f="$1"
  local tmp
  tmp="$(mktemp -d)"
  # extraction non verbeuse; certains runtimes affichent sur stderr → 2>/dev/null
  if "$f" --appimage-extract >/dev/null 2>&1; then
    # l’extraction crée ./squashfs-root dans PWD
    if [[ -d squashfs-root ]]; then
      # on cherche le .desktop principal
      local desk
      desk="$(ls -1 squashfs-root/*.desktop squashfs-root/usr/share/applications/*.desktop 2>/dev/null | head -n1)"
      if [[ -n "$desk" ]]; then
        # Priorité à Name[en], sinon Name générique
        local name
        name="$(grep -E '^Name(\[en(_[A-Za-z]+)?\])?=' "$desk" | head -n1 | sed -E 's/^Name(\[.*\])?=//')"
        name="${name:-$(grep -E '^Name=' "$desk" | head -n1 | sed -E 's/^Name=//')}"
        if [[ -n "$name" ]]; then
          # Nettoyage
          name="$(echo "$name" | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+|[[:space:]]+$//g; s/[^A-Za-z0-9._+ -]/-/g')"
          echo "$name"
          rm -rf squashfs-root
          return 0
        fi
      fi
      rm -rf squashfs-root
    fi
  fi
  # Fallback: nom depuis le fichier
  local base="${f##*/}"
  base="${base%.AppImage}"
  base="$(echo "$base" | sed -E 's/[-_.](x86_64|amd64|aarch64|arm64|armv7|armhf|linux|ubuntu|jammy|focal|latest)//Ig')"
  base="$(echo "$base" | sed -E 's/[[:space:]]+/ /g; s/[^A-Za-z0-9._+ -]/-/g')"
  echo "$base"
}

normalize_appimage_filename() {
  # Renomme en "<Name>[-Version].AppImage" si possible, sinon juste "<Name>.AppImage"
  local f="$1"
  local dir base name ver new
  dir="$(dirname "$f")"
  base="$(basename "$f")"
  name="$(appimage_pretty_name "$f")"

  # Essaie d’extraire une version depuis le nom d’origine
  ver="$(echo "$base" | sed -nE 's/.*[^0-9]([0-9]+\.[0-9]+(\.[0-9]+)?([._-]?(beta|rc)[0-9]*)?).*/\1/ip' | head -n1 | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
  # Construit un nom court et propre
  if [[ -n "$ver" ]]; then
    new="${name}-${ver}.AppImage"
  else
    new="${name}.AppImage"
  fi
  # compactage des espaces / tirets
  new="$(echo "$new" | sed -E 's/[[:space:]]+/-/g; s/-+/-/g; s/^-+|-+$//g')"

  # Si le nom ne change pas vraiment, ne rien faire
  if [[ "$base" == "$new" ]]; then
    echo "$f"
    return 0
  fi

  local target="$dir/$new"
  if mv -f -- "$f" "$target"; then
    echo "$target"
    return 0
  else
    echo "$f"
    return 0
  fi
}

# --- Gear Lever CLI ---------------------------------------------------------
GL_CMD=""
if command -v gearlever >/dev/null 2>&1; then
  GL_CMD="gearlever"
else
  GL_CMD="flatpak run it.mijorus.gearlever"
fi

# option non-interactive si dispo
GL_YES=""
if $GL_CMD --help 2>/dev/null | grep -q -- '--assume-yes'; then
  GL_YES="--assume-yes"
fi

integrate_and_update_appimages() {
  local appdir="${APPDIR:-$HOME/.AppImages}"
  [[ -d "$appdir" ]] || { echo "[INFO] Rien à intégrer: $appdir inexistant"; return 0; }

  echo "[INFO] Intégration/MAJ via Gear Lever dans: $appdir"

  # Liste actuelle pour éviter ré-intégrer
  local installed
  installed="$($GL_CMD --list-installed 2>/dev/null || true)"

  # Ne prendre que des candidats AppImage: .AppImage OU exécutable (pour ceux sans extension)
  while IFS= read -r -d '' f; do
    [[ -f "$f" && -r "$f" ]] || continue
    case "$f" in
      *.desktop|*.zsync) continue ;;
    esac

    # S’assurer que c’est exécutable
    [[ -x "$f" ]] || chmod +x "$f" 2>/dev/null || true

    # Vérifier AppImage (signature) ou extension .AppImage
    if ! is_appimage_file "$f" && [[ ! "$f" =~ \.AppImage$ ]]; then
      # 🔎 Diagnostic pour cas comme "beeper" si pas reconnu
      echo "[SKIP] $(basename "$f") n'est pas détecté comme AppImage (signature 'AI' absente)."
      continue
    fi

    # ➜ Renommer proprement pour éviter les noms à rallonge
    f="$(normalize_appimage_filename "$f")"
    local base="$(basename "$f")"
    echo "[INFO] Candidat: $base"

    if printf '%s\n' "$installed" | grep -Fq -- "$base"; then
      echo "  └─ Déjà intégré → vérif des mises à jour…"
      if $GL_CMD --update $GL_YES "$f" >/dev/null 2>&1; then
        echo "     ✓ À jour (ou mis à jour)"
      else
        echo "     ⚠️  Update indisponible pour $base"
      fi
    else
      echo "  └─ Intégration…"
      if $GL_CMD --integrate $GL_YES "$f" </dev/null 2>/dev/null; then
        echo "     ✓ Intégré"
        installed="$($GL_CMD --list-installed 2>/dev/null || printf '%s' "$installed")"
      else
        # fallback si pas de --assume-yes
        if command -v yes >/dev/null 2>&1 && yes | $GL_CMD --integrate "$f" >/dev/null 2>&1; then
          echo "     ✓ Intégré (fallback yes)"
          installed="$($GL_CMD --list-installed 2>/dev/null || printf '%s' "$installed")"
        else
          echo "     ❌ Échec d'intégration: $base"
        fi
      fi

      # Tente une MAJ immédiate si source détectable
      $GL_CMD --update $GL_YES "$f" >/dev/null 2>&1 || true
    fi
  done < <(find "$appdir" -maxdepth 1 -type f \( -iname '*.AppImage' -o -perm -u+x \) ! -iname '*.zsync' -print0)

  echo "[INFO] Récap des mises à jour disponibles…"
  $GL_CMD --list-updates || true
}

integrate_and_update_appimages

echo "[OK] External AppImages installed"

echo "[OK] Application installation step complete."
