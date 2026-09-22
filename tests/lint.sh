#!/usr/bin/env bash
# tests/lint.sh — part of the smoke tier. Sourced by ../smoke-test.sh, which owns the
# CLI; this file only defines functions. Split out of the single 1,350-line
# smoke-test.sh (2026-09-22) so each tier is readable on its own — the
# external assessment's last open item. Shared helpers: tests/lib.sh.

# ── lint ────────────────────────────────────────────────────────────────────
# --severity=warning: the tree is clean at the warning level; the remaining
# info-level notes (SC2016 as_user '…$HOME…', SC2024 dconf redirects, SC2015)
# are intentional — see CLAUDE.md.
cmd_lint() {
  command -v shellcheck >/dev/null 2>&1 \
    || { echo "shellcheck not found — brew install shellcheck"; exit 2; }
  hdr "lint (shellcheck, severity=warning; info notes are intentional)"
  local s
  for s in "$HERE"/provision/steps/*.sh; do
    check "steps/$(basename "$s")" \
      shellcheck -x --severity=warning --source-path="$HERE/provision" "$s"
  done
  for s in provision/provision.sh provision/lib.sh provision/inventory-export.sh \
           provision/versions-lock.sh provision/pins.sh provision/boot-pkgs.sh \
           dotfiles-install.sh install.sh smoke-test.sh \
           tests/lib.sh tests/vocab.sh tests/lint.sh tests/dry.sh tests/verify.sh tests/scenarios.sh; do
    [ -f "$HERE/$s" ] || { skip "$s (missing)"; continue; }
    check "$s" shellcheck -x --severity=warning \
      --source-path="$HERE/provision" --source-path="$HERE/tests" "$HERE/$s"
  done
}
