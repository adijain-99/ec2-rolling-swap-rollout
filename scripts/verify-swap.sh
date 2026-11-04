#!/usr/bin/env bash
#
# verify-swap.sh — assert that swap is configured as expected. Read-only.
#
# Used as the post-change gate in a rollout: the next host is not touched
# until this exits 0 on the current one.
#
# Configuration (environment variables):
#   SWAP_FILE      Path of the swap file         (default: /swapfile)
#   SWAP_SIZE_MIB  Expected size in MiB          (default: 8192)
#   SWAPPINESS     Expected vm.swappiness        (default: 10)
#   SYSCTL_FILE    Expected sysctl drop-in path  (default: /etc/sysctl.d/99-swap.conf)
#
# Exit codes:
#   0  all checks passed
#   1  one or more checks failed

set -Eeuo pipefail

SWAP_FILE="${SWAP_FILE:-/swapfile}"
SWAP_SIZE_MIB="${SWAP_SIZE_MIB:-8192}"
SWAPPINESS="${SWAPPINESS:-10}"
SYSCTL_FILE="${SYSCTL_FILE:-/etc/sysctl.d/99-swap.conf}"

FAILURES=0
log()  { printf '%s [verify-swap] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
ok()   { log "OK    $*"; }
bad()  { log "FAIL  $*"; FAILURES=$((FAILURES + 1)); }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

# 1. Swap file is active with the expected size (allow one page of slack:
#    the kernel reserves the first page for the swap header).
active_kib="$(swapon --show=NAME,SIZE --bytes --noheadings \
  | awk -v f="$SWAP_FILE" '$1 == f {print int($2 / 1024)}')"
expected_kib=$((SWAP_SIZE_MIB * 1024))
if [[ -z "$active_kib" ]]; then
  bad "${SWAP_FILE} is not active swap"
elif (( expected_kib - active_kib > 64 )); then
  bad "${SWAP_FILE} active but ${active_kib} KiB, expected ~${expected_kib} KiB"
else
  ok "${SWAP_FILE} active (${active_kib} KiB)"
fi

# 2. Permissions
if [[ -e "$SWAP_FILE" ]]; then
  perms="$(stat -c '%a %U:%G' "$SWAP_FILE")"
  if [[ "$perms" == "600 root:root" ]]; then
    ok "Permissions ${perms}"
  else
    bad "Permissions ${perms}, expected 600 root:root"
  fi
fi

# 3. Exactly one fstab entry
entries="$(grep -Ec "^[[:space:]]*${SWAP_FILE}[[:space:]]+[^[:space:]]+[[:space:]]+swap" /etc/fstab || true)"
if [[ "$entries" == "1" ]]; then
  ok "/etc/fstab has exactly one entry for ${SWAP_FILE}"
else
  bad "/etc/fstab has ${entries} entries for ${SWAP_FILE}, expected 1"
fi

# 4. Swappiness, live and persisted
live="$(cat /proc/sys/vm/swappiness)"
if [[ "$live" == "$SWAPPINESS" ]]; then
  ok "vm.swappiness live value ${live}"
else
  bad "vm.swappiness live value ${live}, expected ${SWAPPINESS}"
fi
if [[ -f "$SYSCTL_FILE" ]] && grep -qx "vm.swappiness=${SWAPPINESS}" "$SYSCTL_FILE"; then
  ok "vm.swappiness persisted in ${SYSCTL_FILE}"
else
  bad "vm.swappiness=${SWAPPINESS} not persisted in ${SYSCTL_FILE}"
fi

# Informational snapshot
free -h | sed 's/^/          /'

log "Summary: ${FAILURES} failure(s)"
(( FAILURES == 0 ))
