#!/usr/bin/env bash
# ============================================================================
# pins.sh — the commits and checksums of CODE THIS REPO EXECUTES AT INSTALL
# TIME from mutable upstreams, plus the two helpers that apply them.
#
# Sourced by provision/lib.sh AND install.sh (one owner). Steps that run as the
# target user cannot see sourced functions through `sudo -u … bash -c`, so this
# file also runs as a command:   bash pins.sh clone_pinned URL SHA DEST
#                                 bash pins.sh fetch_pinned URL SHA256 OUT
#
# WHY (TODO J, 2026-09-13): the tools this repo installs float by design — brew,
# rustup's toolchain, mise, Claude, kitty — and versions.lock records what
# landed. That policy is about TOOLS. This file is about the SCRIPTS AND SHELL
# CODE that run during provisioning: the Homebrew installer, rustup-init, the
# Claude bootstrap, and three git clones whose code runs in every shell
# (oh-my-zsh, powerlevel10k, alacritty-theme). Until now each of those was
# fetched from a moving branch and executed unverified — weaker than any brew
# formula, whose sha256 sits in homebrew-core. Pinning them is a security
# control, not a version policy: nothing here moves except by editing this
# file, i.e. a reviewed commit.
#
# HOW TO BUMP: read the upstream change first (`git log OLD..NEW` for a clone,
# a diff of the script for a hash), then edit the value here and commit.
# versions.lock's `git` kind records the SHA that actually landed, so a bump
# shows up as drift exactly once. The cadence is written down in
# provision/README.md ("Supply chain").
#
# HONEST LIMITS: a pinned installer script still installs a moving payload —
# the Homebrew installer clones Homebrew/brew at its current release, the Claude
# bootstrap fetches the current manifest (which it verifies by sha256 itself),
# rustup-init installs the current stable toolchain (verified by rustup against
# its channel manifest). This closes the script, not the ecosystem.
# ============================================================================
# shellcheck disable=SC2034  # values are consumed by the scripts that source this file

# ── git clones that ship code run by every shell ─────────────────────────────
OMZ_SHA=be8da5c77192eb3da3699ea7c5e47bdfaa5eea4e                 # ohmyzsh/ohmyzsh            HEAD 2026-09-11
P10K_SHA=d05a1b00f9a61f9578bf9dc19b8451942dde8734                # romkatv/powerlevel10k      HEAD 2026-09-06
ALACRITTY_THEME_SHA=ab88d5a80d676b5dc6157e91aba8067f2078dc94     # alacritty/alacritty-theme  HEAD 2026-09-11
OMZ_URL=https://github.com/ohmyzsh/ohmyzsh
P10K_URL=https://github.com/romkatv/powerlevel10k
ALACRITTY_THEME_URL=https://github.com/alacritty/alacritty-theme

# ── installer scripts / binaries executed once ───────────────────────────────
# Homebrew/install: the raw URL is pinned to a COMMIT (not HEAD) and the file
# is verified against the hash recorded here before it runs.
HOMEBREW_INSTALL_COMMIT=fde1410a61157a71c78d2dc0c3a57a3a848b9756     # 2026-09-11
HOMEBREW_INSTALL_SHA256=25548e1da7930c1563dbbe2cb05834a4131c4da09234540b6fdac812fda3c287
HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/$HOMEBREW_INSTALL_COMMIT/install.sh"

# rustup: NOT sh.rustup.rs (a script that downloads whatever rustup-init is
# current). The versioned binary from static.rust-lang.org/rustup/archive, whose
# hash is recorded HERE — upstream's .sha256 file is same-host and is only used
# when bumping, to fill these in.
RUSTUP_VERSION=1.29.1
RUSTUP_INIT_SHA256_aarch64=15f6e4ce9f583b929c996c91562bad6d4454f3281de858b02cdfdef615fac433
RUSTUP_INIT_SHA256_x86_64=dda7234360b7f578ca8b0ddcb80145646fa61a67c1720a5abc7051b35c9fcb71
rustup_init_url() { echo "https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/$(uname -m)-unknown-linux-gnu/rustup-init"; }
rustup_init_sha256() { local v; v="RUSTUP_INIT_SHA256_$(uname -m)"; echo "${!v:-}"; }

