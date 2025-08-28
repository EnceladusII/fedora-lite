#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$DIR/.." && pwd)"

. "$DIR/00_helpers.sh"

banner() { printf "\n==== %s ====\n" "$1"; }

confirm() {
  while true; do
    read -rp "Proceed to the next step? (y/n) " answer
    case "$answer" in
      [Yy]* ) break ;;
      [Nn]* ) echo "Aborted."; exit 1 ;;
      * ) echo "Please answer y or n." ;;
    esac
  done
}

# Steps list
STEPS=(
  "01_config_dnf"
  "02_set_global_settings"
  "03_remove_bloat"
  "04_repos_and_codecs"
  "05_gpu_drivers"
  "06_display_manager"
  "07_install_dots"
  "08_install_apps"
  "09_boot_optimize"
  "10_ai_stack"
)

for s in "${STEPS[@]}"; do
  script="$DIR/$s.sh"
  if [[ ! -e "$script" ]]; then
    echo "[WARN] Missing: $script — skipping."
    continue
  fi
  if [[ ! -x "$script" ]]; then
    echo "[WARN] Not executable: $script — try: chmod +x \"$script\". Skipping."
    continue
  fi

  banner "$s"
  bash "$script"
  confirm
done

banner "All steps completed!"
