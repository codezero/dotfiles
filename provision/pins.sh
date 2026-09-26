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
OMZ_SHA=74965c96098134b192f00084f966b4b02438a739     # omz HEAD 2026-09-24 (bumped 2026-09-24 from 86ef655: 6 commits, log reviewed via `pins.sh bump`)
P10K_SHA=d05a1b00f9a61f9578bf9dc19b8451942dde8734                # romkatv/powerlevel10k      HEAD 2026-09-06
ALACRITTY_THEME_SHA=ab88d5a80d676b5dc6157e91aba8067f2078dc94     # alacritty/alacritty-theme  HEAD 2026-09-11
OMZ_URL=https://github.com/ohmyzsh/ohmyzsh
P10K_URL=https://github.com/romkatv/powerlevel10k
ALACRITTY_THEME_URL=https://github.com/alacritty/alacritty-theme

# ── installer scripts / binaries executed once ───────────────────────────────
# Homebrew/install: the raw URL is pinned to a COMMIT (not HEAD) and the file
# is verified against the hash recorded here before it runs.
HOMEBREW_INSTALL_COMMIT=0a396a4ee5b538f409de666af904fa0570b53949     # 2026-09-25 (bumped from e53db71a; diff reviewed via `pins.sh bump`)
HOMEBREW_INSTALL_SHA256=f31a38f097f3b5bbfdc110658e4a9876d0c023ccc9ef2e70527f5b8a762e505e     # sha256 of install.sh at that commit
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
# clone_pinned URL SHA DEST — DEST ends up a checkout of EXACTLY that commit,
# detached, so nothing moves it but a pin bump. GitHub serves reachable commits
# by SHA. The git-config lines mirror what oh-my-zsh's own installer sets, so
# `omz` keeps working on a pinned checkout (its updater is set to remind, not
# act — see .zshrc). Idempotent and CONVERGING (2026-09-21): a checkout already
# at SHA is a no-op with no network; a checkout at any other commit (an `omz
# update` by hand, or a pin bumped in the repo after the box was built) is
# fetched and moved to SHA — untracked content such as ~/.oh-my-zsh/custom/
# survives, a partial/interrupted clone is completed. Before this the callers
# gated on a sentinel file, so a bumped pin only ever reached FRESH boxes and
# every existing one stayed red in `verify` forever. A non-empty DEST that is
# not a git checkout is refused, never wiped.
clone_pinned() {
  local url="$1" sha="$2" dest="$3"
  case "$sha" in [0-9a-f]*) [ "${#sha}" -eq 40 ] ;; *) false ;; esac \
    || { echo "clone_pinned: '$sha' is not a 40-hex commit (pins.sh)" >&2; return 2; }
  case "$dest" in ""|/|"$HOME") echo "clone_pinned: refusing to clone into '$dest'" >&2; return 2 ;; esac
  if [ -d "$dest/.git" ]; then
    # At the pin is not enough: the TRACKED files must be what that commit
    # says (2026-09-22, assessment). Untracked content (omz's custom/) is
    # exempt. A local edit is never reset silently — say what to do.
    if [ "$(git -C "$dest" rev-parse HEAD 2>/dev/null)" = "$sha" ]; then
      if [ -n "$(git -C "$dest" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        echo "clone_pinned: $dest is at $sha but tracked files are modified locally — \`git -C '$dest' checkout -- .\` to discard, or move it aside" >&2; return 1
      fi
      return 0
    fi
    git -C "$dest" fetch -q --depth=1 origin "$sha" \
      && git -C "$dest" checkout -q --detach FETCH_HEAD \
      && [ "$(git -C "$dest" rev-parse HEAD)" = "$sha" ] \
      || { echo "clone_pinned: $dest is a checkout but could not be moved to $sha (local changes? wrong remote?) — fix or move it aside" >&2; return 1; }
    return 0
  fi
  if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    echo "clone_pinned: $dest exists and is not a git checkout — move it aside first (refusing to wipe it)" >&2; return 1
  fi
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

# ── bump — the cadence, as one command (2026-09-21) ──────────────────────────
#   bash pins.sh bump [--check] omz|p10k|alacritty-theme|brew-installer|claude-bootstrap|rustup|all
# For each pin: look upstream, show what changed since the pin (the git log for
# a clone, the diff for a script, the version for rustup) — THAT is the review —
# then rewrite the pin line here, converge the local checkout if this box has
# one, and stage this file. Nothing is committed: the commit is the reviewed
# act. --check only reports (exit 1 = something is behind). Why it exists: on a daily box `omz update` would
# make the tool a second owner of code the pin owns; the pin wins, so bumping
# has to be as easy as the tool's own updater (.zshrc routes `omz update` here).
# ABSOLUTE, always: callers do `git -C "$(dirname …)" add "$(…)"`, and with a
# relative BASH_SOURCE (`bash provision/pins.sh bump …` from the repo root)
# that resolves to provision/provision/pins.sh and fails. It failed silently
# for two days because the `git add` was 2>/dev/null'd while bump still
# printed "rewritten and staged" (2026-09-24).
_pins_file() { printf '%s/%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" "$(basename "${BASH_SOURCE[0]}")"; }
_pin_get() { grep -E "^$1=" "$(_pins_file)" | head -1 | cut -d= -f2 | cut -d' ' -f1 | tr -d '"'; }
# _pin_set VAR VALUE COMMENT — replace the whole VAR= line; the rest of the
# file stays byte-identical (the dry tier asserts that).
_pin_set() {
  local var="$1" val="$2" note="$3" f; f="$(_pins_file)"
  grep -qE "^$var=" "$f" || { echo "bump: no pin named $var in $f" >&2; return 2; }
  awk -v var="$var" -v val="$val" -v note="$note" '
    index($0, var "=") == 1 { print var "=" val "     # " note; next } { print }' "$f" > "$f.tmp" \
    && mv "$f.tmp" "$f"
}
_bump_clone() {  # NAME VAR URL DEST — a git pin
  local name="$1" var="$2" url="$3" dest="$4" old new n t
  old="$(_pin_get "$var")"
  new="$(git ls-remote "$url" HEAD 2>/dev/null | cut -f1)"
  [ -n "$new" ] || { echo "bump $name: cannot reach $url" >&2; return 1; }
  if [ "$new" = "$old" ]; then echo "bump $name: at upstream HEAD (${old:0:12}) — nothing to do"; return 0; fi
  # The review: every commit between the pin and HEAD. Shallow-fetch HEAD and
  # deepen until the pin is reachable (GitHub serves commits by SHA).
  t="$(mktemp -d)"; git -C "$t" init -q && git -C "$t" remote add origin "$url" \
    && git -C "$t" fetch -q --depth=1 origin "$new" && git -C "$t" fetch -q --depth=1 origin "$old" 2>/dev/null
  n=0; while ! git -C "$t" merge-base --is-ancestor "$old" "$new" 2>/dev/null && [ "$n" -lt 20 ]; do
    git -C "$t" fetch -q --deepen=100 origin "$new" 2>/dev/null; n=$((n+1)); done
  echo "── bump $name: ${old:0:12} -> ${new:0:12} — upstream log (READ IT):"
  git -C "$t" log --format='   %h %ad %s' --date=short "$old..$new" 2>/dev/null || echo "   (log unavailable: pin not an ancestor of HEAD?)"
  local count; count="$(git -C "$t" rev-list --count "$old..$new" 2>/dev/null || echo '?')"
  rm -rf "$t"
  [ "$CHECK" = 1 ] && { echo "   ($count commits; --check: not written)"; return 3; }
  _pin_set "$var" "$new" "$name HEAD $(date -u +%F) (bumped $(date -u +%F) from ${old:0:7}: $count commits, log reviewed via \`pins.sh bump\`)" || return 1
  if [ -d "$dest/.git" ]; then
    if clone_pinned "$url" "$new" "$dest"; then echo "   converged $dest to ${new:0:12}"
    else echo "   pin rewritten, but $dest was NOT moved to it (see above) — fix the checkout, then re-run the box's recipe" >&2; return 1; fi
  fi
  return 3
}
_bump_brew() {
  local old new t1 t2 h
  old="$(_pin_get HOMEBREW_INSTALL_COMMIT)"
  new="$(git ls-remote https://github.com/Homebrew/install HEAD 2>/dev/null | cut -f1)"
  [ -n "$new" ] || { echo "bump brew-installer: cannot reach GitHub" >&2; return 1; }
  if [ "$new" = "$old" ]; then echo "bump brew-installer: at upstream HEAD (${old:0:12}) — nothing to do"; return 0; fi
  t1="$(mktemp)"; t2="$(mktemp)"
  curl --proto '=https' --tlsv1.2 -fsSL "https://raw.githubusercontent.com/Homebrew/install/$old/install.sh" -o "$t1" \
    && curl --proto '=https' --tlsv1.2 -fsSL "https://raw.githubusercontent.com/Homebrew/install/$new/install.sh" -o "$t2" \
    || { echo "bump brew-installer: download failed" >&2; rm -f "$t1" "$t2"; return 1; }
  echo "── bump brew-installer: ${old:0:12} -> ${new:0:12} — diff of install.sh (READ IT; look for curl/eval/sudo/base64):"
  diff "$t1" "$t2" | sed 's/^/   /'
  h="$(sha256sum "$t2" | cut -d' ' -f1)"; rm -f "$t1" "$t2"
  [ "$CHECK" = 1 ] && { echo "   (--check: not written)"; return 3; }
  _pin_set HOMEBREW_INSTALL_COMMIT "$new" "$(date -u +%F) (bumped from ${old:0:8}; diff reviewed via \`pins.sh bump\`)" \
    && _pin_set HOMEBREW_INSTALL_SHA256 "$h" "sha256 of install.sh at that commit" && return 3
}
_bump_claude() {
  local old t h
  old="$(_pin_get CLAUDE_BOOTSTRAP_SHA256)"; t="$(mktemp)"
  curl --proto '=https' --tlsv1.2 -fsSL "$CLAUDE_BOOTSTRAP_URL" -o "$t" || { echo "bump claude-bootstrap: download failed" >&2; rm -f "$t"; return 1; }
  h="$(sha256sum "$t" | cut -d' ' -f1)"
  if [ "$h" = "$old" ]; then echo "bump claude-bootstrap: unchanged upstream (${old:0:12})"; rm -f "$t"; return 0; fi
  echo "── bump claude-bootstrap: sha256 ${old:0:12} -> ${h:0:12} — the script changed; no old copy to diff against, READ THE NEW ONE:"
  sed 's/^/   /' "$t"; rm -f "$t"
  [ "$CHECK" = 1 ] && { echo "   (--check: not written)"; return 3; }
  _pin_set CLAUDE_BOOTSTRAP_SHA256 "$h" "$(date -u +%F) (bumped from ${old:0:8}; script read via \`pins.sh bump\`)" && return 3
}
_bump_rustup() {
  local old new a x
  old="$(_pin_get RUSTUP_VERSION)"
  new="$(curl --proto '=https' --tlsv1.2 -fsSL https://static.rust-lang.org/rustup/release-stable.toml 2>/dev/null | sed -n "s/^version = '\(.*\)'/\1/p")"
  [ -n "$new" ] || { echo "bump rustup: cannot read release-stable.toml" >&2; return 1; }
  if [ "$new" = "$old" ]; then echo "bump rustup: $old is current — nothing to do"; return 0; fi
  echo "── bump rustup: $old -> $new (a binary: no diff to read; hashes come from upstream's .sha256 files, same-host, recorded here)"
  a="$(curl -fsSL "https://static.rust-lang.org/rustup/archive/$new/aarch64-unknown-linux-gnu/rustup-init.sha256" | cut -d' ' -f1)"
  x="$(curl -fsSL "https://static.rust-lang.org/rustup/archive/$new/x86_64-unknown-linux-gnu/rustup-init.sha256" | cut -d' ' -f1)"
  { [ "${#a}" -eq 64 ] && [ "${#x}" -eq 64 ]; } || { echo "bump rustup: could not read both .sha256 files" >&2; return 1; }
  [ "$CHECK" = 1 ] && { echo "   (--check: not written)"; return 3; }
  _pin_set RUSTUP_VERSION "$new" "$(date -u +%F) (bumped from $old via \`pins.sh bump\`)" \
    && _pin_set RUSTUP_INIT_SHA256_aarch64 "$a" "from upstream .sha256, $new" \
    && _pin_set RUSTUP_INIT_SHA256_x86_64 "$x" "from upstream .sha256, $new" && return 3
}
bump() {
  CHECK=0; [ "${1:-}" = "--check" ] && { CHECK=1; shift; }
  local what="${1:-}" rc=0 news=0 r
  local zc="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  # Snapshot pins.sh so the outcome can be read off the FILE rather than guessed
  # from a worker's exit code.
  local pf snap=""; pf="$(_pins_file)"
  [ -n "$what" ] || { echo "usage: pins.sh bump [--check] omz|p10k|alacritty-theme|brew-installer|claude-bootstrap|rustup|all" >&2; return 2; }
  # `all` means all, alone: expanding it used to throw away any other names
  # before they were validated, so `bump all bogus` ran every worker and
  # exited 0 (round-4 review).
  if [ "$what" = all ]; then
    [ $# -eq 1 ] || { echo "bump: 'all' cannot be combined with other names" >&2; return 2; }
    set -- omz p10k alacritty-theme brew-installer claude-bootstrap rustup
  fi
  # Every name is checked BEFORE the snapshot and before any worker runs, so a
  # bad argument changes nothing and leaves nothing behind (round-3 review:
  # `bump bogus` leaked the snapshot, `bump brew-installer bogus` rewrote a pin
  # and then returned 2 without comparing, staging or cleaning up).
  local w
  for w in "$@"; do
    case "$w" in
      omz|p10k|alacritty-theme|brew-installer|claude-bootstrap|rustup) ;;
      *) echo "bump: unknown pin '$w'" >&2; return 2 ;;
    esac
  done
  # The snapshot is how the outcome is judged, so no snapshot means no bump:
  # stop BEFORE any worker can change the file (round-2 review — it used to
  # carry on with snap="", skip the check, and return 0 after a rewrite).
  if [ "$CHECK" = 0 ]; then
    snap="$(mktemp)" && cp -- "$pf" "$snap" \
      || { echo "bump: cannot make a safety copy of $pf — nothing changed" >&2; [ -n "$snap" ] && rm -f -- "$snap"; return 1; }
  fi
  for what in "$@"; do
    case "$what" in
      omz)              _bump_clone omz OMZ_SHA "$OMZ_URL" "$HOME/.oh-my-zsh" ;;
      p10k)             _bump_clone p10k P10K_SHA "$P10K_URL" "$zc/themes/powerlevel10k" ;;
      alacritty-theme)  _bump_clone alacritty-theme ALACRITTY_THEME_SHA "$ALACRITTY_THEME_URL" "$HOME/.config/alacritty/themes" ;;
      brew-installer)   _bump_brew ;;
      claude-bootstrap) _bump_claude ;;
      rustup)           _bump_rustup ;;
      *) rc=2 ;;   # unreachable — names were validated above; no early return past the snapshot
    esac; r=$?
    # 3 = news (rewritten, or found by --check). 0 = already at upstream.
    # Anything else is a failure, and says NOTHING about whether the file
    # changed: a worker returns 1 both for "cannot reach GitHub" (nothing
    # written) and for "pin rewritten but the checkout would not converge"
    # (written). The old code mapped 1 to changed=1 and so claimed a rewrite
    # that had not happened (external review, 2026-09-25, F2).
    case "$r" in 3) news=1 ;; 0) ;; *) rc=1 ;; esac
  done
  # Claim a rewrite only if pins.sh ACTUALLY DIFFERS. Read off the file, never
  # inferred from an exit status — that is the whole point of the fix.
  if [ "$CHECK" = 0 ] && [ -n "$snap" ] && ! cmp -s -- "$pf" "$snap"; then
    # Not silenced: a message that says "staged" when nothing was staged is
    # worse than no message.
    if git -C "$(dirname "$pf")" add -- "$pf"; then
      echo "── pins.sh rewritten and staged. Review the log/diff above, then commit: git commit -m 'pins: bump …'"
    else
      # The documented final step did not happen, so this is not a success —
      # automation used to see 0 here and carry on (F2).
      echo "── pins.sh rewritten but NOT staged (not a git checkout?) — stage $pf yourself, then commit." >&2
      rc=1
    fi
  fi
  [ -n "$snap" ] && rm -f -- "$snap"
  # --check: exit 1 when something is behind (cadence step 1), like versions-lock.sh check.
  [ "$CHECK" = 1 ] && [ "$news" = 1 ] && [ "$rc" = 0 ] && return 1
  return $rc
}

# Run as a command (steps invoke it inside `as_user`, where sourced functions
# are out of reach); a no-op when sourced.
case "${1:-}" in
  clone_pinned|fetch_pinned|bump) [ "${BASH_SOURCE[0]}" = "$0" ] && "$@" ;;
esac
