#!/usr/bin/env bash
# Step 85 — record installed versions: ~/versions.lock, written as the target
# user by provision/versions-lock.sh (every source it reads — brew, rustup,
# claude, mise, the git clones — is per-user). Runs after step 80 and before
# finalize; finalize leaves $HOME alone, so every GOLDEN carries its own lock and
# every clone boots with its own lock. What it covers: provision/README.md#versions--recorded-not-pinned.
#
# Before overwriting, an existing lock from the previous run is compared and the
# drift is logged — so a bring-to-latest re-run SAYS what moved (TODO J's
# "observed act"). Nothing here installs or pins; the record is the product.
set -uo pipefail
# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

LOCK_FILE="$TARGET_HOME/versions.lock"
TOOL="$PROVISION_DIR/versions-lock.sh"
# What this run was asked for — recorded in the lock's header, so a lock read
# months later still says which recipe produced it.
# DOTFILES_COPY is recorded as its EFFECTIVE value: GOLDEN_IMAGE implies it.
COPY_EFF="${DOTFILES_COPY:-0}"; [ "${GOLDEN_IMAGE:-0}" = 1 ] && COPY_EFF=1
FLAGS="PROFILE=$PROFILE HEADLESS=${HEADLESS:-0} INSTALL_DESKTOP=${INSTALL_DESKTOP:-0} \
GOLDEN_IMAGE=${GOLDEN_IMAGE:-0} DOTFILES_COPY=$COPY_EFF \
DOCKER_ROOTLESS=${DOCKER_ROOTLESS:-0} APT_UPGRADE=${APT_UPGRADE:-0}"

log "versions.lock: recording installed versions -> $LOCK_FILE"

if dry; then
  would "(as $TARGET_USER) if $LOCK_FILE exists: versions-lock.sh check it and log the drift since the previous run"
  would "(as $TARGET_USER) versions-lock.sh emit -o $LOCK_FILE   [flags: $FLAGS]"
  exit 0
fi

[ -x "$TOOL" ] || [ -r "$TOOL" ] || { soft_fail "missing $TOOL — versions.lock NOT written"; exit 0; }

# Drift since the previous run, if there was one. Informational: exit 1 from
# `check` means "something moved", which is the expected outcome of a
# bring-to-latest re-run, not a failure.
if [ -s "$LOCK_FILE" ]; then
  log "versions.lock: changes since the previous run"
  as_user "bash '$TOOL' check '$LOCK_FILE'" || true
fi

# Resolve the repo SHA HERE, as root, and hand it down: the emitter runs as the
# target user, and git refuses to parse a repo owned by another user
# (safe.directory). Under cloud-init the repo is root-owned in /opt, so the
# user's own probe finds nothing and the lock loses the one field that says
# which commit produced it (found live, TODO K). Root owns it there; on a
# normal box git's SUDO_UID special case covers the user-owned repo. If neither
# resolves, the emitter records `repo: unknown` rather than dropping the field.
#
# FAIL-CLOSED (external review, 2026-09-25): `unknown` and `(dirty)` were only
# ever annotations. check strips the header and verify asserts the lock is
# non-empty, so NO consumer looked at either — a golden could reach capture with
# no machine-checked provenance at all while the repo claims "this commit
# produced this image". Both now soft_fail, which a tolerant run records and
# STRICT/GOLDEN turns into an abort.
#
# Full 40 hex, not --short=7: a shallow cloud-init clone cannot know whether an
# abbreviation is unique in the full history, and this field's whole job is to
# identify a commit unambiguously. It is a header, never a compared row, so
# widening it causes no drift.
REPO_SHA="$(git -C "$DOTFILES_ROOT" rev-parse HEAD 2>/dev/null || true)"
if [ -z "$REPO_SHA" ]; then
  soft_fail "cannot resolve the repo commit at $DOTFILES_ROOT — the lock would record 'repo: unknown', so this image could not be traced to a commit"
elif ! repo_is_clean "$DOTFILES_ROOT"; then   # edits, untracked (golden: also ignored) files, or a failing git status
  REPO_SHA="$REPO_SHA (dirty)"
  soft_fail "the repo at $DOTFILES_ROOT has uncommitted changes — '$(printf %.7s "$REPO_SHA") (dirty)' names a tree nobody else can reproduce"
fi
# As the user, and no `rm` first: emit writes a temp file and renames it, which
# replaces a planted symlink instead of following it, and a FAILED emit now
# leaves the last good lock in place rather than none (round-3 review).
as_user "PROVISION_REPO_SHA='$REPO_SHA' PROVISION_FLAGS='$FLAGS' bash '$TOOL' emit -o '$LOCK_FILE'" \
  || soft_fail "could not write $LOCK_FILE"
