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
# rustup-init comes from the VERSIONED archive and is verified against the hash
# recorded in pins.sh (TODO J) — not from sh.rustup.rs, a script that downloads
# whatever rustup-init is current with no checksum at all. The toolchain it
# then installs still floats (stable), verified by rustup's channel manifest.
# The file MUST be named rustup-init: rustup's binary dispatches on argv[0]
# (rustup-init = installer; any other name = toolchain proxy, which just fails).
# Found live in the J rehearsal — a mktemp name verified fine and then did
# nothing. Hence a temp DIR with the canonical filename inside.
as_user "test -x \"\$HOME/.cargo/bin/cargo\" || {
  d=\$(mktemp -d) && bash '$PINS' fetch_pinned '$(rustup_init_url)' '$(rustup_init_sha256)' \"\$d/rustup-init\" \
    && chmod +x \"\$d/rustup-init\" && \"\$d/rustup-init\" -y --no-modify-path --default-toolchain stable; rc=\$?; rm -rf \"\$d\"; exit \$rc; }" \
  || soft_fail "rustup install failed (rustup-init fetch/verify/run — see pins.sh)"

# Keep stable current on re-runs (no-op when already up to date).
as_user 'test -x "$HOME/.cargo/bin/rustup" && "$HOME/.cargo/bin/rustup" update stable >/dev/null 2>&1' \
  || stale_warn "rustup update stable failed — the toolchain stays at its current version (network? see rustup output by re-running as $TARGET_USER)"

# Validate the toolchain actually landed (curl|sh can exit 0 on a masked fetch failure).
as_user 'test -x "$HOME/.cargo/bin/cargo" && test -x "$HOME/.cargo/bin/rustc"' \
  || soft_fail "rust toolchain missing after rustup (fetch/install may have failed)"
