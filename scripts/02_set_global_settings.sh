#!/usr/bin/env bash
set -euo pipefail
# Step — Dark mode, locales/metrics/clock (agnostic), layout (GNOME)

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set (from .env or sudo env)}"
UHOME="$(user_home "$TARGET_USER")"

# .env inputs
: "${LANG_DEFAULT:?Missing LANG_DEFAULT in .env}"     # e.g., en_US.UTF-8
: "${FORMATS:?Missing FORMATS in .env}"               # e.g., fr_FR.UTF-8
: "${CLOCK_FORMAT:?Missing CLOCK_FORMAT in .env}"     # "24h" or "12h" (GNOME only)
: "${KEYBOARD_LAYOUT:?Missing KEYBOARD_LAYOUT in .env}"     # e.g., fr, us
: "${KEYBOARD_VARIANT:?Missing KEYBOARD_VARIANT in .env}"   # e.g., oss or ""
: "${KEYBOARD_OPTIONS:?Missing KEYBOARD_OPTIONS in .env}"   # e.g., "caps:escape" or ""

# Build XKB id (used for GNOME path; harmless elsewhere)
_XKB_ID="$KEYBOARD_LAYOUT"
if [[ -n "${KEYBOARD_VARIANT}" ]]; then
  _XKB_ID="${KEYBOARD_LAYOUT}+${KEYBOARD_VARIANT}"
fi

######## 1) Themes (GTK) & Dark mode ########
as_root "dnf install -y adw-gtk3-theme"

# GNOME/libadwaita → dark mode (no effect outside GNOME, harmless otherwise)
as_user "dbus-run-session gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true"

# Icons & cursor (GNOME)
as_user "dbus-run-session gsettings set org.gnome.desktop.interface icon-theme 'Adwaita' || true"
as_user "dbus-run-session gsettings set org.gnome.desktop.interface cursor-theme 'Adwaita' || true"

# GTK3 apps → adw-gtk3-dark (GNOME/GTK3)
as_user "dbus-run-session gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark' || true"

# GTK outside GNOME: prefer-dark via settings.ini
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

######## 2) Locales / formats / units (agnostic, works for quickshell too) ########
# These variables are read at login by systemd --user (GNOME, Hyprland, etc.)
as_user "mkdir -p ~/.config/environment.d"
as_user "bash -lc 'cat > ~/.config/environment.d/10-locales.conf <<EOF
LANG=${LANG_DEFAULT}
LC_TIME=${FORMATS}            # e.g., fr_FR.UTF-8 → 24h clock
LC_MEASUREMENT=${FORMATS}     # e.g., fr_FR.UTF-8 → metric units
LC_NUMERIC=${FORMATS}
LC_MONETARY=${FORMATS}
LC_PAPER=${FORMATS}
LC_NAME=${FORMATS}
LC_ADDRESS=${FORMATS}
LC_TELEPHONE=${FORMATS}
EOF'"

# (optional) Generic Wayland cursor
as_user "bash -lc 'cat > ~/.config/environment.d/20-cursor.conf <<EOF
XCURSOR_THEME=${XCURSOR_THEME:-Adwaita}
XCURSOR_SIZE=${XCURSOR_SIZE:-24}
EOF'"

# GNOME only: region & clock format (no effect outside GNOME/quickshell)
as_user "dbus-run-session gsettings set org.gnome.system.locale region '${FORMATS}' || true"
as_user "dbus-run-session gsettings set org.gnome.desktop.interface clock-format '${CLOCK_FORMAT}' || true"

######## 3) Keyboard layout (GNOME only at this stage) ########

# sources = [ ('xkb', '<layout+variant>') ]
# We send a single string to as_user via $'...'
# Internal single quotes are escaped as \'
as_user "dbus-run-session gsettings set org.gnome.desktop.input-sources sources \"[('xkb', '$_XKB_ID')]\" || true"

# xkb-options if provided, e.g.: "caps:escape,compose:rctrl"
if [[ -n "${KEYBOARD_OPTIONS}" ]]; then
  _opts_quoted="${KEYBOARD_OPTIONS//,/','}"
  as_user "dbus-run-session gsettings set org.gnome.desktop.input-sources xkb-options \"['${_opts_quoted}']\" || true"
fi

######## 4) Application tips ########
echo "[OK] Locales/metrics/clock (agnostic), GTK dark, and GNOME layout applied for $TARGET_USER."
echo "     Log out and back in so environment.d is taken into account."
echo "     Under GNOME: settings are active. Under quickshell/non-GNOME: 24h + metric via LC_*."
