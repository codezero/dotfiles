#!/usr/bin/env bash
# Step 35 — Rust toolchain via rustup. Per-user (rustup installs into the user's
# $HOME; root-owned toolchains are a pain), needed both for general dev and to
# build Alacritty in step 36.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

log "Rust (rustup) for '$TARGET_USER'"

# Install rustup + the stable toolchain if cargo isn't already present.
# --no-modify-path: .zshrc owns PATH (it sources ~/.cargo/env), so don't let
# rustup edit untracked profile files (~/.profile, ~/.zshenv).
as_user 'test -x "$HOME/.cargo/bin/cargo" || command -v cargo >/dev/null 2>&1 || \
  curl --proto "=https" --tlsv1.2 -fsSL https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --default-toolchain stable' \
  || warn "rustup install failed"

# Keep stable current on re-runs (no-op when already up to date).
as_user 'test -x "$HOME/.cargo/bin/rustup" && "$HOME/.cargo/bin/rustup" update stable >/dev/null 2>&1' \
  || true
