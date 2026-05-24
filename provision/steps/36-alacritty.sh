#!/usr/bin/env bash
# Step 36 — Alacritty, built from crates.io via cargo (latest stable release).
# Replaces the old snap so the machine needs no snapd. The binary lands in
# ~/.cargo/bin/alacritty (on PATH via .zshrc's ~/.cargo/env). `cargo install`
# does NOT add desktop integration, so terminfo/.desktop/icon are pulled from
# the matching upstream tag afterwards (all best-effort).
#
# Trade-off: building Alacritty compiles a large Rust dep tree — slow and
# RAM-hungry on small instances. apt's `alacritty` is the lighter (but frozen)
# alternative if that ever bites.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

log "Alacritty: build deps + cargo install (as '$TARGET_USER')"

# Build deps per Alacritty's INSTALL.md (Ubuntu). build-essential is from step 10.
apt_install cmake pkg-config libfreetype6-dev libfontconfig1-dev \
            libxcb-xfixes0-dev libxkbcommon-dev python3

# cargo comes from step 35. Source ~/.cargo/env because rustup --no-modify-path
# means cargo isn't on PATH in a fresh non-login shell yet.
as_user 'set -e; . "$HOME/.cargo/env"; cargo install alacritty --locked' \
  || warn "cargo install alacritty failed"

# Desktop integration from the tag matching the installed version (terminfo,
# .desktop, icon). Best-effort: a failure here warns but never aborts the run.
as_user 'set -e; . "$HOME/.cargo/env"; \
  ver="$(alacritty --version 2>/dev/null | cut -d" " -f2)"; [ -n "$ver" ] || exit 0; \
  base="https://raw.githubusercontent.com/alacritty/alacritty/v$ver/extra"; \
  appdir="$HOME/.local/share/applications"; \
  icondir="$HOME/.local/share/icons/hicolor/scalable/apps"; \
  mkdir -p "$appdir" "$icondir"; \
  infocmp alacritty >/dev/null 2>&1 || { \
    t="$(mktemp)"; curl -fsSL "$base/alacritty.info" -o "$t" \
      && tic -xe alacritty,alacritty-direct -o "$HOME/.terminfo" "$t"; rm -f "$t"; }; \
  curl -fsSL "$base/logo/alacritty-term.svg" -o "$icondir/Alacritty.svg"; \
  curl -fsSL "$base/linux/Alacritty.desktop" -o "$appdir/Alacritty.desktop"' \
  || warn "alacritty desktop integration incomplete — continuing"
