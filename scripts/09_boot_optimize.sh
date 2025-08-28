#!/usr/bin/env bash
set -euo pipefail
shopt -s lastpipe

# -------------------------------------------------------------
# Boot optimizations for Fedora (GRUB+BLS), safe & idempotent
# - désactive/masque des services connus pour ralentir le boot
# - réduit le timeout GRUB et cache le menu
# - retire 'rhgb' (et optionnellement 'quiet') via grubby
# - (optionnel) rend l'initramfs hostonly et/ou retire Plymouth
# -------------------------------------------------------------

# Charge les helpers (NE PAS MODIFIER helpers)
. "$(dirname "$0")/00_helpers.sh"

# --- Options (surchargées via env) --------------------------
: "${DRY_RUN:=0}"               # 1 = prévisualisation (aucun changement)
: "${REMOVE_PLYMOUTH:=${REMOVE_PLYMOUTH:-0}}"  # vient potentiellement du .env
: "${DRACUT_HOSTONLY:=0}"       # 1 = initramfs "hostonly"
: "${KARGS_DROP_RHGB:=1}"       # 1 = retire 'rhgb' (splash)
: "${KARGS_DROP_QUIET:=0}"      # 1 = retire 'quiet' (affiche logs)
: "${KARGS_ADD_NOWATCHDOG:=0}"  # 1 = ajoute 'nowatchdog'
# ------------------------------------------------------------

SERVICES_LIST="${ROOT_DIR}/lists/services-disable.txt"

log()  { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

run() {
  # Utilise as_root() des helpers ; respecte DRY_RUN
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY] $*"
  else
    as_root "$*"
  fi
}

# 0) Résumé des options
log "[INFO] DRY_RUN=$DRY_RUN REMOVE_PLYMOUTH=$REMOVE_PLYMOUTH DRACUT_HOSTONLY=$DRACUT_HOSTONLY"
log "[INFO] KARGS: drop_rhgb=$KARGS_DROP_RHGB drop_quiet=$KARGS_DROP_QUIET add_nowatchdog=$KARGS_ADD_NOWATCHDOG"

# 1) Désactiver / masquer des services (liste utilisateur)
disable_one() {
  local unit="$1"
  [[ -z "${unit// /}" || "$unit" =~ ^# ]] && return 0
  log "[INFO] Disabling service: $unit"
  disable_service "$unit" || true
}

if [[ -f "$SERVICES_LIST" ]]; then
  apply_list "$SERVICES_LIST" | while IFS= read -r svc; do
    disable_one "$svc"
  done
else
  log "[INFO] No services list found at $SERVICES_LIST"
fi

# Gains “communs” sûrs (ignore si l’unité n’existe pas)
disable_service "kdump.service" || true
run "systemctl mask systemd-boot-system-token.service || true"
run "systemctl disable --now NetworkManager-wait-online.service 2>/dev/null || true"
run "systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true"
run "systemctl mask plymouth-quit-wait.service 2>/dev/null || true"

# 2) GRUB : timeout minimal + menu caché (sauvegarde avant modif)
GRUB_DEFAULT="/etc/default/grub"
ts="$(date +%s)"
run "cp -a '$GRUB_DEFAULT' '${GRUB_DEFAULT}.bak.${ts}' || true"

run "bash -lc '
  set -euo pipefail
  f=\"$GRUB_DEFAULT\"
  touch \"$f\"
  grep -q \"^GRUB_TIMEOUT=\" \"$f\" && sed -i \"s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/\" \"$f\" || echo GRUB_TIMEOUT=1 >> \"$f\"
  grep -q \"^GRUB_TIMEOUT_STYLE=\" \"$f\" && sed -i \"s/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/\" \"$f\" || echo GRUB_TIMEOUT_STYLE=hidden >> \"$f\"
'"

# 3) Kargs via grubby (BLS)
if command -v grubby >/dev/null 2>&1; then
  [[ "$KARGS_DROP_RHGB" == "1" ]] && run "grubby --update-kernel=ALL --remove-args='rhgb' || true"
  [[ "$KARGS_DROP_QUIET" == "1" ]] && run "grubby --update-kernel=ALL --remove-args='quiet' || true"
  [[ "$KARGS_ADD_NOWATCHDOG" == "1" ]] && run "grubby --update-kernel=ALL --args='nowatchdog' || true"
else
  warn "grubby introuvable, saut des ajustements kargs (BLS)."
fi

# 4) Option : retirer Plymouth et reconstruire l'initramfs
if [[ "${REMOVE_PLYMOUTH}" == "1" ]]; then
  log "[INFO] Removing Plymouth and rebuilding initramfs"
  run "dnf -y remove 'plymouth*' || true"
  run "dracut --force"
else
  log "[INFO] Keeping Plymouth (REMOVE_PLYMOUTH=0)."
fi

# 5) Option : initramfs hostonly (plus petit/rapide)
if [[ "${DRACUT_HOSTONLY}" == "1" ]]; then
  log "[INFO] Enabling dracut hostonly"
  run "mkdir -p /etc/dracut.conf.d"
  run "bash -lc 'echo hostonly=\\\"yes\\\" > /etc/dracut.conf.d/10-hostonly.conf'"
  run "dracut --force"
fi

# 6) Rebuild GRUB config (utile si encore lu directement)
GRUB_CFG="$(detect_grub_cfg)"
log "[INFO] Rebuilding GRUB config at: $GRUB_CFG"
run "grub2-mkconfig -o '$GRUB_CFG' || true"

log "[OK] Boot optimization applied. Mesure les gains :"
log "  systemd-analyze && systemd-analyze critical-chain"
