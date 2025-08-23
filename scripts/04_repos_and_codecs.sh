#!/usr/bin/env bash
set -euo pipefail
# Enable RPMFusion (free+nonfree), update groups, install codecs, add Flathub system-wide, enable COPRs.

. "$(dirname "$0")/00_helpers.sh"

# RPMFusion
as_root "bash -lc '
  if ! rpm -q rpmfusion-free-release &>/dev/null; then
    ver=\$(rpm -E %fedora)
    dnf -y install \
      https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-\$ver.noarch.rpm \
      https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-\$ver.noarch.rpm
  fi
'"

# Core group refresh
#as_root "dnf -y groupupdate core"

# Multimedia codecs
as_root "dnf -y install \
  gstreamer1-plugins-good \
  gstreamer1-plugins-bad-free \
  gstreamer1-plugins-bad-freeworld \
  gstreamer1-plugins-ugly \
  gstreamer1-plugin-openh264 \
  lame\*"

# Flathub (system-wide)
as_root "flatpak --system remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true"

# COPRs from list
while read -r c; do
  [[ -z "${c// /}" || "$c" =~ ^# ]] && continue
  as_root "dnf -y copr enable $c || true"
done < <(apply_list "$ROOT_DIR/lists/coprs.txt")

echo "[OK] Repos and codecs ready."
