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

# Build deps per Alacritty's INSTALL.md (Ubuntu). Ensure build-essential (cc +
# linker), curl, and git HERE rather than assuming an earlier step provided them
# — otherwise a missing compiler surfaces as a cryptic cargo/link error, and the
# step can't run standalone.
apt_install build-essential curl git cmake pkg-config libfreetype6-dev \
            libfontconfig1-dev libxcb-xfixes0-dev libxkbcommon-dev python3

# cargo comes from step 35. Source ~/.cargo/env because rustup --no-modify-path
# means cargo isn't on PATH in a fresh non-login shell yet.
as_user 'set -e; . "$HOME/.cargo/env"; cargo install alacritty --locked' \
  || soft_fail "cargo install alacritty failed"

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

# Color themes — alacritty.toml imports one from here. Clone the upstream repo
# rather than vendoring ~190 theme files. Skip if already a checkout; clone if
# empty/missing; but DON'T wipe a non-empty non-git dir (could be custom themes).
as_user 'set -e; d="$HOME/.config/alacritty/themes"; \
  if [ -d "$d/.git" ]; then exit 0; fi; \
  if [ -e "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then \
    echo "[warn] $d is not a git checkout — leaving it (theme import may be missing)" >&2; exit 0; fi; \
  rm -rf "$d"; git clone --depth=1 https://github.com/alacritty/alacritty-theme "$d"' \
  || soft_fail "alacritty theme clone failed"
# Confirm the theme that alacritty.toml imports actually resolved.
as_user 'test -f "$HOME/.config/alacritty/themes/themes/catppuccin_mocha.toml"' \
  || warn "alacritty theme catppuccin_mocha.toml missing — alacritty.toml import will fail"