# Claude Code: claude.ai/install.sh is a 302 to this bootstrap script. Pinned by
# hash; when Anthropic changes it the step refuses and says to review + re-pin.
CLAUDE_BOOTSTRAP_URL=https://downloads.claude.ai/claude-code-releases/bootstrap.sh
CLAUDE_BOOTSTRAP_SHA256=3a68d3406cf674e17bed1733a4dcf37805e2e47d87417700007d7e1aa766a944

# ── helpers ──────────────────────────────────────────────────────────────────
# clone_pinned URL SHA DEST — a shallow clone at EXACTLY that commit, detached,
# so nothing moves it but a pin bump. GitHub serves reachable commits by SHA.
# The git-config lines mirror what oh-my-zsh's own installer sets, so `omz`
# keeps working on a pinned checkout (its updater is set to remind, not act —
# see .zshrc).
clone_pinned() {
  local url="$1" sha="$2" dest="$3"
  case "$sha" in [0-9a-f]*) [ "${#sha}" -eq 40 ] ;; *) false ;; esac \
    || { echo "clone_pinned: '$sha' is not a 40-hex commit (pins.sh)" >&2; return 2; }
  case "$dest" in ""|/|"$HOME") echo "clone_pinned: refusing to clone into '$dest'" >&2; return 2 ;; esac
  rm -rf "$dest" && mkdir -p "$dest" \
    && git -C "$dest" init -q \
    && git -C "$dest" config core.autocrlf false \
    && git -C "$dest" config fsck.zeroPaddedFilemode ignore \
    && git -C "$dest" config fetch.fsck.zeroPaddedFilemode ignore \
    && git -C "$dest" config receive.fsck.zeroPaddedFilemode ignore \
    && git -C "$dest" config oh-my-zsh.remote origin \
    && git -C "$dest" config oh-my-zsh.branch master \
    && git -C "$dest" remote add origin "$url" \
    && git -C "$dest" fetch -q --depth=1 origin "$sha" \
    && git -C "$dest" checkout -q --detach FETCH_HEAD \
    && [ "$(git -C "$dest" rev-parse HEAD)" = "$sha" ] \
    || { echo "clone_pinned: could not check out $url @ $sha into $dest" >&2; return 1; }
}

# fetch_pinned URL SHA256 OUT — download, verify, or refuse. A mismatch names
# the URL and both hashes and says what to do; it never leaves the file behind
# for something to run anyway.
fetch_pinned() {
  local url="$1" want="$2" out="$3" got
  [ "${#want}" -eq 64 ] || { echo "fetch_pinned: expected hash for $url is not sha256 (pins.sh)" >&2; return 2; }
  # https only — except under the smoke tier, which exercises this with file://
  # URLs and no network (PINS_TEST_ALLOW_FILE=1 is set by smoke-test.sh alone).
  local proto='=https'; [ "${PINS_TEST_ALLOW_FILE:-0}" = 1 ] && proto='=https,file'
  curl --proto "$proto" --tlsv1.2 -fsSL --max-time 120 -o "$out" "$url" \
    || { echo "fetch_pinned: download failed: $url" >&2; rm -f "$out"; return 1; }
  got="$(sha256sum "$out" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    rm -f "$out"
    echo "fetch_pinned: REFUSING $url — sha256 $got, pinned $want. Upstream changed the script: read the new version, then re-pin it in provision/pins.sh." >&2
    return 1
  fi
}

# Run as a command (steps invoke it inside `as_user`, where sourced functions
# are out of reach); a no-op when sourced.
case "${1:-}" in
  clone_pinned|fetch_pinned) [ "${BASH_SOURCE[0]}" = "$0" ] && "$@" ;;
esac
