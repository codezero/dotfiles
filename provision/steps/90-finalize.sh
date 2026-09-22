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

# Every account the image could carry, not just the target user: uid >= 1000
# with a home under /home (a forgotten root-made account included), plus root.
# Decided 2026-09-22 (external assessment): a golden is credential-free for
# EVERY home or it is not credential-free. Each home is scrubbed AS ITS OWNER
# (as_owner) — root never walks a path a user controls, so a planted symlink
# cannot turn the scrub into a write elsewhere (same rule as steps 60/38/80).
mapfile -t ACCOUNTS < <(getent passwd | awk -F: '$3>=1000 && $3<65534 && $6 ~ "^/home/" {print $1":"$6}')
ACCOUNTS+=("root:/root")
as_owner() {  # <user> <bash -c string> — run in that account's context
  local u="$1"; shift
  if [ "$u" = root ]; then bash -c "$*"; else sudo -u "$u" -H bash -c "$*"; fi
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
  would "scrub EVERY account (uid >= 1000 with a /home dir, plus root), each as its own owner: ${ACCOUNTS[*]%%:*}"
  would "rm -rf ~/.cargo/registry/{cache,src} (re-downloadable crate cache)"
  would "scrub creds: ${CRED_PATHS[*]}"
  would "scrub auths/credHelpers from ~/.docker/config.json (keep currentContext; rm file if unscrubbable)"
  would "rm ALL private keys in ~/.ssh (id_* + any file containing 'PRIVATE KEY') + known_hosts + authorized_keys (always — a cloud clone gets keys from cloud-init, a local clone logs in at the console)"
  would "rm the <dotfile>.backup.<ts> files step 60 / install.sh left for every dotfiles.list entry"
  would "truncate /etc/machine-id; rm /var/lib/dbus/machine-id; rm /etc/ssh/ssh_host_*"
  would "cloud-init clean --logs --seed; rm -rf /var/lib/cloud/*"
  would "scan $TARGET_HOME + /root for a leftover repo clone / *.log and WARN (never delete)"
  would "LAST: truncate /var/log/* + journal, rm shell history, clear /tmp & /var/tmp (incl. hidden)"
  would "verify (STRICT, every account): machine-id empty, no host keys, no cred paths, no private key ANYWHERE under /home or /root, no authorized_keys, no dotfile backups, no docker auths — else die"
  [ "${GOLDEN_POWEROFF:-0}" = 1 ] && would "power off as the last action (GOLDEN_POWEROFF=1) — nothing typed on the box after the scrub"
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

# Per-account scrub, each as its owner. Cargo's download cache
# (~/.cargo/registry/{cache,src}) is re-downloadable — the toolchain
# (~/.rustup, ~/.cargo/bin) and registry/index stay. Credential stores per
# CRED_PATHS. SSH: every private key (id_* and any file whose contents declare
# one), known_hosts, and authorized_keys — ALWAYS. Before 2026-09-22 keys were
# kept when cloud-init would not re-inject them (a lockout-safety trade-off,
# with a warning); the user decided a golden keeps no access material at all:
# a cloud clone gets keys from cloud-init, a local clone is logged into at the
# console first. The <dotfile>.backup.<ts> files step 60 / install.sh make are
# removed too — a golden built by re-running on a clone kept the previous
# dotfiles around (assessment finding). Docker: strip registry creds a stray
# `docker login` wrote but KEEP the rest (currentContext for rootless); if it
# can't be scrubbed cleanly the file goes — never bake auths into an image.
mapfile -t DOTFILE_ENTRIES < <(grep -vE '^[[:space:]]*(#|$)' "$DOTFILES_ROOT/dotfiles.list")
log "finalize: scrubbing ${#ACCOUNTS[@]} accounts (${ACCOUNTS[*]%%:*})"
for acct in "${ACCOUNTS[@]}"; do
  owner="${acct%%:*}"; home="${acct#*:}"
  [ -d "$home" ] || continue
  as_owner "$owner" 'rm -rf "$HOME/.cargo/registry/cache" "$HOME/.cargo/registry/src" 2>/dev/null; true'
  for p in "${CRED_PATHS[@]}"; do as_owner "$owner" "rm -rf \"\$HOME/$p\" 2>/dev/null; true"; done
  as_owner "$owner" 'rm -f "$HOME"/.ssh/id_* "$HOME"/.ssh/known_hosts "$HOME"/.ssh/authorized_keys 2>/dev/null
    [ -d "$HOME/.ssh" ] && find "$HOME/.ssh" -maxdepth 1 -type f -exec grep -qI "PRIVATE KEY" {} \; -delete 2>/dev/null; true'
  for e in "${DOTFILE_ENTRIES[@]}"; do
    case "$e" in ""|/*|*..*) continue ;; esac
    as_owner "$owner" "rm -rf \"\$HOME/$e\".backup.* 2>/dev/null; true"
  done
  as_owner "$owner" 'dc="$HOME/.docker/config.json"; [ -f "$dc" ] || exit 0
    jq=$(command -v jq || ls /home/linuxbrew/.linuxbrew/bin/jq 2>/dev/null)
    if [ -n "$jq" ] && "$jq" "del(.auths,.credsStore,.credHelpers,.HttpHeaders)" "$dc" > "$dc.tmp" 2>/dev/null; then mv "$dc.tmp" "$dc"
    else rm -f "$dc" "$dc.tmp"; fi; true'
done
log "finalize: authorized_keys removed for every account — a cloud clone gets keys from cloud-init, a local clone logs in at the console first"

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
   && ! { command -v cloud-init >/dev/null 2>&1 && [ ! -e /etc/cloud/cloud-init.disabled ] \
          && { systemctl is-enabled --quiet cloud-init.service 2>/dev/null || systemctl is-enabled --quiet cloud-init.target 2>/dev/null; }; }; then
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
for acct in "${ACCOUNTS[@]}"; do
  home="${acct#*:}"
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
for acct in "${ACCOUNTS[@]}"; do
  as_owner "${acct%%:*}" 'rm -f "$HOME/.bash_history" "$HOME/.zsh_history" 2>/dev/null; true'
done
$SUDO find /tmp /var/tmp -mindepth 1 -delete 2>/dev/null || true

# Verify the image is actually clean. All the cleanup above is best-effort
# (|| true) so one failure can't wedge the wipe — but under STRICT/golden a
# residue is unacceptable, so FAIL HARD here rather than capture a dirty image.
if strict; then
  probs=()
  [ -s /etc/machine-id ] && probs+=("/etc/machine-id not empty")
  ls /etc/ssh/ssh_host_* >/dev/null 2>&1 && probs+=("/etc/ssh host keys present")
  for acct in "${ACCOUNTS[@]}"; do
    home="${acct#*:}"; [ -d "$home" ] || continue
    # Verify EVERY path the scrub above claims to remove — same array, so the
    # scrub list and the verifier can't drift apart. Reads only (root may read
    # a user home; it never writes into one).
    for p in "${CRED_PATHS[@]}"; do
      [ -e "$home/$p" ] && probs+=("$home/$p remains")
    done
    if [ -d "$home/.ssh" ] && { ls "$home"/.ssh/id_* >/dev/null 2>&1 \
         || find "$home/.ssh" -maxdepth 1 -type f -exec grep -qI 'PRIVATE KEY' {} \; -print 2>/dev/null | grep -q .; }; then
      probs+=("$home/.ssh still has a private key")
    fi
    [ -s "$home/.ssh/authorized_keys" ] && probs+=("$home/.ssh/authorized_keys still holds keys")
    for e in "${DOTFILE_ENTRIES[@]}"; do
      case "$e" in ""|/*|*..*) continue ;; esac
      ls -d "$home/$e".backup.* >/dev/null 2>&1 && probs+=("$home/$e.backup.* remains")
    done
    [ -f "$home/.docker/config.json" ] && grep -qE '"(auths|credsStore|credHelpers)"' "$home/.docker/config.json" \
      && probs+=("$home/.docker/config.json still has registry auth")
  done
  # Whole-image sweep, independent of the lists above: any regular file under
  # /home or /root that contains a private key is a failure, whoever owns it
  # and whatever it is called. grep -r does not follow symlinks.
  stray="$(grep -rIl --exclude-dir=.git 'PRIVATE KEY' /home /root 2>/dev/null | head -5)"
  [ -n "$stray" ] && probs+=("private key material under: $(tr '\n' ' ' <<<"$stray")")
  [ "${#probs[@]}" -eq 0 ] || die "finalize verification FAILED — image not clean: ${probs[*]}"
fi

# GOLDEN_POWEROFF=1: power off as finalize's OWN last action, so nothing is
# typed on the build box after the scrub. Anything typed in an interactive zsh
# after this point is recorded by atuin at pre-exec — the `sudo poweroff`
# itself included — which recreates ~/.local/share/atuin AFTER finalize wiped
# it and bakes the build session's commands into the image (Gen-4, 2026-09-13:
# the first-boot audit flagged it). `unset HISTFILE` only ever covered zsh's
# own history. Opt-in, because an operator may want to inspect before capture;
# the runbook recommends it.
# --check-inhibitors=no: a GNOME desktop session holds a logind block
# inhibitor, and a plain `systemctl poweroff` refuses ("Operation denied due
# to active block inhibitor") — the first GOLDEN_POWEROFF build hit exactly
# that, after a clean scrub (2026-09-13). Root may override it; -i is the
# older spelling, kept as a fallback for a systemd without the long option.
if [ "${GOLDEN_POWEROFF:-0}" = 1 ]; then
  log "GOLDEN_POWEROFF=1 — powering off now; capture the image once the VM is stopped."
  sync
  $SUDO systemctl poweroff --check-inhibitors=no 2>/dev/null \
    || $SUDO systemctl poweroff -i 2>/dev/null \
    || die "GOLDEN_POWEROFF: systemctl poweroff refused — power off from the GUI or the hypervisor WITHOUT typing in a shell (atuin/zsh would record it)"
fi
