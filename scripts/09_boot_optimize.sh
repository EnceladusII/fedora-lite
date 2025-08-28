#!/usr/bin/env bash
set -euo pipefail
shopt -s lastpipe
set -o errtrace

. "$(dirname "$0")/00_helpers.sh"

: "${DRY_RUN:=0}"
: "${REMOVE_PLYMOUTH:=${REMOVE_PLYMOUTH:-0}}"
: "${DRACUT_HOSTONLY:=0}"
: "${KARGS_DROP_RHGB:=1}"
: "${KARGS_DROP_QUIET:=0}"
: "${KARGS_ADD_NOWATCHDOG:=0}"
: "${VERBOSE:=0}"

[[ "$VERBOSE" == "1" ]] && set -x

SERVICES_LIST="${ROOT_DIR}/lists/services-disable.txt"

log()  { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
on_err(){ echo "[ERR] command failed (line $LINENO): $BASH_COMMAND" >&2; }
trap on_err ERR

# <<< FIX: init + trap safe >>>
SUDO_KEEPALIVE_PID=""  # évite 'unbound variable' si non défini
cleanup() {
  # kill uniquement si défini et non vide
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
# >>> FIX

# Exécution root via helpers (respecte DRY_RUN)
do_root() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY] $*"
  else
    as_root "$*"
  fi
}

# Sudo warm-up (sauf DRY)
if [[ "$DRY_RUN" != "1" ]]; then
  sudo -v || { echo "[ERR] Need sudo (user in wheel). Run 'sudo -v' first."; exit 1; }
  ( while true; do sleep 60; sudo -n true 2>/dev/null || exit; done ) &
  SUDO_KEEPALIVE_PID=$!
fi

log "[INFO] DRY_RUN=$DRY_RUN REMOVE_PLYMOUTH=$REMOVE_PLYMOUTH DRACUT_HOSTONLY=$DRACUT_HOSTONLY"
log "[INFO] KARGS: drop_rhgb=$KARGS_DROP_RHGB drop_quiet=$KARGS_DROP_QUIET add_nowATCHDOG=$KARGS_ADD_NOWATCHDOG"

# 1) Désactivation services (liste utilisateur)
disable_one() {
  local unit="$1"
  [[ -z "${unit// /}" || "$unit" =~ ^# ]] && return 0
  log "[INFO] Disabling service: $unit"
  disable_service "$unit" || true
}

if [[ -f "$SERVICES_LIST" ]]; then
  awk '
    /^[[:space:]]*$/ {next}
    /^[[:space:]]*#/ {next}
    { sub(/[[:space:]]*#.*/, "", $0); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); if (length($0)>0) print $0 }
  ' "$SERVICES_LIST" | while IFS= read -r svc; do
    disable_one "$svc"
  done
else
  log "[INFO] No services list found at $SERVICES_LIST"
fi

# 2) Gains communs sûrs
disable_service "kdump.service" || true
do_root "systemctl mask systemd-boot-system-token.service || true"
do_root "systemctl disable --now NetworkManager-wait-online.service 2>/dev/null || true"
do_root "systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true"
do_root "systemctl mask plymouth-quit-wait.service 2>/dev/null || true"

# 3) GRUB : timeout + menu caché (avec backup)
ts="$(date +%s)"
do_root "cp -a '/etc/default/grub' '/etc/default/grub.bak.${ts}' 2>/dev/null || true"
do_root "bash -lc '
  set -euo pipefail
  f=/etc/default/grub
  touch \"$f\"
  if grep -q \"^GRUB_TIMEOUT=\" \"$f\"; then
    sed -i \"s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/\" \"$f\"
  else
    echo GRUB_TIMEOUT=1 >> \"$f\"
  fi
  if grep -q \"^GRUB_TIMEOUT_STYLE=\" \"$f\"; then
    sed -i \"s/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/\" \"$f\"
  else
    echo GRUB_TIMEOUT_STYLE=hidden >> \"$f\"
  fi
'"

# 4) Kargs via grubby
if command -v grubby >/dev/null 2>&1; then
  [[ "$KARGS_DROP_RHGB" == "1"      ]] && do_root "grubby --update-kernel=ALL --remove-args='rhgb' || true"
  [[ "$KARGS_DROP_QUIET" == "1"     ]] && do_root "grubby --update-kernel=ALL --remove-args='quiet' || true"
  [[ "$KARGS_ADD_NOWATCHDOG" == "1" ]] && do_root "grubby --update-kernel=ALL --args='nowatchdog' || true"
else
  warn "grubby not found; skipping kernel args adjustments."
fi

# 5) Option : retirer Plymouth + reconstruire initramfs
if [[ "$REMOVE_PLYMOUTH" == "1" ]]; then
  log "[INFO] Removing Plymouth and rebuilding initramfs"
  do_root "dnf -y remove 'plymouth*' || true"
  do_root "dracut -f -v || { echo '[WARN] dracut failed after plymouth removal; continuing'; true; }"
else
  log "[INFO] Keeping Plymouth (REMOVE_PLYMOUTH=0)."
fi

# 6) Option : initramfs hostonly
if [[ "$DRACUT_HOSTONLY" == "1" ]]; then
  log "[INFO] Enabling dracut hostonly"
  do_root "mkdir -p /etc/dracut.conf.d"
  do_root "bash -lc 'echo hostonly=\\\"yes\\\" > /etc/dracut.conf.d/10-hostonly.conf'"
  do_root "dracut -f -v || { echo '[WARN] dracut hostonly rebuild failed; continuing'; true; }"
fi

# 7) Rebuild GRUB config
GRUB_CFG="$(detect_grub_cfg)"
log "[INFO] Rebuilding GRUB config at: $GRUB_CFG"
do_root "grub2-mkconfig -o '$GRUB_CFG' || true"

log "[OK] Boot optimization applied. Try:"
log "  systemd-analyze && systemd-analyze critical-chain"
