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

# Will cloud-init actually re-inject SSH keys on the clone? Require it INSTALLED
# and ENABLED and not explicitly disabled — "merely installed" isn't enough (a
# disabled / masked / no-datasource cloud-init never re-adds keys, so dropping
# authorized_keys would lock the image out). Unsure => return false => keep keys.
cloud_init_reinjects() {
  command -v cloud-init >/dev/null 2>&1 || return 1
  [ -e /etc/cloud/cloud-init.disabled ] && return 1
  systemctl is-enabled --quiet cloud-init.service 2>/dev/null \
    || systemctl is-enabled --quiet cloud-init.target 2>/dev/null
}

# Credential/token stores scrubbed from BOTH the target user and root — never
# needed in a shared image (reconfigure per-clone; cloud-init re-injects SSH).
# NOTE: .docker/config.json is KEPT but credential-SCRUBBED below — its
# currentContext pointer is useful (rootless), but any auths/credHelpers a stray
# `docker login` wrote are stripped so they can't bake into a shared image.
# .local/share/atuin: every shell command ever run (history.db) plus the sync
# key/session if sync was ever set up — history AND a credential. The LAST-phase
# wipe below only knows .bash_history/.zsh_history, so it goes here.
CRED_PATHS=(.aws .gnupg .config/gh .config/glab-cli .config/gcloud .kube .npmrc .netrc \
  .git-credentials .codex .local/share/atuin \
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
  would "scan $TARGET_HOME + /root for a leftover repo clone / *.log and WARN (never delete)"
  would "LAST: truncate /var/log/* + journal, rm shell history, clear /tmp & /var/tmp (incl. hidden)"
  would "verify (STRICT): machine-id empty, no host keys, no cred dirs / private keys remain — else die"
  exit 0
fi

# Through the apt_get WRAPPER, not bare apt-get: the wrapper is what makes apt
# non-interactive (DEBIAN_FRONTEND, NEEDRESTART_MODE=a, stdin detached). Bare,
# an autoremove that drops an old kernel — exactly what APT_UPGRADE=1 sets up —
# let needrestart draw its "restart services?" dialog into /dev/null and wait
# on the tty forever. Found live in the Gen-4 build (2026-09-13): finalize
# "hung". Gen-3 never removed a kernel, so it never asked.
apt_get autoremove -y >/dev/null 2>&1 || true
apt_get clean >/dev/null 2>&1 || true
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
  # SSH: always drop private keys + known_hosts.
  $SUDO rm -f "$home"/.ssh/id_* "$home"/.ssh/known_hosts 2>/dev/null || true
  # Catch CUSTOM-named private keys too (not just id_*): any ~/.ssh file whose
  # contents declare a private key. -I skips binaries; -maxdepth 1 stays shallow.
  [ -d "$home/.ssh" ] && $SUDO find "$home/.ssh" -maxdepth 1 -type f \
    -exec grep -qI 'PRIVATE KEY' {} \; -delete 2>/dev/null || true
  # authorized_keys: drop ONLY when cloud-init will actually re-inject keys on the
  # clone (see cloud_init_reinjects) — not merely when it's installed — so a local
  # / disabled-cloud-init image isn't locked out. When kept, SAY SO loudly: it is
  # a deliberate lockout-safety trade-off against a fully key-free image.
  if cloud_init_reinjects; then
    $SUDO rm -f "$home"/.ssh/authorized_keys 2>/dev/null || true
  elif $SUDO test -f "$home/.ssh/authorized_keys" 2>/dev/null; then
    warn "KEEPING $home/.ssh/authorized_keys (cloud-init won't re-inject keys — removing it would lock the image out); rm it manually if this image must be key-free"
  fi
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
    [ "$home" = "$TARGET_HOME" ] && $SUDO chown "$TARGET_USER":"$TARGET_GROUP" "$dc" 2>/dev/null || true
  else
    $SUDO rm -f "$dc" "$dc.tmp" 2>/dev/null || true
  fi
done

# machine-id stays an EMPTY file (systemd regenerates a unique id per clone;
# deleting it can break boot). dbus id removed. SSH host keys regenerated on boot.
$SUDO truncate -s 0 /etc/machine-id 2>/dev/null || true
$SUDO rm -f /var/lib/dbus/machine-id 2>/dev/null || true
$SUDO rm -f /etc/ssh/ssh_host_* 2>/dev/null || true
# Who puts them back? cloud-init's ssh module, on a clone where it RUNS. On a
# desktop install cloud-init is disabled, so an image that also carries sshd
# would boot clones whose sshd has no keys and fails to start. Say so — the
# desktop golden today has no openssh-server (not in apt.list), so this is a
# warning about a combination, not a state. Fix if it ever applies: a oneshot
# unit running `ssh-keygen -A` before ssh.service, or keep cloud-init enabled.
if dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q 'install ok installed' \
   && ! cloud_init_reinjects; then
  warn "openssh-server is installed but cloud-init will NOT run on the clone — SSH host keys will not regenerate and sshd will fail to start; add a first-boot 'ssh-keygen -A' unit or keep cloud-init enabled"
fi

# cloud-init re-runs on the clone with fresh instance metadata.
command -v cloud-init >/dev/null 2>&1 && { $SUDO cloud-init clean --logs --seed >/dev/null 2>&1 || true; }
$SUDO rm -rf /var/lib/cloud/* 2>/dev/null || true

# Step 80's notes/MOTD and step 85's ~/versions.lock survive by construction:
# neither path is a cred path, and finalize never sweeps $HOME wholesale.
# Heads-up (operator-facing, NON-destructive): finalize does NOT touch $HOME, so a
# repo clone or run-log left there bakes into the image. We never delete user files
# blindly — just flag them so you can rm before capture. (Cloning + logging under
# /tmp avoids this entirely: the tmp-wipe below removes those for free.) Hidden
# repos are skipped — ~/.oh-my-zsh etc. are intentional git checkouts, not cruft.
for home in "$TARGET_HOME" /root; do
  [ -n "$home" ] && [ -d "$home" ] || continue
  leftovers=()
  while IFS= read -r g; do
    repo="${g%/.git}"; case "${repo##*/}" in .*) continue ;; esac
    leftovers+=("$repo")
  done < <($SUDO find "$home" -mindepth 2 -maxdepth 2 -name .git -type d 2>/dev/null)
  while IFS= read -r f; do leftovers+=("$f"); done \
    < <($SUDO find "$home" -mindepth 1 -maxdepth 1 -type f -name '*.log' 2>/dev/null)
  [ "${#leftovers[@]}" -gt 0 ] \
    && warn "leftover under $home will bake into the image — rm before capture: ${leftovers[*]}"
done

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
    # Verify EVERY path the scrub above claims to remove — same array, so the
    # scrub list and the verifier can't drift apart.
    for p in "${CRED_PATHS[@]}"; do
      [ -e "$home/$p" ] && probs+=("$home/$p remains")
    done
    if [ -d "$home/.ssh" ] && { ls "$home"/.ssh/id_* >/dev/null 2>&1 \
         || $SUDO find "$home/.ssh" -maxdepth 1 -type f -exec grep -qI 'PRIVATE KEY' {} \; -print 2>/dev/null | grep -q .; }; then
      probs+=("$home/.ssh still has a private key")
    fi
  done
  [ "${#probs[@]}" -eq 0 ] || die "finalize verification FAILED — image not clean: ${probs[*]}"
fi
