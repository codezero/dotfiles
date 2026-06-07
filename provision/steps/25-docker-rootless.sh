#!/usr/bin/env bash
# Step 25 — rootless Docker for the target user (ONLY with DOCKER_ROOTLESS=1).
# Runs the official setuptool AS THE USER so dockerd runs unprivileged (no
# 'docker' group, which is root-equivalent). Requires docker-ce-rootless-extras
# + uidmap + dbus-user-session (step 20) and unprivileged user namespaces — it
# will NOT work on hosts that restrict nested userns (same limit as the source
# VM / this sandbox); there it soft-fails and the rootful daemon still works.
#
# This generates the systemd --user unit natively (better than porting a
# hardcoded one) and enables linger so the daemon survives logout — needed for
# headless / cloud-init / golden images.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

[ "${DOCKER_ROOTLESS:-0}" = "1" ] || { log "rootless Docker: skipped (DOCKER_ROOTLESS != 1)"; exit 0; }
command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1 \
  || { soft_fail "rootless requested but dockerd-rootless-setuptool.sh missing (docker-ce-rootless-extras not installed)"; exit 0; }

uid="$(id -u "$TARGET_USER" 2>/dev/null || true)"
[ -n "$uid" ] || { soft_fail "rootless requested but can't resolve uid for '$TARGET_USER'"; exit 0; }

log "Rootless Docker for '$TARGET_USER' (uid $uid)"

if dry; then
  would "preflight: require kernel.apparmor_restrict_unprivileged_userns != 1 (rootlesskit needs caps inside the userns)"
  would "loginctl enable-linger $TARGET_USER"
  would "(as $TARGET_USER) dockerd-rootless-setuptool.sh install --force"
  would "(as $TARGET_USER) systemctl --user enable --now docker"
  would "(as $TARGET_USER) docker context use rootless (unix:///run/user/$uid/docker.sock)"
  exit 0
fi

# Pre-flight: fail fast (and precisely) when AppArmor restricts unprivileged
# user namespaces — otherwise the same failure surfaces minutes later inside the
# setuptool with a vaguer message (and under STRICT/golden, that's where the
# build would abort). We read the sysctl DIRECTLY rather than probing with
# `unshare --user --map-root-user true`: that probe false-OKs on 24.04+ —
# Ubuntu grants the `unshare` binary its own userns-allowing AppArmor profile,
# and the restriction doesn't deny userns *creation* anyway (it transitions the
# process to an `unprivileged_userns` profile that strips capabilities INSIDE
# the ns, which is what kills rootlesskit's mounts). The sysctl is the exact
# knob the documented remedy flips. Relaxing it is a deliberate host-wide
# trade-off left to the user (see ~/PROVISION-NEXT-STEPS.md) — and on a GOLDEN
# build box the sysctl.d drop-in would bake into the image (every clone
# inherits it), so a golden stays rootless-free by default and clones opt in.
# Missing file (non-Ubuntu kernel / pre-23.10) => no restriction => proceed;
# a rare hand-crafted rootlesskit profile would false-block here — acceptable,
# the message says how to proceed.
if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ]; then
  soft_fail "rootless preflight: kernel.apparmor_restrict_unprivileged_userns=1 (Ubuntu 24.04+ default) — rootlesskit would get a capability-stripped userns; skipping rootless setup. See ~/PROVISION-NEXT-STEPS.md, then re-run with DOCKER_ROOTLESS=1"
  exit 0
fi

# Linger so the user's systemd instance (hence rootless dockerd) runs with no
# active login — essential headless.
$SUDO loginctl enable-linger "$TARGET_USER" || soft_fail "enable-linger failed (rootless daemon won't survive logout)"

# Wait for the lingering user manager's session bus to appear.
RB="/run/user/$uid/bus"
for _ in {1..10}; do [ -S "$RB" ] && break; sleep 1; done
[ -S "$RB" ] || warn "user session bus $RB not up yet — systemctl --user may fail"

# Install + enable the rootless daemon as the user, against that session bus.
setup_ok=1
as_user "export XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=$RB PATH=/usr/bin:\$PATH; \
  dockerd-rootless-setuptool.sh install --force && systemctl --user enable --now docker" \
  || { setup_ok=0; soft_fail "rootless Docker setup failed — unprivileged userns likely AppArmor-restricted (Ubuntu 24.04+ default); see ~/PROVISION-NEXT-STEPS.md to allow it persistently, then re-run with DOCKER_ROOTLESS=1"; }

# Only repoint the CLI + validate when the setup actually succeeded. On failure
# we must NOT `docker context use rootless` — that would aim the user's CLI at a
# socket that doesn't exist, breaking even rootful use ("soft-fails and the
# rootful daemon still works" is the contract). Tolerant runs reach this point
# after the soft_fail above; STRICT/golden already died there.
if [ "$setup_ok" = 1 ]; then
  # Point the user's docker CLI at the rootless socket by default.
  as_user "export XDG_RUNTIME_DIR=/run/user/$uid; \
    docker context create rootless --docker host=unix:///run/user/$uid/docker.sock >/dev/null 2>&1 || true; \
    docker context use rootless >/dev/null 2>&1 || true"

  # Validate the requested rootless daemon actually came up — don't silently
  # underdeliver (under GOLDEN_IMAGE/STRICT this soft_fail aborts the build).
  as_user "export XDG_RUNTIME_DIR=/run/user/$uid; systemctl --user is-active --quiet docker" \
    || soft_fail "rootless Docker service not active after setup (unprivileged userns restricted?)"

  # Validate the CLI default context is actually 'rootless' (the `context use`
  # above is best-effort) — otherwise `docker` would silently talk to the rootful
  # daemon and the rootless setup would be a no-op from the user's POV.
  as_user "export XDG_RUNTIME_DIR=/run/user/$uid; [ \"\$(docker context show 2>/dev/null)\" = rootless ]" \
    || soft_fail "docker context is not 'rootless' after setup (CLI would default to the rootful daemon)"

  log "Rootless Docker configured (socket unix:///run/user/$uid/docker.sock)."
  log "System (rootful) Docker is left installed but unused; to remove it:"
  log "  sudo systemctl disable --now docker.service docker.socket"
fi
