#!/usr/bin/env bash
# Step 40 — snaps.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

command -v snap >/dev/null 2>&1 || { warn "snapd not present; skipping snaps"; exit 0; }

# On cloud-init first boot snapd may not be seeded yet; wait briefly so installs
# don't fail with "too early for operation, device not yet seeded".
if ! dry; then $SUDO snap wait system seed.loaded 2>/dev/null || true; fi

log "Installing snaps"
while read -r name flags || [ -n "${name:-}" ]; do
  case "${name:-}" in ""|\#*) continue ;; esac
  if dry; then would "snap install $name ${flags:-}"; continue; fi
  # Try as listed, then strict, then classic — whichever the snap requires.
  $SUDO snap install "$name" $flags 2>/dev/null \
    || $SUDO snap install "$name" 2>/dev/null \
    || $SUDO snap install "$name" --classic 2>/dev/null \
    || warn "snap: failed to install '$name'"
done < "$PKG_DIR/snap.list"
