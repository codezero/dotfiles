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
            libfontconfig1-dev fontconfig libxcb-xfixes0-dev libxkbcommon-dev python3

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

# Shell completions (zsh/bash/fish) from the matching release tag. `cargo install`
# places only the binary; completions live in the repo's extra/ dir. Install them
# SYSTEM-WIDE (as root) so every shell/user gets them — esp. zsh's `_alacritty`.
# Best-effort: a fetch/install miss warns, never aborts.
if dry; then
  would "fetch alacritty completions for the installed version + install system-wide:"
  would "  _alacritty     -> /usr/share/zsh/vendor-completions/_alacritty"
  would "  alacritty.bash -> /usr/share/bash-completion/completions/alacritty"
  would "  alacritty.fish -> /usr/share/fish/vendor_completions.d/alacritty.fish"
else
  comp_ver="$(as_user '. "$HOME/.cargo/env" 2>/dev/null; alacritty --version 2>/dev/null | cut -d" " -f2')"
  if [ -n "$comp_ver" ]; then
    log "Alacritty shell completions (v$comp_ver), system-wide"
    cbase="https://raw.githubusercontent.com/alacritty/alacritty/v$comp_ver/extra/completions"
    for pair in \
      "_alacritty|/usr/share/zsh/vendor-completions/_alacritty" \
      "alacritty.bash|/usr/share/bash-completion/completions/alacritty" \
      "alacritty.fish|/usr/share/fish/vendor_completions.d/alacritty.fish"; do
      src="${pair%%|*}"; dest="${pair##*|}"; t="$(mktemp)"
      if curl -fsSL "$cbase/$src" -o "$t"; then
        $SUDO mkdir -p "$(dirname "$dest")" && $SUDO cp "$t" "$dest" \
          || warn "alacritty completion install failed: $dest"
      else
        warn "alacritty completion fetch failed: $src"
      fi
      rm -f "$t"
    done
  else
    warn "alacritty version unknown — skipping shell completions"
  fi
fi

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
  || soft_fail "alacritty theme catppuccin_mocha.toml missing — alacritty.toml import will fail"

# MesloLGS NF — the Nerd Font that .p10k.zsh (POWERLEVEL9K_MODE=nerdfont-v3) and
# alacritty.toml's `[font].family` both require. A fresh Ubuntu doesn't ship it,
# and without it the prompt + TUI glyphs render as tofu. The TTFs are VENDORED in
# the repo (fonts/MesloLGS-NF) — no network fetch, works offline — and copied
# SYSTEM-WIDE so the font is available to every user (survives a different
# PROVISION_USER in a golden image). fc-cache comes from fontconfig (above).
fontsrc="$DOTFILES_ROOT/fonts/MesloLGS-NF"
fontdir="/usr/local/share/fonts/MesloLGS-NF"
if [ -d "$fontsrc" ]; then
  log "MesloLGS NF: install system-wide from vendored $fontsrc"
  run mkdir -p "$fontdir"
  if dry; then
    would "cp '$fontsrc'/*.ttf -> '$fontdir/' && fc-cache -f '$fontdir'"
  else
    cp -f "$fontsrc"/*.ttf "$fontdir/" \
      && fc-cache -f "$fontdir" >/dev/null 2>&1 \
      || soft_fail "MesloLGS NF install (copy/fc-cache) failed"
  fi
else
  soft_fail "vendored fonts dir missing: $fontsrc — MesloLGS NF not installed (prompt/TUI glyphs will be tofu)"
fi
