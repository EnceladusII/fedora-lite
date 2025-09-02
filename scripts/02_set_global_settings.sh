#!/usr/bin/env bash
set -euo pipefail
# Step — Dark mode, locales/metrics/clock (agnostique), layout (GNOME)

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set (from .env or sudo env)}"
UHOME="$(user_home "$TARGET_USER")"

# .env inputs
: "${LANG_DEFAULT:?Missing LANG_DEFAULT in .env}"     # ex: en_US.UTF-8
: "${FORMATS:?Missing FORMATS in .env}"               # ex: fr_FR.UTF-8
: "${CLOCK_FORMAT:?Missing CLOCK_FORMAT in .env}"     # "24h" ou "12h" (GNOME uniquement)
: "${KEYBOARD_LAYOUT:?Missing KEYBOARD_LAYOUT in .env}"     # ex: fr, us
: "${KEYBOARD_VARIANT:?Missing KEYBOARD_VARIANT in .env}"   # ex: oss ou ""
: "${KEYBOARD_OPTIONS:?Missing KEYBOARD_OPTIONS in .env}"   # ex: "caps:escape" ou ""

# Build XKB id (for GNOME path; harmless elsewhere)
_XKB_ID="$KEYBOARD_LAYOUT"
if [[ -n "${KEYBOARD_VARIANT}" ]]; then
  _XKB_ID="${KEYBOARD_LAYOUT}+${KEYBOARD_VARIANT}"
fi

######## 1) Thèmes (GTK) & Dark mode ########
as_root "dnf install -y adw-gtk3-theme"

# GNOME/libadwaita → dark mode (no effect outside GNOME, but harmless)
as_user "dbus-run-session gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true"

# Icônes & curseur (GNOME)
as_user "dbus-run-session gsettings set org.gnome.desktop.interface icon-theme 'Adwaita' || true"
as_user "dbus-run-session gsettings set org.gnome.desktop.interface cursor-theme 'Adwaita' || true"

# Apps GTK3 → adw-gtk3-dark (GNOME/GTK3)
as_user "dbus-run-session gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark' || true"

# GTK hors GNOME : prefer-dark via settings.ini
as_user "mkdir -p ~/.config/gtk-3.0 ~/.config/gtk-4.0"
as_user "bash -lc 'cat > ~/.config/gtk-3.0/settings.ini <<EOF
[Settings]
gtk-application-prefer-dark-theme=1
gtk-theme-name=adw-gtk3-dark
gtk-icon-theme-name=Adwaita
gtk-cursor-theme-name=Adwaita
EOF'"
as_user "bash -lc 'cat > ~/.config/gtk-4.0/settings.ini <<EOF
[Settings]
gtk-application-prefer-dark-theme=1
gtk-icon-theme-name=Adwaita
gtk-cursor-theme-name=Adwaita
EOF'"

######## 2) Locales / formats / unités (agnostique, valable pour quickshell) ########
# Ces variables sont lues au login par systemd --user (GNOME, Hyprland, etc.)
as_user "mkdir -p ~/.config/environment.d"
as_user "bash -lc 'cat > ~/.config/environment.d/10-locales.conf <<EOF
LANG=${LANG_DEFAULT}
LC_TIME=${FORMATS}            # ex: fr_FR.UTF-8 -> horloge 24h
LC_MEASUREMENT=${FORMATS}     # ex: fr_FR.UTF-8 -> unités métriques
LC_NUMERIC=${FORMATS}
LC_MONETARY=${FORMATS}
LC_PAPER=${FORMATS}
LC_NAME=${FORMATS}
LC_ADDRESS=${FORMATS}
LC_TELEPHONE=${FORMATS}
EOF'"

# (facultatif) Curseur Wayland générique
as_user "bash -lc 'cat > ~/.config/environment.d/20-cursor.conf <<EOF
XCURSOR_THEME=${XCURSOR_THEME:-Adwaita}
XCURSOR_SIZE=${XCURSOR_SIZE:-24}
EOF'"

# GNOME uniquement : région & format d’horloge (sans effet pour quickshell/hors GNOME)
as_user "dbus-run-session gsettings set org.gnome.system.locale region '${FORMATS}' || true"
as_user "dbus-run-session gsettings set org.gnome.desktop.interface clock-format '${CLOCK_FORMAT}' || true"

######## 3) Keyboard layout (GNOME uniquement à ce stade) ########

# sources = [ ('xkb', '<layout+variant>') ]
# On envoie UNE seule chaîne à as_user grâce à $'...'
# Les quotes simples internes sont représentées par \'
as_user "dbus-run-session gsettings set org.gnome.desktop.input-sources sources \"[('xkb', '$_XKB_ID')]\" || true"

# xkb-options si fourni, ex: "caps:escape,compose:rctrl"
if [[ -n "${KEYBOARD_OPTIONS}" ]]; then
  _opts_quoted="${KEYBOARD_OPTIONS//,/','}"
  as_user "dbus-run-session gsettings set org.gnome.desktop.input-sources xkb-options \"['${_opts_quoted}']\" || true"
fi

######## 4) Conseils d’application ########
echo "[OK] Locales/metrics/clock (agnostique), GTK dark, et layout GNOME appliqués pour $TARGET_USER."
echo "     Déconnexion/reconnexion recommandée pour que environment.d soit pris en compte."
echo "     Sous GNOME: réglages actifs. Sous quickshell/hors GNOME: 24h + métrique via LC_*."
