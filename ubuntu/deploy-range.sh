#!/usr/bin/env bash
# =====================================================================
# deploy-range.sh - one-shot orchestrator that chains stages 00 -> 03
#   00 preflight  ->  01 networks  ->  02 deploy VMs  ->  (armed snap)  ->  03 boot
# Everything (this script + every child stage) is tee'd to a timestamped log.
#
# Usage:
#   ./deploy-range.sh [options]
# Options:
#   -n, --dry-run        print actions without changing anything (DRY_RUN=1)
#       --build-images   run images/build-images.sh first (stage 0-)
#       --skip-preflight skip stage 00
#       --skip-boot      stop after deploy (no stage 03)
#       --snapshot-armed after deploy, snapshot every VM as 'scenario-armed'
#       --revert SNAP    boot stage reverts each VM to SNAP first
#                        (defaults to 'scenario-armed' when --snapshot-armed set)
#   -h, --help           show this help
# =====================================================================
source "$(dirname "$0")/lib.sh"
set +e   # this orchestrator handles stage failures explicitly

SKIP_PREFLIGHT=0
SKIP_BOOT=0
MAKE_ARMED=0
BUILD_IMAGES=0
REVERT=""

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run)      export DRY_RUN=1 ;;
    --build-images)    BUILD_IMAGES=1 ;;
    --skip-preflight)  SKIP_PREFLIGHT=1 ;;
    --skip-boot)       SKIP_BOOT=1 ;;
    --snapshot-armed)  MAKE_ARMED=1 ;;
    --revert)          REVERT="${2:-}"; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) err "unknown option: $1 (see --help)"; exit 2 ;;
  esac
  shift
done

# --- Logging: capture this script AND all child stages ---
LOG_DIR="$CR_ROOT/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

RANGE_START=$(date +%s)
say "One-shot range deployment starting"
say "Log file : $LOG"
say "DRY_RUN  : ${DRY_RUN:-0}   skip_preflight=$SKIP_PREFLIGHT  skip_boot=$SKIP_BOOT  snapshot_armed=$MAKE_ARMED"

# stage NUM "Description" -- command [args...]
stage() {
  local num="$1" desc="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  local start; start=$(date +%s)
  printf '\n\033[1m================ STAGE %s: %s ================\033[0m\n' "$num" "$desc"
  say "run: $*"
  "$@"
  local rc=$?
  local dur=$(( $(date +%s) - start ))
  if [ "$rc" -eq 0 ]; then
    ok "STAGE $num complete (${dur}s)"
  else
    err "STAGE $num FAILED (rc=$rc, ${dur}s) - aborting. Full log: $LOG"
    exit "$rc"
  fi
}

# Snapshot every defined VM as scenario-armed (post-configuration baseline).
make_armed_snaps() {
  local n=0
  while IFS=$'\t' read -r name _rest; do
    run "$VIRSH" snapshot-create-as "$name" "$SNAP_ARMED" "armed for exercise" \
      && n=$((n+1)) || warn "could not snapshot '$SNAP_ARMED' on $name (is it defined?)"
  done < <(tsv "$INV_VM")
  ok "requested '$SNAP_ARMED' snapshot on $n VM(s)"
}

# --- Chain the stages ---
if [ "$BUILD_IMAGES" = 1 ]; then
  stage "0-" "Build base images" -- ./images/build-images.sh
fi

if [ "$SKIP_PREFLIGHT" = 1 ]; then warn "skipping stage 00 (preflight)"; else
  stage 00 "Preflight" -- ./00-preflight.sh
fi

stage 01 "Create isolated networks" -- ./01-create-networks.sh
stage 02 "Deploy VMs"               -- ./02-deploy-vms.sh

if [ "$MAKE_ARMED" = 1 ]; then
  stage 02b "Snapshot scenario-armed" -- make_armed_snaps
  REVERT="${REVERT:-$SNAP_ARMED}"
fi

if [ "$SKIP_BOOT" = 1 ]; then warn "skipping stage 03 (boot)"; else
  stage 03 "Boot in dependency order" -- ./03-boot-order.sh start "$REVERT"
fi

TOTAL=$(( $(date +%s) - RANGE_START ))
printf '\n\033[1m================ SUMMARY ================\033[0m\n'
ok  "Range deployment finished in ${TOTAL}s"
say "Log saved to: $LOG"
if [ "${DRY_RUN:-0}" = 1 ]; then
  warn "DRY_RUN was set - nothing was actually changed. Re-run without --dry-run to deploy."
else
  say "Next: ./scenario-toggle.sh A   (then B)   and   ./validate.sh A|B"
fi
