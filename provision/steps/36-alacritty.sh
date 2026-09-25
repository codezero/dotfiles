#!/usr/bin/env bash
# Step 36 — Alacritty, built from crates.io via cargo (latest stable release).
# Replaces the old snap so the machine needs no snapd. The binary lands in
# ~/.cargo/bin/alacritty (on PATH via .zshrc's ~/.cargo/env). `cargo install`
# does NOT add desktop integration, so the .desktop/icon/completions are
# taken from the crate's extra/ dir afterwards — the .crate re-fetched from
# crates.io and verified against the index's sha256 (all best-effort).
#
# Trade-off: building Alacritty compiles a large Rust dep tree — slow and
# RAM-hungry on small instances. apt's `alacritty` is the lighter (but frozen)
# alternative if that ever bites.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# No GUI wanted (PROFILE=minimal or HEADLESS=1): no GUI terminal, and no Nerd
# Font — that's only for glyph rendering in a terminal emulator; the p10k prompt
# itself degrades fine. The gate is lib.sh's gui_wanted, shared by every GUI step.
gui_wanted || { log "alacritty: skipped ($(no_gui_reason))"; exit 0; }

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

# Ancillary files — .desktop, icon, and the zsh/bash/fish completions.
# NOT terminfo: until 2026-09-24 this step also tic'd the crate's alacritty.info
# into $HOME/.terminfo, which was wrong twice over — it covered exactly ONE
# account (not a second user, not root), and terminfo for inbound ssh is not
# this step's business at all. `ncurses-term` in the apt lists carries the
# alacritty entries for every account on every profile, including boxes where
# Alacritty is never installed. ~/.terminfo is the USER's now; the repo does not
# write it, so anything they put there wins (ncurses searches it first).
# `cargo install` places only the binary; the rest live in the
# crate's extra/ dir. Until 2026-09-22 they were fetched from
# raw.githubusercontent.com at the matching tag with NO hash — and the zsh
# completion is code sourced by every shell of every user, installed
# system-wide (external assessment, finding 5). Now they come from the crate
# itself: the sparse index at index.crates.io gives the sha256 cargo itself
# checked the crate against, the .crate is fetched from static.crates.io,
# verified against it, and extra/ is unpacked in root's tmp. Same host
# relationship as `cargo install`, no user-writable path involved (root never
# reads the user's ~/.cargo copy — a tampered file there would be exactly the
# escalation we are closing), no GitHub. Refuses on mismatch. Skipped when the
# installed version already has its files (stamp) — a bring-to-latest that
# lands a newer alacritty refreshes them.
ALACRITTY_EXTRA_STAMP=/usr/local/share/alacritty-extra.version
fetch_alacritty_extra() {  # <version> <outdir> — leaves <outdir>/extra/
  local ver="$1" out="$2" idx cksum crate got
  idx="$(curl --proto '=https' --tlsv1.2 -fsSL --max-time 60 https://index.crates.io/al/ac/alacritty)" || return 1
  cksum="$(grep -F "\"vers\":\"$ver\"" <<<"$idx" | sed -n 's/.*"cksum":"\([0-9a-f]\{64\}\)".*/\1/p' | head -1)"
  [ "${#cksum}" -eq 64 ] || { warn "alacritty: no sha256 for $ver in the crates.io index"; return 1; }
  crate="$out/alacritty-$ver.crate"
  curl --proto '=https' --tlsv1.2 -fsSL --max-time 120 -o "$crate" "https://static.crates.io/crates/alacritty/alacritty-$ver.crate" || return 1
  got="$(sha256sum "$crate" | cut -d' ' -f1)"
  [ "$got" = "$cksum" ] || { warn "alacritty: REFUSING crate $ver — sha256 $got, crates.io index says $cksum"; return 1; }
  tar -xzf "$crate" -C "$out" --strip-components=1 "alacritty-$ver/extra" && [ -d "$out/extra/completions" ]
}
if dry; then
  would "fetch alacritty-<ver>.crate from static.crates.io, verify against the index.crates.io sha256, unpack extra/"
  would "install completions system-wide from it: _alacritty, alacritty.bash, alacritty.fish"
  would "(as $TARGET_USER) Alacritty.desktop + icon -> ~/.local/share (Exec rewritten to ~/.cargo/bin)"
