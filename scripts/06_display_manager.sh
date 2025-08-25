#!/usr/bin/env bash
set -euo pipefail
# Step 6 — greetd + tuigreet (Fedora repos), staging safe by default

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set}"
: "${ROOT_DIR:?ROOT_DIR must be set}"  # normalement défini dans 00_helpers.sh

echo "[INFO] Installing greetd + tuigreet"
as_root "dnf -y install greetd tuigreet"

echo "[INFO] Deploying configs"
as_root "install -D -m 0644 '$ROOT_DIR/config/greetd/config.toml' /etc/greetd/config.toml"
as_root "sed -i 's/__TARGET_USER__/$TARGET_USER/g' /etc/greetd/config.toml"
as_root "install -D -m 0644 '$ROOT_DIR/config/tuigreet/tuigreet.toml' /etc/tuigreet.toml"


echo "[INFO] Checking sessions directories"
if ! as_root "test -d /usr/share/wayland-sessions || test -d /usr/share/xsessions"; then
  echo '[WARN] No sessions directories found. Install at least one session (e.g., hyprland).'
fi
# Sanity: list found .desktop sessions
as_root "sh -c 'ls -1 /usr/share/wayland-sessions/*.desktop 2>/dev/null || true'"
as_root "sh -c 'ls -1 /usr/share/xsessions/*.desktop 2>/dev/null || true'"

# Don’t bounce current session by default
if [[ "${APPLY_NOW:-0}" = "1" ]]; then
  echo "[INFO] Enabling greetd now (this will kill current graphical session)"
  disable_service gdm.service || true
  enable_service greetd.service
  as_root "systemctl set-default graphical.target"
  # Redémarrer le target graphique (optionnel; sinon reboot)
  # as_root "systemctl isolate graphical.target"
  echo "[OK] greetd enabled. Reboot recommended."
else
  echo "[INFO] Staging only: will enable greetd at next boot."
  disable_service gdm.service || true
  as_root "systemctl enable greetd.service"
  as_root "systemctl set-default graphical.target"
  echo "[OK] Ready. Reboot when you’re ready to switch to greetd."
fi

echo "[HINT] If you get a black screen, check: journalctl -u greetd -b -e"
