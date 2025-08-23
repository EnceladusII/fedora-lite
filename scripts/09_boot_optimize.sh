#!/usr/bin/env bash
set -euo pipefail
# Boot optimizations: disable services from list, tweak GRUB timeout, optionally remove Plymouth.

. "$(dirname "$0")/00_helpers.sh"

SERVICES_LIST="$ROOT_DIR/lists/services-disable.txt"

# 1) Disable services from your list
if [[ -f "$SERVICES_LIST" ]]; then
  while IFS= read -r svc; do
    [[ -z "${svc// /}" || "$svc" =~ ^# ]] && continue
    echo "[INFO] Disabling service: $svc"
    disable_service "$svc"
  done < <(apply_list "$SERVICES_LIST")
else
  echo "[INFO] No services list found at $SERVICES_LIST"
fi

# 2) Common safe wins (skip errors if units don't exist)
disable_service "kdump.service"
as_root "systemctl mask systemd-boot-system-token.service || true"
# Often wastes seconds if enabled by deps:
as_root "systemctl disable --now NetworkManager-wait-online.service 2>/dev/null || true"

# 3) GRUB: reduce timeout (and hide menu), keep other settings intact
GRUB_DEFAULT="/etc/default/grub"
ts="$(date +%s)"
as_root "cp -a '$GRUB_DEFAULT' '${GRUB_DEFAULT}.bak.${ts}' || true"

# Ensure the keys exist with the values we want
as_root "bash -lc '
  set -euo pipefail
  f=\"$GRUB_DEFAULT\"
  touch \"$f\"
  grep -q \"^GRUB_TIMEOUT=\" \"$f\" && sed -i \"s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/\" \"$f\" || echo GRUB_TIMEOUT=1 >> \"$f\"
  grep -q \"^GRUB_TIMEOUT_STYLE=\" \"$f\" && sed -i \"s/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/\" \"$f\" || echo GRUB_TIMEOUT_STYLE=hidden >> \"$f\"
'"

# 4) Optionally remove Plymouth to shave time (text boot)
if [[ "${REMOVE_PLYMOUTH:-0}" == "1" ]]; then
  echo "[INFO] Removing Plymouth and rebuilding initramfs"
  as_root "dnf -y remove 'plymouth*' || true"
  as_root "dracut --force"
else
  echo "[INFO] Keeping Plymouth (REMOVE_PLYMOUTH=0)."
fi

# 5) Rebuild GRUB config
GRUB_CFG="$(detect_grub_cfg)"
echo "[INFO] Rebuilding GRUB config at: $GRUB_CFG"
as_root "grub2-mkconfig -o '$GRUB_CFG' || true"

echo "[OK] Boot optimization applied. For further gains, trim your services list and ensure fast storage."
