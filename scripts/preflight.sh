#!/usr/bin/env bash
#
# preflight.sh — read-only checks before adding a swap file to a Linux host.
#
# Makes NO changes. Exits non-zero if any blocking condition is found, so it
# can gate an automated rollout (see rolling-rollout.sh).
#
# Configuration (environment variables):
#   SWAP_FILE              Path of the swap file           (default: /swapfile)
#   SWAP_SIZE_MIB          Size of the swap file in MiB    (default: 8192)
#   MIN_FREE_HEADROOM_MIB  Free disk to keep after creation (default: 2048)
#
# Exit codes:
#   0  all checks passed (warnings may still be printed)
#   1  one or more blocking checks failed
#   2  usage / environment error

set -Eeuo pipefail

SWAP_FILE="${SWAP_FILE:-/swapfile}"
SWAP_SIZE_MIB="${SWAP_SIZE_MIB:-8192}"
MIN_FREE_HEADROOM_MIB="${MIN_FREE_HEADROOM_MIB:-2048}"

FAILURES=0
WARNINGS=0

log()  { printf '%s [preflight] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
pass() { log "PASS  $*"; }
warn() { log "WARN  $*"; WARNINGS=$((WARNINGS + 1)); }
fail() { log "FAIL  $*"; FAILURES=$((FAILURES + 1)); }

usage() {
  sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! [[ "$SWAP_SIZE_MIB" =~ ^[0-9]+$ && "$MIN_FREE_HEADROOM_MIB" =~ ^[0-9]+$ ]]; then
  log "SWAP_SIZE_MIB and MIN_FREE_HEADROOM_MIB must be integers"
  exit 2
fi

swap_dir="$(dirname "$SWAP_FILE")"

log "Host: $(hostname)  Kernel: $(uname -r)"
log "Target: ${SWAP_FILE} (${SWAP_SIZE_MIB} MiB), headroom ${MIN_FREE_HEADROOM_MIB} MiB"

# --- 1. Operating system ---------------------------------------------------
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  pass "OS: ${PRETTY_NAME:-unknown}"
else
  warn "Cannot read /etc/os-release; OS not verified"
fi

# --- 2. Existing swap --------------------------------------------------------
active_swap="$(swapon --show --noheadings --raw 2>/dev/null || true)"
if [[ -z "$active_swap" ]]; then
  pass "No active swap"
elif grep -q "^${SWAP_FILE} " <<<"$active_swap"; then
  warn "Swap already active at ${SWAP_FILE}; configure-swap.sh will treat this as already applied"
else
  fail "Other swap already active — review before adding more:"
  printf '%s\n' "$active_swap" | sed 's/^/          /'
fi

if [[ -e "$SWAP_FILE" ]] && ! grep -q "^${SWAP_FILE} " <<<"$active_swap"; then
  fail "${SWAP_FILE} exists but is not active swap — inspect it manually"
fi

# --- 3. Filesystem type ------------------------------------------------------
fs_type="$(findmnt -n -o FSTYPE --target "$swap_dir" 2>/dev/null || echo unknown)"
case "$fs_type" in
  xfs|ext4|ext3)
    pass "Filesystem for ${swap_dir}: ${fs_type}" ;;
  btrfs)
    fail "btrfs needs a NOCOW swap file (chattr +C); not supported by these scripts" ;;
  *)
    fail "Unsupported or unknown filesystem for ${swap_dir}: ${fs_type}" ;;
esac

# --- 4. Free disk space -------------------------------------------------------
avail_mib="$(df --output=avail -m "$swap_dir" | tail -n 1 | tr -d ' ')"
required_mib=$((SWAP_SIZE_MIB + MIN_FREE_HEADROOM_MIB))
if grep -q "^${SWAP_FILE} " <<<"$active_swap"; then
  pass "Free disk check skipped (swap file already in place)"
elif (( avail_mib >= required_mib )); then
  pass "Free disk: ${avail_mib} MiB (need ${required_mib} MiB)"
else
  fail "Free disk: ${avail_mib} MiB, need ${required_mib} MiB — grow the volume first"
fi

# --- 5. Memory snapshot (informational) --------------------------------------
mem_total_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
mem_avail_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
avail_pct=$((mem_avail_kib * 100 / mem_total_kib))
log "INFO  Memory: $((mem_total_kib / 1024)) MiB total, $((mem_avail_kib / 1024)) MiB available (${avail_pct}%)"
if (( avail_pct < 10 )); then
  warn "Less than 10% memory available — the host is already under pressure"
fi

log "INFO  Current vm.swappiness: $(cat /proc/sys/vm/swappiness)"

# --- 6. fstab sanity -----------------------------------------------------------
if grep -Eq "^[[:space:]]*${SWAP_FILE}[[:space:]]" /etc/fstab; then
  warn "${SWAP_FILE} already referenced in /etc/fstab"
else
  pass "/etc/fstab has no existing entry for ${SWAP_FILE}"
fi

# --- Summary -------------------------------------------------------------------
log "Summary: ${FAILURES} failure(s), ${WARNINGS} warning(s)"
if (( FAILURES > 0 )); then
  exit 1
fi
exit 0
