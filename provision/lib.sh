#!/usr/bin/env bash
# Shared helpers for the provisioning scripts. SOURCE this; don't run directly.
# ----------------------------------------------------------------------------

# Repo layout: this file lives in <repo>/provision/lib.sh
# These vars are consumed by the step scripts that SOURCE this file, so shellcheck
# can't see their use when it lints lib.sh in isolation.
# shellcheck disable=SC2034
PROVISION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_ROOT="$(cd "$PROVISION_DIR/.." && pwd)"
PKG_DIR="$PROVISION_DIR/packages"
STEPS_DIR="$PROVISION_DIR/steps"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[err]\033[0m %s\n'  "$*" >&2; exit 1; }

is_root() { [ "$(id -u)" -eq 0 ]; }
SUDO=""; is_root || SUDO="sudo"

# --- dry-run support --------------------------------------------------------
# provision.sh exports DRY_RUN=1 for `--dry-run`. In that mode the helpers below
# PRINT the action they would take and change nothing.
DRY_RUN="${DRY_RUN:-0}"
dry()   { [ "$DRY_RUN" = "1" ]; }
would() { printf '   \033[2m[would]\033[0m %s\n' "$*"; }
# Execute a plain command (no pipes/redirects), or just print it in dry-run.
run()   { if dry; then would "$*"; else "$@"; fi; }

# --- strict / golden-image mode ---------------------------------------------
# GOLDEN_IMAGE=1 builds a reusable image: it implies STRICT (fail hard on the
# first real failure instead of warn-and-continue) and turns on the finalize
# step (90) + self-contained dotfile copies (step 60). STRICT may also be set
# on its own for a fail-fast run without the image finalize.
GOLDEN_IMAGE="${GOLDEN_IMAGE:-0}"
STRICT="${STRICT:-$GOLDEN_IMAGE}"
strict() { [ "$STRICT" = "1" ]; }

# --- soft-failure tracking --------------------------------------------------
# Tolerant helpers (apt_install, installer steps) call soft_fail on a REAL
# failure. Normally it warns + records to $SOFT_FAIL_LOG so the run finishes
# every step yet still exits non-zero. Under STRICT it dies on the first failure
# (so a golden image is never captured from a partial/broken provision).
SOFT_FAIL_LOG="${SOFT_FAIL_LOG:-}"
soft_fail() {
  strict && die "$*"
  warn "$*"
  [ -n "$SOFT_FAIL_LOG" ] && printf '%s\n' "$*" >> "$SOFT_FAIL_LOG" 2>/dev/null || true
}

# --- target user resolution -------------------------------------------------
# Per-user installs (Homebrew, oh-my-zsh, rustup, Claude Code, dotfiles) can't
# run as root, and cloud-init runs as root — so those steps drop to this user.
#   - PROVISION_USER set explicitly -> it MUST exist, else die. This catches a
#     typo in cloud-init before we silently provision the wrong account; an
#     existing user such as the AWS AMI default `ubuntu` is honored as-is.
#   - PROVISION_USER unset           -> best-effort: the invoking user
#     (SUDO_USER / logname), then the uid-1000 user, then literally "ubuntu".
# (In --dry-run a missing explicit user only warns, so previews never block.)
if [ -n "${PROVISION_USER:-}" ]; then
  TARGET_USER="$PROVISION_USER"
  if ! id "$TARGET_USER" >/dev/null 2>&1; then
    if dry; then
      warn "PROVISION_USER='$TARGET_USER' does not exist (continuing for dry-run preview)"
    else
      die "PROVISION_USER='$TARGET_USER' does not exist. Create the user first, or unset PROVISION_USER to auto-detect the invoking/uid-1000 user."
    fi
  fi
else
  TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
  if [ -z "${TARGET_USER:-}" ] || ! id "$TARGET_USER" >/dev/null 2>&1; then
    TARGET_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
  fi
  [ -n "${TARGET_USER:-}" ] || TARGET_USER="ubuntu"
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"

# Per-user installs (Homebrew/oh-my-zsh/rustup) must NOT run as root and
# shouldn't land in /root. Refuse a root/uid-0 target (covers SUDO_USER=root,
# PROVISION_USER=root, or a uid-1000 that happens to be root). Dry-run only warns.
if [ "$(id -u "$TARGET_USER" 2>/dev/null || true)" = "0" ]; then
  if dry; then
    warn "TARGET_USER '$TARGET_USER' is root (uid 0) — per-user steps would fail; set PROVISION_USER to a normal user"
  else
    die "Refusing to target root (uid 0): set PROVISION_USER to a non-root user — Homebrew/oh-my-zsh won't run as root."
  fi
fi

# Run a command as the target (non-root) user via a login shell.
as_user() {
  if dry; then would "(as $TARGET_USER) $*"; return 0; fi
  if [ "$(id -un)" = "$TARGET_USER" ]; then
    bash -lc "$*"
  else
    sudo -u "$TARGET_USER" -H bash -lc "$*"
  fi
}

# Non-interactive apt. Wrap every call in `env` so the noninteractive/needrestart
# settings survive `sudo` (sudo resets the environment by default). The force-conf*
# options auto-resolve dpkg config-file prompts. `apt_get` returns apt's real exit
# status; `apt_install` is the tolerant variant most steps use.
export DEBIAN_FRONTEND=noninteractive
apt_get() {
  if dry; then would "apt-get $*"; return 0; fi
  # DPkg::Lock::Timeout makes apt WAIT for the lock instead of failing — essential
  # on cloud-init first boot where unattended-upgrades often holds it.
  $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
    apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            -o DPkg::Lock::Timeout=600 "$@"
}
apt_install() { apt_get install -y "$@" || soft_fail "apt: some of [$*] failed to install"; }

# Validate a keyring file holds a usable GPG key before we trust its repo. If
# `expected_fp` is non-empty, the primary-key fingerprint must match it. Returns
# non-zero (so callers can GATE the repo add) on an empty/garbage key or a
# fingerprint mismatch — prevents adding a repo behind a failed/tampered key.
verify_keyring() {
  local kr="$1" want="${2:-}" got
  [ -s "$kr" ] || { warn "GPG keyring $kr is empty/missing"; return 1; }
  got="$(gpg --show-keys --with-colons "$kr" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
  [ -n "$got" ] || { warn "no GPG key found in $kr"; return 1; }
  if [ -n "$want" ] && [ "$got" != "$want" ]; then
    warn "GPG fingerprint mismatch in $kr: got $got expected $want"
    return 1
  fi
  return 0
}

# Fresh-boot apt preflight. On first boot Ubuntu's apt-daily timers + unattended-
# upgrades fire and hold the dpkg lock, so our first apt-get blocks and looks
# frozen (and may fail if the upgrade runs > Lock::Timeout). STOP those units for
# this run (temporary — `stop` resumes on next boot; we don't disable/mask), then
# WAIT for any in-flight run to finish via a transient systemd unit ordered After
# them (the modern way — no brittle lock-file polling). apt_get's
# DPkg::Lock::Timeout=600 is the final backstop. Verified current for 26.04/APT 3.x.
apt_preflight() {
  if dry; then
    would "pause apt-daily/unattended-upgrades/packagekit units, then wait for any in-flight run"
    return 0
  fi
  log "apt preflight: pausing background updaters for this run (they resume on next boot)"
  for u in unattended-upgrades.service apt-daily.service apt-daily-upgrade.service \
           apt-daily.timer apt-daily-upgrade.timer packagekit.service; do
    $SUDO systemctl stop "$u" 2>/dev/null || true
  done
  command -v systemd-run >/dev/null 2>&1 && \
    $SUDO systemd-run --quiet --collect --wait \
      --property="After=apt-daily.service apt-daily-upgrade.service unattended-upgrades.service" \
      /bin/true 2>/dev/null || true
}

load_brew() {
  [ -x /home/linuxbrew/.linuxbrew/bin/brew ] && \
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
}
