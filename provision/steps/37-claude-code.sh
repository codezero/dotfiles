#!/usr/bin/env bash
# Step 37 — Claude Code CLI via the official native installer (per-user).
# Matches the source machine: installs to ~/.local/bin/claude (on PATH via
# .zshrc), needs no Node, and self-updates in place. `stable` pins the channel.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

log "Claude Code (native installer, stable channel) for '$TARGET_USER'"
# Gate on the native-installer location (~/.local/bin/claude) specifically — not
# any `claude` on PATH (e.g. an npm-global or other install we don't manage).
# The bootstrap script (claude.ai/install.sh is a 302 to it) is verified against
# pins.sh before it runs (TODO J). It then fetches a per-version manifest and
# verifies the binary's sha256 itself — the payload was always checked; now the
# script is too. When Anthropic changes it, this refuses and says to re-pin.
as_user "test -x \"\$HOME/.local/bin/claude\" || {
  t=\$(mktemp) && bash '$PINS' fetch_pinned '$CLAUDE_BOOTSTRAP_URL' '$CLAUDE_BOOTSTRAP_SHA256' \"\$t\" \
    && bash \"\$t\" stable; rc=\$?; rm -f \"\$t\"; exit \$rc; }" \
  || soft_fail "Claude Code install failed (bootstrap fetch/verify/run — see pins.sh)"

# Validate it landed — the curl|bash pipe can exit 0 even if the fetch failed.
as_user 'test -x "$HOME/.local/bin/claude"' \
  || soft_fail "claude binary not found after install (~/.local/bin/claude)"
