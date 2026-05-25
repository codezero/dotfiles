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
# NOTE: .docker/config.json is KEPT but credential-SCRUBBED below — its
# currentContext pointer is useful (rootless), but any auths/credHelpers a stray
# `docker login` wrote are stripped so they can't bake into a shared image.
CRED_PATHS=(.aws .gnupg .config/gh .config/gcloud .kube .npmrc .codex \
  .claude/.credentials.json .claude/projects .claude/sessions \
  .claude/history.jsonl .claude/shell-snapshots)

if dry; then
  would "apt-get autoremove + clean; rm -rf /var/lib/apt/lists/*"
  would "rm -rf ~/.cargo/registry/{cache,src} for $TARGET_USER + root (re-downloadable crate cache)"
  would "scrub creds from $TARGET_USER + root: ${CRED_PATHS[*]}"
  would "scrub auths/credHelpers from ~/.docker/config.json (keep currentContext; rm file if unscrubbable)"
  would "rm ALL private keys in ~/.ssh (id_* + any file containing 'PRIVATE KEY') + known_hosts (+ authorized_keys if cloud-init re-injects)"
  would "truncate /etc/machine-id; rm /var/lib/dbus/machine-id; rm /etc/ssh/ssh_host_*"
  would "cloud-init clean --logs --seed; rm -rf /var/lib/cloud/*"
  would "LAST: truncate /var/log/* + journal, rm shell history, clear /tmp & /var/tmp (incl. hidden)"
  would "verify (STRICT): machine-id empty, no host keys, no cred dirs / private keys remain — else die"
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
  # Catch CUSTOM-named private keys too (not just id_*): any ~/.ssh file whose
  # contents declare a private key. -I skips binaries; -maxdepth 1 stays shallow.
  [ -d "$home/.ssh" ] && $SUDO find "$home/.ssh" -maxdepth 1 -type f \
    -exec grep -qI 'PRIVATE KEY' {} \; -delete 2>/dev/null || true
  command -v cloud-init >/dev/null 2>&1 && $SUDO rm -f "$home"/.ssh/authorized_keys 2>/dev/null || true
done

# Docker: strip registry creds a stray `docker login` may have written, but KEEP
# the rest (e.g. currentContext for rootless). If we can't scrub it cleanly, drop
# the file outright — never bake auths into a shared image.
for home in "$TARGET_HOME" /root; do
  [ -n "$home" ] || continue
  dc="$home/.docker/config.json"
  [ -f "$dc" ] || continue
  if command -v jq >/dev/null 2>&1 \
     && $SUDO sh -c 'jq "del(.auths,.credsStore,.credHelpers,.HttpHeaders)" "$1" >"$1.tmp"' _ "$dc" 2>/dev/null; then
    $SUDO mv "$dc.tmp" "$dc"
    [ "$home" = "$TARGET_HOME" ] && $SUDO chown "$TARGET_USER":"$TARGET_USER" "$dc" 2>/dev/null || true
  else
    $SUDO rm -f "$dc" "$dc.tmp" 2>/dev/null || true
  fi
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

# Verify the image is actually clean. All the cleanup above is best-effort
# (|| true) so one failure can't wedge the wipe — but under STRICT/golden a
# residue is unacceptable, so FAIL HARD here rather than capture a dirty image.
if strict; then
  probs=()
  [ -s /etc/machine-id ] && probs+=("/etc/machine-id not empty")
  ls /etc/ssh/ssh_host_* >/dev/null 2>&1 && probs+=("/etc/ssh host keys present")
  for home in "$TARGET_HOME" /root; do
    [ -n "$home" ] || continue
    for p in .aws .gnupg .kube .config/gh .config/gcloud .npmrc; do
      [ -e "$home/$p" ] && probs+=("$home/$p remains")
    done
    ls "$home"/.ssh/id_* >/dev/null 2>&1 && probs+=("$home/.ssh private keys remain")
  done
  [ "${#probs[@]}" -eq 0 ] || die "finalize verification FAILED — image not clean: ${probs[*]}"
fi
