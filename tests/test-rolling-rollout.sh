#!/usr/bin/env bash
#
# test-rolling-rollout.sh — exercise rolling-rollout.sh against a mock AWS CLI.
#
# Checks:
#   1. Happy path: every instance is processed, in the given order.
#   2. Fail-fast: a failure on instance 2 stops the rollout before instance 3.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/tests/mockbin:${PATH}"
export POLL_SECONDS=0
ROLLOUT="${ROOT}/scripts/rolling-rollout.sh"
PASSED=0

assert() {
  local name="$1"; shift
  if "$@"; then echo "ok   - ${name}"; PASSED=$((PASSED + 1)); else echo "FAIL - ${name}"; exit 1; fi
}

not_contains() { ! grep -qF -- "$1" <<<"$2"; }

# 1. Happy path
out="$("$ROLLOUT" --instances i-aaa,i-bbb,i-ccc --soak-seconds 0 --yes 2>&1)"
assert "happy path completes" grep -q "complete: configure applied to 3 instance(s)" <<<"$out"
order="$(grep -o '===== \[[0-9]/3\] i-[a-z]*' <<<"$out" | awk '{print $3}' | paste -sd,)"
assert "instances processed in order" test "$order" = "i-aaa,i-bbb,i-ccc"

# 2. Fail-fast
set +e
out="$(FAIL_ON=i-bbb "$ROLLOUT" --instances i-aaa,i-bbb,i-ccc --soak-seconds 0 --yes 2>&1)"
rc=$?
set -e
assert "failure returns non-zero" test "$rc" -ne 0
assert "stops at failing instance" grep -q "i-bbb: preflight failed" <<<"$out"
assert "next instance untouched" not_contains "] i-ccc =====" "$out"

# 3. Dry run makes no configure calls
out="$("$ROLLOUT" --instances i-aaa --dry-run --yes 2>&1)"
assert "dry run skips configure" not_contains "configure-swap.sh" "$out"

rm -rf "${ROOT}/logs"
echo "${PASSED} checks passed"
