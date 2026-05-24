#!/usr/bin/env bash
# Shared helpers for the provisioning scripts. SOURCE this; don't run directly.
# ----------------------------------------------------------------------------

# Repo layout: this file lives in <repo>/provision/lib.sh
PROVISION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_ROOT="$(cd "$PROVISION_DIR/.." && pwd)"
PKG_DIR="$PROVISION_DIR/packages"
STEPS_DIR="$PROVISION_DIR/steps"

# Target (human) user for per-user installs: Homebrew, oh-my-zsh, dotfiles.
# Homebrew refuses to run as root, and cloud-init runs as root — so user-level
# steps drop to this account. Override with PROVISION_USER=<name>.
TARGET_USER="${PROVISION_USER:-${SUDO_USER:-$(logname 2>/dev/null || true)}}"
[ -n "${TARGET_USER:-}" ] && id "$TARGET_USER" >/dev/null 2>&1 || \
  TARGET_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
[ -n "${TARGET_USER:-}" ] || TARGET_USER="ubuntu"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"

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
apt_install() { apt_get install -y "$@" || warn "apt: some of [$*] failed to install"; }

load_brew() {
  [ -x /home/linuxbrew/.linuxbrew/bin/brew ] && \
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
}
