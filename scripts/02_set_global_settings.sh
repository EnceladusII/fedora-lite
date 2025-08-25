#!/usr/bin/env bash
set -euo pipefail
# Step 2 — Dark mode, locals/metrics/clock, layout (per-user only)

. "$(dirname "$0")/00_helpers.sh"

: "${TARGET_USER:?TARGET_USER must be set (from .env or sudo env)}"
UHOME="$(user_home "$TARGET_USER")"

# Check .env input variables
: "${LANG_DEFAULT:?Missing LANG_DEFAULT in .env}"   # ex: en_US.UTF-8
: "${FORMATS:?Missing FORMATS in .env}"             # ex: fr_FR.UTF-8
: "${CLOCK_FORMAT:?Missing CLOCK_FORMAT in .env}"   # ex: 24h ou 12h"

: "${KEYBOARD_LAYOUT:?Missing KEYBOARD_LAYOUT in .env}"
: "${KEYBOARD_VARIANT:?Missing KEYBOARD_VARIANT in .env}"   # peut être ""
: "${KEYBOARD_OPTIONS:?Missing KEYBOARD_OPTIONS in .env}"   # peut être ""

# ID XKB for gsettings (ex: "fr+oss" or "us")
_XKB_ID="$KEYBOARD_LAYOUT"
if [[ -n "$KEYBOARD_VARIANT" ]]; then
  _XKB_ID="${KEYBOARD_LAYOUT}+${KEYBOARD_VARIANT}"
fi

# 1) Dark mode (per-user)
as_root "dnf install -y adw-gtk3-theme"

# GNOME/libadwaita → dark mode
as_user "dbus-run-session gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'"

# Icons & cursor
as_user "dbus-run-session gsettings set org.gnome.desktop.interface icon-theme 'Adwaita'"
as_user "dbus-run-session gsettings set org.gnome.desktop.interface cursor-theme 'Adwaita'"

# Legacy apps (GTK3) → adw-gtk3-dark
as_user "dbus-run-session gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark'"

# 2) Locals / formats / units (per-user)
# a) Formats — gsettings org.gnome.system.locale::region
as_user "dbus-run-session gsettings set org.gnome.system.locale region '${FORMATS}' || true"

# b) Clocks format (optionnel)
as_user "dbus-run-session gsettings set org.gnome.desktop.interface clock-format '${CLOCK_FORMAT}' || true"

# c) Language — per-user via environment.d
as_user "mkdir -p ~/.config/environment.d"
as_user "bash -lc 'cat > ~/.config/environment.d/10-locales.conf <<EOF
LANG=${LANG_DEFAULT}
EOF'"

# 3) Keyboard Layout (per-user)
# Input sources GNOME
as_user "dbus-run-session gsettings set org.gnome.desktop.input-sources sources \"[('xkb', '$_XKB_ID')]\" || true"

# Options layout (ex: caps:escape)
if [[ -n "$KEYBOARD_OPTIONS" ]]; then
  as_user "dbus-run-session gsettings set org.gnome.desktop.input-sources xkb-options \"['${KEYBOARD_OPTIONS//,/','}']\" || true"
fi

echo "[OK] Dark mode, locals/metrics/clock et layout apply for $TARGET_USER."
echo "     Log-out highly recommended to apply changes."