else
  ver="$(as_user '. "$HOME/.cargo/env" 2>/dev/null; alacritty --version 2>/dev/null | cut -d" " -f2')"
  if [ -z "$ver" ]; then
    warn "alacritty version unknown — skipping completions and desktop integration"
  elif [ "$(cat "$ALACRITTY_EXTRA_STAMP" 2>/dev/null)" = "$ver" ] && [ -f /usr/share/zsh/vendor-completions/_alacritty ]; then
    log "alacritty $ver ancillary files already installed — skipping"
  else
    xt="$(mktemp -d)"
    if fetch_alacritty_extra "$ver" "$xt"; then
      log "Alacritty $ver: completions (system-wide) + desktop integration, from the verified crate"
      for pair in \
        "_alacritty|/usr/share/zsh/vendor-completions/_alacritty" \
        "alacritty.bash|/usr/share/bash-completion/completions/alacritty" \
        "alacritty.fish|/usr/share/fish/vendor_completions.d/alacritty.fish"; do
        src="${pair%%|*}"; dest="${pair##*|}"
        # install -m 0644 (NOT cp): 0644 = world-readable like a packaged
        # completion (root-owned 0644 is compaudit-secure); a 0600 copy would
        # make every user's compinit fail with "permission denied".
        $SUDO mkdir -p "$(dirname "$dest")" && $SUDO install -m 0644 "$xt/extra/completions/$src" "$dest" \
          || warn "alacritty completion install failed: $dest"
      done
      # Desktop integration as the user, from the same verified extract (the
      # tmp dir is opened up read-only for that; it holds public crate files).
      chmod -R a+rX "$xt"
      as_user "set -e; x='$xt/extra'; \
        appdir=\"\$HOME/.local/share/applications\"; icondir=\"\$HOME/.local/share/icons/hicolor/scalable/apps\"; \
        mkdir -p \"\$appdir\" \"\$icondir\"; \
        cp -f \"\$x/logo/alacritty-term.svg\" \"\$icondir/Alacritty.svg\"; \
        cp -f \"\$x/linux/Alacritty.desktop\" \"\$appdir/Alacritty.desktop\"; \
        sed -i \"s|^Exec=alacritty|Exec=\$HOME/.cargo/bin/alacritty|; s|^TryExec=alacritty|TryExec=\$HOME/.cargo/bin/alacritty|\" \"\$appdir/Alacritty.desktop\"" \
        || warn "alacritty desktop integration incomplete — continuing"
      printf '%s\n' "$ver" | $SUDO tee "$ALACRITTY_EXTRA_STAMP" >/dev/null
    else
      warn "alacritty $ver: could not fetch/verify the crate for completions + desktop files — skipped (re-run later)"
    fi
    rm -rf "$xt"
  fi
fi

# Color themes — alacritty.toml imports one from here. Clone the upstream repo
# rather than vendoring ~190 theme files. Skip if already a checkout; clone if
# empty/missing; but DON'T wipe a non-empty non-git dir (could be custom themes).
# Pinned clone (pins.sh ALACRITTY_THEME_SHA) — it was `git clone --depth=1` at
# whatever HEAD was that day (TODO J).
# Every run: clone_pinned converges an existing checkout to the pin, is a
# no-op at the pin, and refuses (never wipes) a non-checkout dir (2026-09-21).
as_user "bash '$PINS' clone_pinned '$ALACRITTY_THEME_URL' '$ALACRITTY_THEME_SHA' \"\$HOME/.config/alacritty/themes\"" \
  || soft_fail "alacritty theme clone/converge failed (see pins.sh)"
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

# ── legacy per-user terminfo left by earlier revisions of THIS step ──────────
# Until 2026-09-24 this step ran `tic … -o "$HOME/.terminfo"`. That write is gone
# (ncurses-term now carries the alacritty entries system-wide, for every account
# rather than one), but stopping a write does not undo it: ncurses searches
# ~/.terminfo FIRST, so on a box provisioned earlier the target user's real
# sessions keep resolving the old repo-written entry while the audit — which
# probes with `env -i` to prove the SYSTEM entry exists — passes. That gap was
# found by an external review, 2026-09-25.
#
# Reported, never deleted. ~/.terminfo is the user's space and the repo does not
# write it any more, so it must not quietly remove things from it either: what
# looks like our leftover may be a deliberate override. A `warn` lands in the
# end-of-run summary, which is exactly where a one-time manual follow-up belongs.
if ! dry; then
  legacy="$(as_user 'u="$HOME/.terminfo/a/alacritty"
    [ -e "$u" ] || exit 0
    mine="$(infocmp -1 alacritty 2>/dev/null)"
    sys="$(env -i /usr/bin/infocmp -1 alacritty 2>/dev/null)"
    [ -n "$sys" ] || exit 0
    [ "$mine" = "$sys" ] || printf %s "$u"' 2>/dev/null || true)"
  if [ -n "$legacy" ]; then
    warn "stale per-user terminfo shadows the system entry: $legacy differs from /usr/share/terminfo's. Earlier revisions of step 36 wrote it; ncurses-term owns these now. Remove it as $TARGET_USER when convenient:  rm -f ~/.terminfo/a/alacritty ~/.terminfo/a/alacritty-direct"
  fi
fi
