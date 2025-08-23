#!/usr/bin/env bash
set -euo pipefail
# Enable the chosen Display Manager (Ly by default), disable others.
# Runs as user; uses as_root/enable_service/disable_service from helpers.

. "$(dirname "$0")/00_helpers.sh"

DM_CHOICE="${DM:-ly}"

echo "[INFO] Display Manager requested: $DM_CHOICE"

case "$DM_CHOICE" in
  ly)
    # 1) Install Ly (expects repo availability; add COPR to lists/coprs.txt if needed)
    as_root "dnf -y install ly || true"

    # 2) Deploy config
    as_root "mkdir -p /etc/ly"
    if [[ -f \"$ROOT_DIR/config/ly/config.ini\" ]]; then
      as_root "install -m 0644 \"$ROOT_DIR/config/ly/config.ini\" /etc/ly/config.ini"
    fi

    # 3) Disable GDM and enable Ly
    disable_service gdm.service
    enable_service ly.service

    # 4) Make sure we boot to graphical target
    as_root "systemctl set-default graphical.target"
    echo '[OK] Ly enabled (gdm disabled).'
    ;;

  greetd)
    # Optional alternative if you switch DM in .env
    as_root "dnf -y install greetd tuigreet"
    as_root "mkdir -p /etc/greetd"
    if [[ -f \"$ROOT_DIR/config/greetd/config.toml\" ]]; then
      as_root "install -m 0644 \"$ROOT_DIR/config/greetd/config.toml\" /etc/greetd/config.toml"
    fi
    disable_service gdm.service
    enable_service greetd.service
    as_root "systemctl set-default graphical.target"
    echo '[OK] greetd (tuigreet) enabled (gdm disabled).'
    ;;

  gdm)
    # In case you want to revert to GDM
    as_root "dnf -y install gdm"
    disable_service ly.service
    disable_service greetd.service
    enable_service gdm.service
    as_root "systemctl set-default graphical.target"
    echo '[OK] GDM enabled (others disabled).'
    ;;

  *)
    echo "ERROR: Unknown DM '$DM_CHOICE'. Set DM=ly|greetd|gdm in .env." >&2
    exit 1
    ;;
esac
