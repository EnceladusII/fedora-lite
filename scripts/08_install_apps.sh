#!/usr/bin/env bash
set -euo pipefail
# Install favorite apps from lists/{rpm-packages.txt, flatpaks.txt, appimages.txt}
# Runs as user, elevates only with as_root when required.

. "$(dirname "$0")/00_helpers.sh"

# --- RPM packages ---
RPM_LIST="$ROOT_DIR/lists/rpm-packages.txt"
if [[ -f "$RPM_LIST" ]]; then
  pkgs=()
  while IFS= read -r p; do
    [[ -z "${p// /}" || "$p" =~ ^# ]] && continue
    if ! pkg_installed "$p"; then
      pkgs+=("$p")
    fi
  done < <(apply_list "$RPM_LIST")

  if ((${#pkgs[@]})); then
    echo "[INFO] Installing RPM packages: ${pkgs[*]}"
    as_root "dnf -y install ${pkgs[*]}"
  else
    echo "[INFO] No new RPM packages to install."
  fi
fi

# --- Flatpaks (system-wide install) ---
FLAT_LIST="$ROOT_DIR/lists/flatpaks.txt"
if [[ -f "$FLAT_LIST" ]]; then
  while IFS= read -r app; do
    [[ -z "${app// /}" || "$app" =~ ^# ]] && continue
    if ! flatpak list --system | grep -q "$app"; then
      echo "[INFO] Installing Flatpak: $app"
      as_root "flatpak install -y flathub $app"
    fi
  done < <(apply_list "$FLAT_LIST")
fi

# --- AppImages ---
APPIMG_LIST="$ROOT_DIR/lists/appimages.txt"
if [[ -f "$APPIMG_LIST" ]]; then
  APPDIR="$(user_home "$TARGET_USER")/Applications"
  as_user "mkdir -p '$APPDIR'"
  while IFS= read -r line; do
    [[ -z "${line// /}" || "$line" =~ ^# ]] && continue
    url="$line"
    fname="${url##*/}"
    target="$APPDIR/$fname"
    if [[ ! -f "$target" ]]; then
      echo "[INFO] Downloading AppImage: $url"
      as_user "curl -L -o '$target' '$url'"
      as_user "chmod +x '$target'"
    fi
  done < <(apply_list "$APPIMG_LIST")
fi

echo "[OK] Application installation step complete."
