#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# smoke-test.sh — re-runnable smoke checks for this repo. Three tiers:
#
#   bash smoke-test.sh lint        shellcheck every script (anywhere; no sudo)
#   bash smoke-test.sh dry        provision.sh --dry-run matrix + assertions
#                                  (anywhere; no sudo, no changes, no network)
#   bash smoke-test.sh verify [S<n> | token...]
#                                  read-only end-state audit ON a provisioned
#                                  box/clone. Takes a runbook id (`verify S4`)
#                                  and expands it, or raw tokens, or nothing at
#                                  all (auto-detects mode+profile from the box).
#                                  The tokens are not peers — one MODE, one
#                                  PROFILE, any number of ADD-ONs, and
#                                  `installsh` stands alone because it REPLACES
#                                  the core audit. `scenarios` prints the map.
#   bash smoke-test.sh scenarios   the live runbook (S1–S15) + the verify
#                                  vocabulary and how the tokens compose
#
# lint+dry are the pre-commit/dev-box tier; verify codifies the hand audits
# from phases A–D. NEVER calls Electron `--version` (hangs headless) — package
# presence is checked with dpkg-query / command -v.
# ──────────────────────────────────────────────────────────────────────────
set -uo pipefail
_T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tests"
# Each tier lives in its own file under tests/ (split 2026-09-22); they define
# functions only, so sourcing all of them is free and keeps behaviour identical
# — the dry tier calls cmd_scenarios and scenario_tokens in-process.
# shellcheck source=tests/lib.sh
source "$_T/lib.sh"
for _f in vocab lint dry verify scenarios; do
  # shellcheck source=/dev/null
  source "$_T/$_f.sh"
done
unset _f

# ── main ────────────────────────────────────────────────────────────────────
case "${1:-}" in
  lint)      cmd_lint; summary ;;
  dry)       cmd_dry; summary ;;
  verify)    shift; cmd_verify "$@"; summary ;;
  scenarios) cmd_scenarios ;;
  all)       cmd_lint; cmd_dry; summary ;;
  *) echo "usage: bash smoke-test.sh {lint|dry|all|scenarios|verify [S<n> | token...]}"
     echo "       verify takes a runbook id (verify S4), raw tokens"
     echo "       (auto|plain|copy|full|minimal|desktop|rootless|headless|golden-clone|installsh),"
     echo "       or nothing (auto-detect). Map + composition rules: smoke-test.sh scenarios"
     exit 2 ;;
esac
