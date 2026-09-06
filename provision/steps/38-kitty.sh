#!/usr/bin/env bash
# Step 38 — kitty, from upstream's SIGNED binary bundle.
#
# Why this path and not the others (all checked 2026-09-06, arm64 26.04):
#   cargo   — N/A. kitty is C + Python (Go for `kitten`), not Rust, so the
#             step-35 toolchain that builds Alacritty buys nothing here.
#   brew    — no Linux formula at all (formula/kitty.json -> 404); macOS cask
#             only. The same dead end as Alacritty's deprecated formula.
#   apt     — 0.45.0 against upstream 0.48.2, and frozen for the release. apt
#             was already rejected for Alacritty for exactly this reason;
#             taking it here would leave the two terminals inconsistent.
#   flatpak — kitty is not on Flathub (both plausible app-IDs 404), and a
#             sandboxed terminal would run the user's shell inside the sandbox.
#   snap    — this machine has no snapd by design (see step 36).
#
# The interesting difference from Alacritty: upstream ships NO Linux binary for
# Alacritty (v0.17.0's assets are Windows/macOS plus man pages and completions),
# which is why step 36 must build from crates.io. kitty publishes a per-arch
# .txz AND a detached OpenPGP signature — so this step VERIFIES it against a
# PINNED fingerprint, the same fail-closed pattern verify_keyring() applies to
# the Docker/Cursor/VSCodium apt keys. That makes kitty the only artifact here
# verified by SIGNATURE rather than by checksum-over-TLS. The others are NOT
# unverified: cargo checks the crates.io index cksum (step 36 also passes
# --locked), rustup checks the channel manifest's per-artifact hash, and the
# Claude installer fails closed on a sha256sum mismatch. The difference is that
# in all three the hash is served by the SAME host as the artifact, so it does
# not survive that host being compromised — whereas the fingerprint pinned
# below lives in this repo, so a swapped key fails closed.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# A headless agent box needs no GUI terminal — same rule as step 36.
minimal && { log "kitty: skipped (PROFILE=minimal)"; exit 0; }

# Ensure this step's own tools rather than assuming an earlier step left them —
# the same rule step 36 states for its build deps, and it is load-bearing here:
# `gnupg` is Priority: optional and is NOT in apt.list (the list carries `gpg`),
# and `xz-utils` (for `tar -J`) is not there either. Today they happen to exist
# because step 20 installs gnupg first; that is exactly the cross-step coupling
# the convention forbids, and it would break this step run standalone.
apt_install curl gnupg xz-utils

# Kovid Goyal's release-signing key. Pinned: a mismatch must SKIP the install,
# never fall back to installing unverified. Served from his own domain, so this
# is trust-on-first-use rather than a web of trust — still strictly better than
# an unsigned tarball, and the pin makes a silent key swap fail closed.
KITTY_FP="3CE1780F78DD88DF45194FD706BC317B515ACE7C"
KITTY_KEY_URL="https://calibre-ebook.com/signatures/kovid.gpg"
KITTY_VER_URL="https://sw.kovidgoyal.net/kitty/current-version.txt"
KITTY_REL="https://github.com/kovidgoyal/kitty/releases/download"

APP="$TARGET_HOME/.local/kitty.app"
BINDIR="$TARGET_HOME/.local/bin"
APPSDIR="$TARGET_HOME/.local/share/applications"

# kitty names its assets x86_64/arm64; dpkg says amd64/arm64.
#
# An arch upstream publishes no binary for (ppc64el, s390x, riscv64) WARNS and
# skips rather than soft_fail-ing. soft_fail would abort a GOLDEN build, and
# that is disproportionate for a condition the operator cannot act on: nothing
# they change makes an upstream binary exist. This mirrors vendor_apt_update in
# step 20, which warns instead of soft_failing even under STRICT for the same
# reason — soft_fail is for failures worth stopping an image build over.
# Structural non-applicability belongs with the PROFILE=minimal skip above.
_karch_raw="$(dpkg --print-architecture 2>/dev/null)"
case "$_karch_raw" in
  arm64) karch=arm64 ;;
  amd64) karch=x86_64 ;;
  *)     warn "kitty: skipped — upstream ships no binary for architecture '${_karch_raw:-unknown}'"; exit 0 ;;
esac

if dry; then
  would "resolve the current kitty version from $KITTY_VER_URL"
  would "download kitty-<ver>-$karch.txz + .sig from $KITTY_REL"
  would "verify the OpenPGP signature against pinned fingerprint $KITTY_FP (mismatch => skip, never install unverified)"
  would "extract to $APP and link kitty+kitten into $BINDIR"
  would "install kitty.desktop + kitty-open.desktop into $APPSDIR (Exec/Icon rewritten to $TARGET_HOME)"
  exit 0
