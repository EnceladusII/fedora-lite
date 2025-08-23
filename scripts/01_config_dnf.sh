#!/usr/bin/env bash
set -euo pipefail
# Tune /etc/dnf/dnf.conf without running script as root (uses as_root)

. "$(dirname "$0")/00_helpers.sh"

DNF_CONF="/etc/dnf/dnf.conf"
ts="$(date +%s)"

# Ensure [main] exists; then overwrite the speed block exactly as desired
as_root "bash -lc '
  set -euo pipefail
  [[ -f \"$DNF_CONF\" ]] || touch \"$DNF_CONF\"
  cp -a \"$DNF_CONF\" \"$DNF_CONF.bak.$ts\"
  grep -q \"^\[main\]\" \"$DNF_CONF\" || echo \"[main]\" >> \"$DNF_CONF\"
  # remove previous occurrences to avoid duplicates
  sed -i \"/^max_parallel_downloads=/d;/^defaultyes=/d;/^keepcache=/d;/^fastestmirror=/d\" \"$DNF_CONF\"
  # append our tuned block
  cat >> \"$DNF_CONF\" <<EOF

# Added for Speed:
max_parallel_downloads=20
defaultyes=True
keepcache=True
fastestmirror=True
EOF
  echo \"[OK] dnf.conf tuned (backup: $DNF_CONF.bak.$ts)\"
'"

# System update
echo "[INFO] Updating system (dnf upgrade)"
as_root "dnf -y upgrade --refresh"
echo "[OK] System up to date"
