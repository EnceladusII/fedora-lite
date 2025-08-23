#!/usr/bin/env bash
set -euo pipefail
# Remove unwanted preinstalled packages listed in lists/remove-packages.txt
# Runs dnf via as_root; safe to re-run. Ensures a terminal exists if removing ptyxis.

. "$(dirname "$0")/00_helpers.sh"

LIST="$ROOT_DIR/lists/remove-packages.txt"
[[ -f "$LIST" ]] || { echo "[INFO] No list at $LIST — nothing to remove."; exit 0; }

to_remove=()
skipped=()

# Safety: if the list contains 'ptyxis', ensure preferred terminal is installed first
wants_remove_ptyxis=0

while IFS= read -r p; do
  [[ -z "${p// /}" || "$p" =~ ^# ]] && continue
  pkg="${p%% *}"
  if [[ "$pkg" == "ptyxis" ]]; then wants_remove_ptyxis=1; fi
  if pkg_installed "$pkg"; then
    to_remove+=("$pkg")
  else
    skipped+=("$pkg")
  fi
done < <(apply_list "$LIST")

if (( wants_remove_ptyxis == 1 )); then
  # Ensure we have a terminal before removing the default one on Fedora 41+
  term_pkg="${TERMINAL:-foot}"
  if ! pkg_installed "$term_pkg"; then
    echo "[INFO] Installing terminal '$term_pkg' before removing ptyxis..."
    as_root "dnf -y install $term_pkg"
  fi
fi

if ((${#to_remove[@]})); then
  echo "[INFO] Removing ${#to_remove[@]} packages:"
  printf '  - %s\n' "${to_remove[@]}"
  as_root "dnf -y remove --setopt=clean_requirements_on_remove=1 ${to_remove[*]}"
  as_root "dnf -y autoremove || true"
else
  echo "[INFO] Nothing to remove from list."
fi

if ((${#skipped[@]})); then
  echo "[INFO] Not currently installed (skipped):"
  printf '  - %s\n' "${skipped[@]}"
fi

echo "[OK] Bloat removal completed."
