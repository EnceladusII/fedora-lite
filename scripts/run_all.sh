#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$DIR/.." && pwd)"

# Petit helper d'affichage
banner() { printf "\n==== %s ====\n" "$1"; }

# Liste des étapes dans l’ordre recommandé
# (03 vérifie et installe un terminal avant de retirer ptyxis si nécessaire)
STEPS=(
  "01_config_dnf"
  "02_enable_dark_mode"
  "03_remove_bloat"
  "04_repos_and_codecs"
  "05_gpu_drivers"
  "07_install_dots"
  "06_display_manager"
  "08_install_apps"
  "09_boot_optimize"
  "10_ai_stack"
)

for s in "${STEPS[@]}"; do
  script="$DIR/$s.sh"
  if [[ -x "$script" ]]; then
    banner "$s"
    bash "$script"
  else
    echo "[WARN] Missing or non-executable: $script — skipping."
  fi
done

banner "done"
