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

# zsh_starts_clean — an interactive zsh exits 0 AND prints nothing. It runs under
# a pty (`script`): without a tty, p10k's gitstatus and fzf's --zsh integration
# print errors a real terminal never shows, while `zsh -ic true` still exits 0 —
# so the old exit-status-only check passed with errors on screen (2026-10-17).
# A clean start emits no bytes at all; control sequences are stripped anyway in
# case a theme sets a window title. Without `script`, only the exit status counts.
zsh_starts_clean() {
  command -v script >/dev/null 2>&1 || { zsh -ic true; return; }
  local out
  out="$(timeout 30 script -qec 'zsh -ic true' /dev/null 2>&1)" || return 1
  out="$(printf '%s' "$out" \
    | sed -e 's/\x1b\[[0-9;?<>=]*[@-~]//g' -e 's/\x1b\][^\x07\x1b]*\(\x07\|\x1b\\\)//g' \
          -e 's/\x1b[=>()][0-9A-Za-z]\{0,1\}//g' \
    | tr -d '[:space:]')"
  [ -z "$out" ]
}

summary() {
  printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
  # A skipped check is NOT a passing one — it means the property was never
  # verified. Without this line "36 passed, 1 skipped" reads as green, which is
  # how an unverified assertion quietly becomes a believed one.
  [ "$SKIP" -gt 0 ] && printf '\033[1;33m⚠ %d check(s) SKIPPED — those properties are NOT verified\033[0m\n' "$SKIP"
  [ "$FAIL" -eq 0 ]
}
