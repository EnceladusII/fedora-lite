#!/usr/bin/env bash
set -euo pipefail
# Apply dark mode for GNOME + GTK fallbacks as TARGET_USER (no root needed)

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set (from .env or sudo env)}"
UHOME="$(user_home "$TARGET_USER")"

# GNOME / libadwaita
as_user "dbus-run-session gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true"
as_user "dbus-run-session gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark' || true"
as_user "dbus-run-session gsettings set org.gnome.desktop.interface icon-theme 'Adwaita' || true"

# GTK fallbacks (write as the user to avoid chown later)
as_user "mkdir -p ~/.config/gtk-3.0 ~/.config/gtk-4.0"

as_user "bash -lc 'cat > ~/.config/gtk-3.0/settings.ini <<\"INI\"
[Settings]
gtk-theme-name=Adwaita-dark
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=Adwaita
INI'"

as_user "bash -lc 'cat > ~/.config/gtk-4.0/settings.ini <<\"INI\"
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
INI'"

echo "[OK] Dark mode applied for $TARGET_USER (gsettings + GTK fallbacks)."
