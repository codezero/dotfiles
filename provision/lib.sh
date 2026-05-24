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

# --- soft-failure tracking --------------------------------------------------
# Tolerant helpers (apt_install, installer steps) call soft_fail on a REAL
# failure: it warns AND records to $SOFT_FAIL_LOG (set by provision.sh), so a
# run can finish every step yet still exit non-zero — automation / golden-image
# builds must not treat a partial install as success.
SOFT_FAIL_LOG="${SOFT_FAIL_LOG:-}"
soft_fail() {
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

load_brew() {
  [ -x /home/linuxbrew/.linuxbrew/bin/brew ] && \
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
}
