#!/usr/bin/env bash
set -euo pipefail
# Step 2 — Dark mode (system+user), locales/mesures/heure, clavier (system+user)

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set (from .env or sudo env)}"
UHOME="$(user_home "$TARGET_USER")"

: "${LANG_DEFAULT:?Missing LANG_DEFAULT in .env}"
: "${LC_TIME:?Missing LC_TIME in .env}"
: "${LC_NUMERIC:?Missing LC_NUMERIC in .env}"
: "${LC_MEASUREMENT:?Missing LC_MEASUREMENT in .env}"
: "${LC_PAPER:?Missing LC_PAPER in .env}"
: "${CLOCK_FORMAT:?Missing CLOCK_FORMAT in .env}"

: "${KEYBOARD_LAYOUT:?Missing KEYBOARD_LAYOUT in .env}"
: "${KEYBOARD_VARIANT:?Missing KEYBOARD_VARIANT in .env}"
: "${KEYBOARD_OPTIONS:?Missing KEYBOARD_OPTIONS in .env}"

# Construct ID XKB for gsettings (ex: "fr+oss" / "us")
_XKB_ID="$KEYBOARD_LAYOUT"
if [[ -n "$KEYBOARD_VARIANT" ]]; then
  _XKB_ID="${KEYBOARD_LAYOUT}+${KEYBOARD_VARIANT}"
fi

# 1) Dark mode — defaults système via dconf + fallbacks GTK

install -d -m 0755 /etc/dconf/{db,profile}
if ! grep -q "^system-db:local$" /etc/dconf/profile/user 2>/dev/null; then
  cat >/etc/dconf/profile/user <<'PROFILE'
user-db:user
system-db:local
PROFILE
fi

install -d -m 0755 /etc/dconf/db/local.d
cat >/etc/dconf/db/local.d/00-fedora-autoconfig-dark <<'DCONF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'
gtk-theme='Adwaita-dark'
icon-theme='Adwaita'
DCONF

dconf update

# Fallbacks GTK système
install -d -m 0755 /etc/gtk-3.0 /etc/gtk-4.0
cat >/etc/gtk-3.0/settings.ini <<'INI'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=Adwaita
INI
cat >/etc/gtk-4.0/settings.ini <<'INI'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
INI

# Hint environnement pour GTK3 "récalcitrantes"
install -d -m 0755 /etc/environment.d
cat >/etc/environment.d/99-gtk-dark.conf <<'ENV'
GTK_THEME=Adwaita:dark
GTK_ICON_THEME=Adwaita
ENV

# 2) Locals / formats / units — system + per-user

# System
localectl set-locale \
  "LANG=${LANG_DEFAULT}" \
  "LC_TIME=${LC_TIME}" \
  "LC_NUMERIC=${LC_NUMERIC}" \
  "LC_MEASUREMENT=${LC_MEASUREMENT}" \
  "LC_PAPER=${LC_PAPER}"

# Per-user: environment.d to force/align
as_user "mkdir -p ~/.config/environment.d"
as_user "bash -lc 'cat > ~/.config/environment.d/10-locales.conf <<EOF
LANG=${LANG_DEFAULT}
LC_TIME=${LC_TIME}
LC_NUMERIC=${LC_NUMERIC}
LC_MEASUREMENT=${LC_MEASUREMENT}
LC_PAPER=${LC_PAPER}
EOF'"

# GNOME: clock format
as_user "dbus-run-session gsettings set org.gnome.desktop.interface clock-format '${CLOCK_FORMAT}' || true"

# 3) Clavier — system + per-user (GNOME input sources)

# Systeme (consol + X11 by default)
if [[ -n "$KEYBOARD_OPTIONS" ]]; then
  localectl set-x11-keymap "$KEYBOARD_LAYOUT" "" "$KEYBOARD_VARIANT" "$KEYBOARD_OPTIONS"
else
  localectl set-x11-keymap "$KEYBOARD_LAYOUT" "" "$KEYBOARD_VARIANT"
fi

# Per-user: GNOME input sources
# sources = [('xkb', 'fr+oss')] ou [('xkb', 'us')]
as_user "dbus-run-session gsettings set org.gnome.desktop.input-sources sources \"[('xkb', '$_XKB_ID')]\" || true"

# Options
if [[ -n "$KEYBOARD_OPTIONS" ]]; then
  as_user "dbus-run-session gsettings set org.gnome.desktop.input-sources xkb-options \"['${KEYBOARD_OPTIONS//,/','}']\" || true"
fi

# 4) Per-user — enforcement dark mode

as_user "dbus-run-session gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true"
as_user "dbus-run-session gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark' || true"
as_user "dbus-run-session gsettings set org.gnome.desktop.interface icon-theme 'Adwaita' || true"

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

# Per-user: hint GTK
as_user "bash -lc 'cat > ~/.config/environment.d/99-gtk-dark.conf <<\"ENV\"
GTK_THEME=Adwaita:dark
GTK_ICON_THEME=Adwaita
ENV'"

echo "[OK] Dark mode (system+user), locals/metrics/clock & keyboard layout are configured. PLS reboot your system"
