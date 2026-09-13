#!/usr/bin/env bash
# Step 85 — record what this run landed: ~/versions.lock, written as the target
# user by provision/versions-lock.sh (every source it reads — brew, rustup,
# claude, mise, the git clones — is per-user). Runs after step 80 and before
# finalize; finalize leaves $HOME alone, so every GOLDEN carries its own lock and
# every clone boots with it: "what this image contains", on the box.
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

log "versions.lock: recording what landed -> $LOCK_FILE"

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

# rm FIRST (rm doesn't follow symlinks): same multi-user hardening as step 80 —
# a pre-placed symlink at this path must not redirect the write.
$SUDO rm -f "$LOCK_FILE"
as_user "PROVISION_FLAGS='$FLAGS' bash '$TOOL' emit -o '$LOCK_FILE'" \
  || soft_fail "could not write $LOCK_FILE"
