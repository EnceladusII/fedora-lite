#!/usr/bin/env bash
set -euo pipefail
# Step 2 — Dark mode, locales/mesures/heure, clavier (per-user only)

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set (from .env or sudo env)}"
UHOME="$(user_home "$TARGET_USER")"

# Variables .env obligatoires
: "${LANG_DEFAULT:?Missing LANG_DEFAULT in .env}"
: "${LC_TIME:?Missing LC_TIME in .env}"
: "${LC_NUMERIC:?Missing LC_NUMERIC in .env}"
: "${LC_MEASUREMENT:?Missing LC_MEASUREMENT in .env}"
: "${LC_PAPER:?Missing LC_PAPER in .env}"
: "${CLOCK_FORMAT:?Missing CLOCK_FORMAT in .env}"

: "${KEYBOARD_LAYOUT:?Missing KEYBOARD_LAYOUT in .env}"
: "${KEYBOARD_VARIANT:?Missing KEYBOARD_VARIANT in .env}"   # peut être ""
: "${KEYBOARD_OPTIONS:?Missing KEYBOARD_OPTIONS in .env}"   # peut être ""

# ID XKB pour gsettings (ex: "fr+oss" ou "us")
_XKB_ID="$KEYBOARD_LAYOUT"
if [[ -n "$KEYBOARD_VARIANT" ]]; then
  _XKB_ID="${KEYBOARD_LAYOUT}+${KEYBOARD_VARIANT}"
fi

###############################################################################
# 1) Dark mode (per-user)
###############################################################################
as_user "dbus-run-session gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true"
as_user "dbus-run-session gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark' || true"
as_user "dbus-run-session gsettings set org.gnome.desktop.interface icon-theme 'Adwaita' || true"

# GTK fallbacks dans ~/.config
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

# Hint GTK via environment.d
as_user "mkdir -p ~/.config/environment.d"
as_user "bash -lc 'cat > ~/.config/environment.d/99-gtk-dark.conf <<\"ENV\"
GTK_THEME=Adwaita:dark
GTK_ICON_THEME=Adwaita
ENV'"

###############################################################################
# 2) Locales / formats / unités (per-user)
###############################################################################
as_user "bash -lc 'cat > ~/.config/environment.d/10-locales.conf <<EOF
LANG=${LANG_DEFAULT}
LC_TIME=${LC_TIME}
LC_NUMERIC=${LC_NUMERIC}
LC_MEASUREMENT=${LC_MEASUREMENT}
LC_PAPER=${LC_PAPER}
EOF'"

# GNOME: format d’horloge
as_user "dbus-run-session gsettings set org.gnome.desktop.interface clock-format '${CLOCK_FORMAT}' || true"

###############################################################################
# 3) Clavier (per-user)
###############################################################################
# Input sources GNOME
as_user "dbus-run-session gsettings set org.gnome.desktop.input-sources sources \"[('xkb', '$_XKB_ID')]\" || true"

# Options clavier (ex: caps:escape)
if [[ -n "$KEYBOARD_OPTIONS" ]]; then
  as_user "dbus-run-session gsettings set org.gnome.desktop.input-sources xkb-options \"['${KEYBOARD_OPTIONS//,/','}']\" || true"
fi

echo "[OK] Dark mode, locales/mesures/heure et clavier appliqués pour $TARGET_USER."
echo "     Déconnexion/reconnexion recommandée pour appliquer les changements."
