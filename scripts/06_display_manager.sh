#!/usr/bin/env bash
set -euo pipefail
# Step 6 — Deploy greetd + tuigreet with separate TOML files and prefilled user

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set}"
: "${ROOT_DIR:?ROOT_DIR must be set}"

echo "[INFO] Installing greetd + tuigreet"
as_root "dnf -y install greetd tuigreet"

echo "[INFO] Deploying TOML configs"
as_root "install -D -m 0644 \"$ROOT_DIR/config/tuigreet/tuigreet.toml\" /etc/tuigreet.toml"
as_root "install -D -m 0644 \"$ROOT_DIR/config/greetd/config.toml\"  /etc/greetd/config.toml"
# Remplace le placeholder par la vraie valeur
as_root "sed -i \"s/__TARGET_USER__/$TARGET_USER/g\" /etc/greetd/config.toml"

# (SELinux) Assure les bons contextes si actifs
as_root "restorecon -RF /etc/greetd /etc/tuigreet.toml || true"

echo "[INFO] Checking available sessions"
as_root "sh -c 'ls -1 /usr/share/wayland-sessions/*.desktop 2>/dev/null || echo \"(no wayland sessions)\"'"
as_root "sh -c 'ls -1 /usr/share/xsessions/*.desktop       2>/dev/null || echo \"(no x sessions)\"'"

echo "[INFO] Enable greetd for next boot"
disable_service gdm.service || true
as_root "systemctl enable greetd.service"
as_root "systemctl set-default graphical.target"

echo '[OK] Ready. Reboot to use tuigreet. If black screen: `journalctl -u greetd -b -e`'
