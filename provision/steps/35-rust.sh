#!/usr/bin/env bash
# Step 35 — Rust toolchain via rustup. Per-user (rustup installs into the user's
# $HOME; root-owned toolchains are a pain), needed both for general dev and to
# build Alacritty in step 36.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

log "Rust (rustup) for '$TARGET_USER'"
apt_install curl   # the rustup installer fetches over curl — ensure it, don't assume

# Install rustup + the stable toolchain if cargo isn't already present.
# --no-modify-path: .zshrc owns PATH (it sources ~/.cargo/env), so don't let
# rustup edit untracked profile files (~/.profile, ~/.zshenv).
# Gate on the RUSTUP-managed cargo specifically (~/.cargo/bin/cargo) — a stray
# distro/apt `cargo` on PATH must NOT make us skip the rustup install we want.
as_user 'test -x "$HOME/.cargo/bin/cargo" || \
  curl --proto "=https" --tlsv1.2 -fsSL https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --default-toolchain stable' \
  || soft_fail "rustup install failed"

# Keep stable current on re-runs (no-op when already up to date).
as_user 'test -x "$HOME/.cargo/bin/rustup" && "$HOME/.cargo/bin/rustup" update stable >/dev/null 2>&1' \
  || true

# Validate the toolchain actually landed (curl|sh can exit 0 on a masked fetch failure).
as_user 'test -x "$HOME/.cargo/bin/cargo" && test -x "$HOME/.cargo/bin/rustc"' \
  || soft_fail "rust toolchain missing after rustup (fetch/install may have failed)"