fi

ver="$(curl -fsSL --max-time 30 "$KITTY_VER_URL" 2>/dev/null | tr -d '[:space:]')"
case "$ver" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) soft_fail "kitty: could not resolve the current version (got '${ver:-<empty>}')"; exit 0 ;;
esac

# Idempotent: a re-run on an up-to-date box does nothing. Bring-to-latest still
# applies — a newer upstream release reinstalls (see CLAUDE.md's philosophy).
cur="$("$APP/bin/kitty" --version 2>/dev/null | awk '{print $2}')"
if [ "$cur" = "$ver" ]; then
  log "kitty $ver is already installed — skipping"
  exit 0
fi
log "kitty: installing $ver ($karch)${cur:+ — upgrading from $cur}"

tmp="$(mktemp -d)" || { soft_fail "kitty: mktemp failed"; exit 0; }
trap 'rm -rf "$tmp"' EXIT
tarball="kitty-$ver-$karch.txz"

curl -fsSL --max-time 300 -o "$tmp/$tarball"     "$KITTY_REL/v$ver/$tarball" \
  && curl -fsSL --max-time 60 -o "$tmp/$tarball.sig" "$KITTY_REL/v$ver/$tarball.sig" \
  && curl -fsSL --max-time 60 -o "$tmp/kovid.gpg"    "$KITTY_KEY_URL" \
  || { soft_fail "kitty: download failed (tarball, signature, or signing key)"; exit 0; }

# Pin check BEFORE the key is ever used to verify anything.
verify_keyring "$tmp/kovid.gpg" "$KITTY_FP" \
  || { soft_fail "kitty: signing key fingerprint mismatch — refusing to install"; exit 0; }

# Throwaway keyring inside $tmp so we never touch root's real GnuPG home.
export GNUPGHOME="$tmp/gnupg"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
if ! gpg --batch --quiet --import "$tmp/kovid.gpg" 2>/dev/null \
   || ! gpg --batch --verify "$tmp/$tarball.sig" "$tmp/$tarball" 2>/dev/null; then
  soft_fail "kitty: OpenPGP signature verification FAILED for $tarball — not installing"
  exit 0
fi
log "kitty: signature verified against pinned key $KITTY_FP"

# Replace the tree wholesale so an upgrade can't leave stale files behind.
# $TARGET_HOME is guaranteed non-empty by lib.sh (it dies when no non-root user
# resolves), but re-assert here: this is an rm -rf on a derived path.
case "$APP" in
  "$TARGET_HOME"/.local/kitty.app) ;;
  *) soft_fail "kitty: refusing to touch unexpected path '$APP'"; exit 0 ;;
esac
$SUDO rm -rf "$APP"
$SUDO mkdir -p "$APP" "$BINDIR" "$APPSDIR" || { soft_fail "kitty: could not create $APP"; exit 0; }
$SUDO tar -xJf "$tmp/$tarball" -C "$APP" \
  || { soft_fail "kitty: extracting $tarball failed"; exit 0; }

# kitty and kitten on PATH. Relative-free symlinks so they survive a $HOME move
# no worse than the rest of the tree does.
$SUDO ln -sf "$APP/bin/kitty" "$APP/bin/kitten" "$BINDIR/" \
  || warn "kitty: could not link kitty/kitten into $BINDIR"

# Desktop integration. Same BASENAMES as apt's kitty package on purpose: a
# user-level .desktop overrides the system one by XDG precedence, so a box that
# happens to have apt's kitty shows ONE menu entry pointing at this build
# rather than two competing ones.
for d in kitty.desktop kitty-open.desktop; do
  if [ -f "$APP/share/applications/$d" ]; then
    $SUDO cp -f "$APP/share/applications/$d" "$APPSDIR/$d" \
      && $SUDO sed -i \
        -e "s|Icon=kitty|Icon=$TARGET_HOME/.local/kitty.app/share/icons/hicolor/256x256/apps/kitty.png|g" \
        -e "s|Exec=kitty|Exec=$TARGET_HOME/.local/kitty.app/bin/kitty|g" \
        "$APPSDIR/$d" \
      || warn "kitty: desktop entry $d incomplete"
  fi
done

# Everything above ran as root into a user-owned home.
$SUDO chown -R "$TARGET_USER":"$TARGET_GROUP" "$APP" "$BINDIR" "$APPSDIR" \
  || soft_fail "kitty: could not chown $APP to $TARGET_USER"

# Deliberately NOT written: ~/.config/xdg-terminals.list. That would make kitty
# the default terminal for the whole desktop, which is a user preference, not a
# provisioning decision — Alacritty is installed alongside and neither wins.
log "kitty $ver installed to $APP (kitty + kitten on PATH via $BINDIR)"
