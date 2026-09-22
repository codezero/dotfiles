#!/usr/bin/env bash
# tests/lib.sh — what every tier needs: repo root, the pin values, the
# pass/fail counters and the assertion helpers. Sourced first by
# ../smoke-test.sh. HERE is the REPO ROOT (this file lives one level down).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../provision/pins.sh
source "$HERE/provision/pins.sh"   # pin values for the v_core checkout assertions
PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[2m- %s (skipped)\033[0m\n' "$*"; SKIP=$((SKIP+1)); }
hdr()  { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

# check <description> <command...>  — pass/fail on the command's exit status.
check()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
# checkno <description> <command...> — inverted: pass when the command FAILS.
checkno() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

summary() {
  printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
  # A skipped check is NOT a passing one — it means the property was never
  # verified. Without this line "36 passed, 1 skipped" reads as green, which is
  # how an unverified assertion quietly becomes a believed one.
  [ "$SKIP" -gt 0 ] && printf '\033[1;33m⚠ %d check(s) SKIPPED — those properties are NOT verified\033[0m\n' "$SKIP"
  [ "$FAIL" -eq 0 ]
}
