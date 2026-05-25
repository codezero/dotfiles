#!/usr/bin/env bash
# Step 37 — Claude Code CLI via the official native installer (per-user).
# Matches the source machine: installs to ~/.local/bin/claude (on PATH via
# .zshrc), needs no Node, and self-updates in place. `stable` pins the channel.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

log "Claude Code (native installer, stable channel) for '$TARGET_USER'"
as_user 'command -v claude >/dev/null 2>&1 || test -x "$HOME/.local/bin/claude" || \
  curl -fsSL https://claude.ai/install.sh | bash -s stable' \
  || soft_fail "Claude Code install failed"

# Validate it landed — the curl|bash pipe can exit 0 even if the fetch failed.
as_user 'command -v claude >/dev/null 2>&1 || test -x "$HOME/.local/bin/claude"' \
  || soft_fail "claude binary not found after install"
