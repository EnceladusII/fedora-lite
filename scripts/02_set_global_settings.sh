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
as_user "dnf install -y adw-gtk3-theme"

# GNOME/libadwaita → mode sombre global
as_user "dbus-run-session gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'"

# Icônes et curseur par défaut
as_user "dbus-run-session gsettings set org.gnome.desktop.interface icon-theme 'Adwaita'"
as_user "dbus-run-session gsettings set org.gnome.desktop.interface cursor-theme 'Adwaita'"

# Legacy apps (GTK3) → utiliser adw-gtk3-dark
as_user "dbus-run-session gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark'"

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
