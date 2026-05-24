#!/usr/bin/env bash
# Step 90 — golden-image finalize (ONLY with GOLDEN_IMAGE=1). Strips
# machine-specific identity + build cruft so the captured image boots as many
# UNIQUE clones. DESTRUCTIVE by design; gated hard on the flag and runs last
# (in GOLDEN_IMAGE/strict mode an earlier failure aborts before we get here, so
# we never finalize a broken image).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

[ "${GOLDEN_IMAGE:-0}" = "1" ] || { log "finalize: skipped (GOLDEN_IMAGE != 1)"; exit 0; }

log "GOLDEN IMAGE finalize — stripping identity, caches, logs, history"

if dry; then
  would "apt-get clean; rm -rf /var/lib/apt/lists/*"
  would "truncate /etc/machine-id to empty (regenerated per clone); rm /var/lib/dbus/machine-id"
  would "rm /etc/ssh/ssh_host_* (unique host keys regenerated on first boot)"
  would "cloud-init clean --logs --seed; rm -rf /var/lib/cloud/* (re-runs on clone)"
  would "truncate /var/log/* ; clear systemd journal"
  would "rm root + $TARGET_USER bash/zsh history; clear /tmp and /var/tmp"
else
  $SUDO apt-get clean 2>/dev/null || true
  $SUDO rm -rf /var/lib/apt/lists/* 2>/dev/null || true

  # machine-id MUST stay an EMPTY file so systemd regenerates a unique id per
  # clone on first boot (deleting the file can break boot). dbus id is removed.
  $SUDO truncate -s 0 /etc/machine-id 2>/dev/null || true
  $SUDO rm -f /var/lib/dbus/machine-id 2>/dev/null || true

  # SSH host keys — unique per clone, regenerated on first boot.
  $SUDO rm -f /etc/ssh/ssh_host_* 2>/dev/null || true

  # cloud-init re-runs on the clone with fresh instance metadata.
  command -v cloud-init >/dev/null 2>&1 && { $SUDO cloud-init clean --logs --seed >/dev/null 2>&1 || true; }
  $SUDO rm -rf /var/lib/cloud/* 2>/dev/null || true

  # Logs + systemd journal.
  $SUDO find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
  $SUDO rm -rf /var/log/journal/* 2>/dev/null || true

  # Shell history (root + target user).
  for h in /root/.bash_history /root/.zsh_history \
           "$TARGET_HOME/.bash_history" "$TARGET_HOME/.zsh_history"; do
    $SUDO rm -f "$h" 2>/dev/null || true
  done

  # Temp dirs.
  $SUDO rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
fi

log "Finalize complete — power off and capture/snapshot the image."
log "Clones regenerate machine-id, SSH host keys, and cloud-init state on first boot."
