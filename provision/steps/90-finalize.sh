#!/usr/bin/env bash
# Step 90 — golden-image finalize (ONLY with GOLDEN_IMAGE=1). Strips
# machine-specific identity, credentials, caches, logs, and history so the
# captured image boots as many UNIQUE, credential-free clones. DESTRUCTIVE by
# design; gated hard on the flag; runs last (strict mode aborts earlier on any
# failure, so we never finalize a broken image).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

[ "${GOLDEN_IMAGE:-0}" = "1" ] || { log "finalize: skipped (GOLDEN_IMAGE != 1)"; exit 0; }

log "GOLDEN IMAGE finalize — stripping identity, credentials, caches, logs, history"

# Credential/token stores scrubbed from BOTH the target user and root — never
# needed in a shared image (reconfigure per-clone; cloud-init re-injects SSH).
# NOTE: .docker/config.json is intentionally kept (rootless context; auths are
# empty on a pristine build box — don't `docker login` on the builder).
CRED_PATHS=(.aws .gnupg .config/gh .config/gcloud .kube .npmrc .codex \
  .claude/.credentials.json .claude/projects .claude/sessions \
  .claude/history.jsonl .claude/shell-snapshots)

if dry; then
  would "apt-get autoremove + clean; rm -rf /var/lib/apt/lists/*"
  would "rm -rf ~/.cargo/registry/{cache,src} for $TARGET_USER + root (re-downloadable crate cache)"
  would "scrub creds from $TARGET_USER + root: ${CRED_PATHS[*]}"
  would "rm SSH private keys + known_hosts (+ authorized_keys if cloud-init re-injects)"
  would "truncate /etc/machine-id; rm /var/lib/dbus/machine-id; rm /etc/ssh/ssh_host_*"
  would "cloud-init clean --logs --seed; rm -rf /var/lib/cloud/*"
  would "LAST: truncate /var/log/* + journal, rm shell history, clear /tmp & /var/tmp (incl. hidden)"
  exit 0
fi

$SUDO apt-get autoremove -y >/dev/null 2>&1 || true
$SUDO apt-get clean 2>/dev/null || true
$SUDO rm -rf /var/lib/apt/lists/* 2>/dev/null || true

# Cargo download cache (~/.cargo/registry/{cache,src}) — re-downloadable crate
# tarballs + extracted sources left by `cargo install` in step 36. Drop them from
# the image; the toolchain (~/.rustup, ~/.cargo/bin) stays. Keep registry/index
# so a later `cargo install` doesn't re-fetch the whole index.
for home in "$TARGET_HOME" /root; do
  [ -n "$home" ] || continue
  $SUDO rm -rf "$home/.cargo/registry/cache" "$home/.cargo/registry/src" 2>/dev/null || true
done

# Scrub credential stores from the target user AND root.
for home in "$TARGET_HOME" /root; do
  [ -n "$home" ] || continue
  for p in "${CRED_PATHS[@]}"; do $SUDO rm -rf "$home/$p" 2>/dev/null || true; done
  # SSH: always drop private keys + known_hosts. Drop authorized_keys too only if
  # cloud-init is present (it re-injects from instance metadata on first boot);
  # otherwise keep it so a non-cloud image isn't locked out.
  $SUDO rm -f "$home"/.ssh/id_* "$home"/.ssh/known_hosts 2>/dev/null || true
  command -v cloud-init >/dev/null 2>&1 && $SUDO rm -f "$home"/.ssh/authorized_keys 2>/dev/null || true
done

# machine-id stays an EMPTY file (systemd regenerates a unique id per clone;
# deleting it can break boot). dbus id removed. SSH host keys regenerated on boot.
$SUDO truncate -s 0 /etc/machine-id 2>/dev/null || true
$SUDO rm -f /var/lib/dbus/machine-id 2>/dev/null || true
$SUDO rm -f /etc/ssh/ssh_host_* 2>/dev/null || true

# cloud-init re-runs on the clone with fresh instance metadata.
command -v cloud-init >/dev/null 2>&1 && { $SUDO cloud-init clean --logs --seed >/dev/null 2>&1 || true; }
$SUDO rm -rf /var/lib/cloud/* 2>/dev/null || true

log "Finalize done — wiping logs/history/tmp last, then power off and capture the image."

# LAST disk actions: logs, journal, shell history, temp (incl. hidden files).
# Nothing logs after this. (See the runbook: don't tee a golden build to
# /var/log — provision.sh's own end-of-run summary would re-create a log there.)
$SUDO find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
$SUDO rm -rf /var/log/journal/* 2>/dev/null || true
for home in /root "$TARGET_HOME"; do
  [ -n "$home" ] && $SUDO rm -f "$home/.bash_history" "$home/.zsh_history" 2>/dev/null || true
done
$SUDO find /tmp /var/tmp -mindepth 1 -delete 2>/dev/null || true
