#!/usr/bin/env bash
set -euo pipefail
shopt -s lastpipe
set -o errtrace

# -------------------------------------------------------------
# Fedora boot optimization (GRUB+BLS), idempotent
# - Désactive/masque des services lents
# - Réduit le timeout GRUB et cache le menu
# - Retire 'rhgb' (et optionnellement 'quiet') via grubby
# - (optionnel) initramfs hostonly et/ou retrait de Plymouth
# -------------------------------------------------------------

# Charge tes helpers (NE PAS MODIFIER helpers)
. "$(dirname "$0")/00_helpers.sh"

# --- Options (surchargées via env/.env) ----------------------
: "${DRY_RUN:=0}"                      # 1 = prévisualisation
: "${REMOVE_PLYMOUTH:=${REMOVE_PLYMOUTH:-0}}"
: "${DRACUT_HOSTONLY:=0}"
: "${KARGS_DROP_RHGB:=1}"
: "${KARGS_DROP_QUIET:=0}"
: "${KARGS_ADD_NOWATCHDOG:=0}"
: "${VERBOSE:=0}"                      # 1 = trace (debug)
# -------------------------------------------------------------

[[ "$VERBOSE" == "1" ]] && set -x

SERVICES_LIST="${ROOT_DIR}/lists/services-disable.txt"

log()  { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

# Trace l’erreur exacte si ça casse (utile sous make)
on_err() {
  echo "[ERR] command failed (line $LINENO): $BASH_COMMAND" >&2
}
trap on_err ERR

# Exécuter via sudo/as_root, en respectant DRY_RUN
do_root() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY] $*"
  else
    as_root "$*"
  fi
}

# Pré-chauffe sudo et keep-alive pendant le script (évite Error 1 sous make)
if [[ "$DRY_RUN" != "1" ]]; then
  if ! sudo -v; then
    echo "[ERR] Need sudo (user in wheel). Run 'sudo -v' then retry." >&2
    exit 1
  fi
  ( while true; do sleep 60; sudo -n true 2>/dev/null || exit; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
fi

# 0) Résumé
log "[INFO] DRY_RUN=$DRY_RUN REMOVE_PLYMOUTH=$REMOVE_PLYMOUTH DRACUT_HOSTONLY=$DRACUT_HOSTONLY"
log "[INFO] KARGS: drop_rhgb=$KARGS_DROP_RHGB drop_quiet=$KARGS_DROP_QUIET add_nowatchdog=$KARGS_ADD_NOWATCHDOG"

# 1) Désactivation services (liste utilisateur)
disable_one() {
  local unit="$1"
  [[ -z "${unit// /}" || "$unit" =~ ^# ]] && return 0
  log "[INFO] Disabling service: $unit"
  # helpers -> disable_service utilise déjà as_root
  disable_service "$unit" || true
}

if [[ -f "$SERVICES_LIST" ]]; then
  apply_list "$SERVICES_LIST" | while IFS= read -r svc; do
    disable_one "$svc"
  done
else
  log "[INFO] No services list found at $SERVICES_LIST"
fi

# Gains communs sûrs
disable_service "kdump.service" || true
do_root "systemctl mask systemd-boot-system-token.service || true"
do_root "systemctl disable --now NetworkManager-wait-online.service 2>/dev/null || true"
do_root "systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true"
do_root "systemctl mask plymouth-quit-wait.service 2>/dev/null || true"

# 2) GRUB : timeout + menu caché (avec backup)
GRUB_DEFAULT="/etc/default/grub"
ts="$(date +%s)"
do_root "cp -a '$GRUB_DEFAULT' '${GRUB_DEFAULT}.bak.${ts}' 2>/dev/null || true"

do_root "bash -lc '
  set -euo pipefail
  f=\"$GRUB_DEFAULT\"
  touch \"$f\"
  if grep -q \"^GRUB_TIMEOUT=\" \"$f\"; then sed -i \"s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/\" \"$f\"; else echo GRUB_TIMEOUT=1 >> \"$f\"; fi
  if grep -q \"^GRUB_TIMEOUT_STYLE=\" \"$f\"; then sed -i \"s/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/\" \"$f\"; else echo GRUB_TIMEOUT_STYLE=hidden >> \"$f\"; fi
'"

# 3) Kargs via grubby (BLS)
if command -v grubby >/dev/null 2>&1; then
  [[ "$KARGS_DROP_RHGB" == "1"      ]] && do_root "grubby --update-kernel=ALL --remove-args='rhgb' || true"
  [[ "$KARGS_DROP_QUIET" == "1"     ]] && do_root "grubby --update-kernel=ALL --remove-args='quiet' || true"
  [[ "$KARGS_ADD_NOWATCHDOG" == "1" ]] && do_root "grubby --update-kernel=ALL --args='nowatchdog' || true"
else
  warn "grubby introuvable, saut des ajustements kargs (BLS)."
fi

# 4) Option : retirer Plymouth puis reconstruire initramfs
if [[ "$REMOVE_PLYMOUTH" == "1" ]]; then
  log "[INFO] Removing Plymouth and rebuilding initramfs"
  do_root "dnf -y remove 'plymouth*' || true"
  do_root "dracut -f -v || { echo '[WARN] dracut failed after plymouth removal; continuing'; true; }"
else
  log "[INFO] Keeping Plymouth (REMOVE_PLYMOUTH=0)."
fi

# 5) Option : initramfs hostonly
if [[ "$DRACUT_HOSTONLY" == "1" ]]; then
  log "[INFO] Enabling dracut hostonly"
  do_root "mkdir -p /etc/dracut.conf.d"
  do_root "bash -lc 'echo hostonly=\\\"yes\\\" > /etc/dracut.conf.d/10-hostonly.conf'"
  do_root "dracut -f -v || { echo '[WARN] dracut hostonly rebuild failed; continuing'; true; }"
fi

# 6) Rebuild GRUB config
GRUB_CFG="$(detect_grub_cfg)"
log "[INFO] Rebuilding GRUB config at: $GRUB_CFG"
do_root "grub2-mkconfig -o '$GRUB_CFG' || true"

log "[OK] Boot optimization applied. Mesure les gains :"
log "  systemd-analyze && systemd-analyze critical-chain"
