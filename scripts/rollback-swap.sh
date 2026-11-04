#!/usr/bin/env bash
#
# rollback-swap.sh — remove the swap file and restore default swappiness.
#
# swapoff has to move every swapped-out page back into RAM. If there is not
# enough free memory for that, swapoff can trigger the OOM killer, so this
# script refuses to continue unless MemAvailable comfortably exceeds the
# swap currently in use. Use --force only if you understand that risk.
#
# Usage:
#   sudo ./rollback-swap.sh [--force]
#
# Configuration (environment variables):
#   SWAP_FILE         Path of the swap file         (default: /swapfile)
#   SYSCTL_FILE       sysctl drop-in to remove      (default: /etc/sysctl.d/99-swap.conf)
#   SAFETY_MARGIN_MIB Extra RAM required on top of
#                     swap in use before swapoff    (default: 1024)
#
# Exit codes:
#   0  rolled back (or nothing to roll back)
#   1  refused or failed
#   2  usage / environment error

set -Eeuo pipefail

SWAP_FILE="${SWAP_FILE:-/swapfile}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/99-swap.conf}"
SAFETY_MARGIN_MIB="${SAFETY_MARGIN_MIB:-1024}"
FORCE=0

log() { printf '%s [rollback-swap] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR $*"; exit 1; }

case "${1:-}" in
  "") ;;
  --force) FORCE=1 ;;
  -h|--help) sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) log "Unknown argument: $1"; exit 2 ;;
esac

[[ $EUID -eq 0 ]] || { log "ERROR must run as root"; exit 2; }

# --- 1. swapoff (with memory safety check) -----------------------------------
used_kib="$(swapon --show=NAME,USED --bytes --noheadings \
  | awk -v f="$SWAP_FILE" '$1 == f {print int($2 / 1024)}')"

if [[ -n "$used_kib" ]]; then
  avail_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  need_kib=$((used_kib + SAFETY_MARGIN_MIB * 1024))
  log "Swap in use: $((used_kib / 1024)) MiB; MemAvailable: $((avail_kib / 1024)) MiB"

  if (( avail_kib < need_kib )) && (( FORCE == 0 )); then
    die "not enough free RAM to absorb swapped pages safely (need $((need_kib / 1024)) MiB). Re-run with --force to override."
  fi

  log "Running swapoff ${SWAP_FILE} (may take a while if swap is in use)"
  swapoff "$SWAP_FILE"
else
  log "${SWAP_FILE} is not active swap; skipping swapoff"
fi

# --- 2. fstab ------------------------------------------------------------------
if grep -Eq "^[[:space:]]*${SWAP_FILE}[[:space:]]" /etc/fstab; then
  backup="/etc/fstab.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p /etc/fstab "$backup"
  sed -i "\|^[[:space:]]*${SWAP_FILE}[[:space:]]|d" /etc/fstab
  mount -a || { cp -p "$backup" /etc/fstab; die "fstab invalid after edit; restored ${backup}"; }
  log "Removed ${SWAP_FILE} from /etc/fstab (backup: ${backup})"
else
  log "No fstab entry for ${SWAP_FILE}"
fi

# --- 3. Swap file --------------------------------------------------------------
if [[ -f "$SWAP_FILE" ]]; then
  rm -f "$SWAP_FILE"
  log "Deleted ${SWAP_FILE}"
fi

# --- 4. Swappiness ---------------------------------------------------------------
if [[ -f "$SYSCTL_FILE" ]]; then
  rm -f "$SYSCTL_FILE"
  log "Removed ${SYSCTL_FILE}"
fi
# Re-apply remaining sysctl config; fall back to the kernel default.
sysctl -q --system >/dev/null 2>&1 || true
if ! grep -rqs '^[[:space:]]*vm.swappiness' /etc/sysctl.conf /etc/sysctl.d/; then
  sysctl -q -w vm.swappiness=60
fi

log "Rollback complete. swappiness=$(cat /proc/sys/vm/swappiness)"
swapon --show
free -h
