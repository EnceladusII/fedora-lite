#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$DIR/.." && pwd)"

. "$DIR/00_helpers.sh"

banner() { printf "\n==== %s ====\n" "$1"; }

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
  if [[ -x "$script" ]]; then
    banner "$s"
    bash "$script"
  else
    echo "[WARN] Missing or non-executable: $script — skipping."
  fi
done

banner "done"
