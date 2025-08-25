#!/usr/bin/env bash
set -euo pipefail
# Step 6 — Switch to greetd + tuigreet (from Fedora repos), simple & clean

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set}"

echo "[INFO] Installing greetd + tuigreet"
as_root "dnf -y install greetd tuigreet"

echo "[INFO] Writing /etc/tuigreet.toml"
as_root "install -D -m 0644 /dev/null /etc/tuigreet.toml"
as_root "tee /etc/tuigreet.toml >/dev/null <<'TOML'
# /etc/tuigreet.toml
# Tuigreet config (mirrors most CLI flags). Keep it minimal and reliable.
time = true                # show clock
remember = true            # remember last username
remember_session = true    # remember last session chosen
asterisks = true           # hide password chars

# Let tuigreet offer both Wayland and Xorg sessions from system .desktop files:
sessions = [
  "/usr/share/wayland-sessions",
  "/usr/share/xsessions",
]

# Optional: show a user menu (handy on multi-user systems)
user_menu = true

# Tip: no default cmd here -> when you pick a session from the list,
# tuigreet will launch that session's Exec from the .desktop file.
TOML"

echo "[INFO] Writing /etc/greetd/config.toml"
as_root "install -D -m 0644 /dev/null /etc/greetd/config.toml"
as_root "tee /etc/greetd/config.toml >/dev/null <<'TOML'
# /etc/greetd/config.toml
# Minimal greetd config that runs tuigreet with our TOML.
[terminal]
vt = 1

[default_session]
# Use the TOML above; still pass sessions paths explicitly (belt & suspenders)
command = \"/usr/bin/tuigreet --config /etc/tuigreet.toml --sessions /usr/share/wayland-sessions:/usr/share/xsessions\"
user = \"greeter\"
TOML"

echo "[INFO] Enabling greetd (and disabling GDM if present)"
disable_service gdm.service || true
enable_service greetd.service

echo "[INFO] Setting graphical target as default"
as_root "systemctl set-default graphical.target"

echo "[OK] greetd + tuigreet installed and enabled. Reboot to test the greeter."
