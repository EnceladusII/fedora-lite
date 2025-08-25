#!/usr/bin/env bash
set -euo pipefail
# Enable RPMFusion (free+nonfree), update groups, install codecs, add Flathub system-wide, enable COPRs.

. "$(dirname "$0")/00_helpers.sh"

# RPMFusion
as_root "dnf -y install \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"

as_root "dnf config-manager setopt fedora-cisco-openh264.enabled=1"

# Core group refresh
as_root "dnf -y update @core"

# Multimedia codecs
as_root "dnf -y install \
  gstreamer1-plugins-good \
  gstreamer1-plugins-bad-free \
  gstreamer1-plugins-bad-freeworld \
  gstreamer1-plugins-ugly \
  gstreamer1-plugin-openh264 \
  ffmpeg-free \
  lame\*"

# Flathub (system-wide)
as_root "flatpak --system remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true"

# COPRs from list
while read -r c; do
  [[ -z "${c// /}" || "$c" =~ ^# ]] && continue
  as_root "dnf -y copr enable $c || true"
done < <(apply_list "$ROOT_DIR/lists/coprs.txt")

echo "[OK] Repos and codecs ready."
