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

# --- profile -----------------------------------------------------------------
# PROFILE=minimal = lean headless box for AI agents: GUI steps (36-alacritty,
# 50-flatpak) and GUI editors (VSCodium/Cursor in step 20) are skipped, and the
# lean package lists (apt.minimal.list / Brewfile.minimal) are used. zsh + p10k
# + dotfiles + Docker + rust + Claude Code are kept. provision.sh validates the
# value and rejects PROFILE=minimal + INSTALL_DESKTOP=1.
PROFILE="${PROFILE:-full}"
minimal() { [ "$PROFILE" = "minimal" ]; }

# --- strict / golden-image mode ---------------------------------------------
# GOLDEN_IMAGE=1 builds a reusable image: it implies STRICT (fail hard on the
# first real failure instead of warn-and-continue) and turns on the finalize
# step (90) + self-contained dotfile copies (step 60). STRICT may also be set
# on its own for a fail-fast run without the image finalize.
GOLDEN_IMAGE="${GOLDEN_IMAGE:-0}"
# GOLDEN_IMAGE HARD-forces STRICT — never let an explicit STRICT=0 weaken a
# golden build (a soft failure must abort before an image is ever captured).
# STRICT may still be set on its own for a fail-fast run without the finalize.
STRICT="${STRICT:-0}"
[ "$GOLDEN_IMAGE" = "1" ] && STRICT=1
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
#     (SUDO_USER / logname), then the uid-1000 user, then literally "ubuntu" —
#     and if even THAT doesn't exist, die the same way: this repo never creates
#     users, so a box with no non-root account must be told which one to use.
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
  # That last rung is a GUESS, and nothing ever checked it landed on a real
  # account. On a box with no non-root user at all — a bare container image, a
  # hardened cloud image with the default user removed — the chain ends at the
  # literal "ubuntu", which then doesn't exist: TARGET_HOME comes out EMPTY and
  # the per-user steps chown/write into nowhere. Refuse, and name the one thing
  # that fixes it. Deliberately NOT auto-creating the account: user creation is
  # cloud-init's job (`users:` + ssh_authorized_keys), and inventing one here
  # would produce a box whose login story nobody wrote down.
  if ! id "$TARGET_USER" >/dev/null 2>&1; then
    if dry; then
      warn "no non-root user found (auto-detect fell through to '$TARGET_USER', which does not exist) — set PROVISION_USER to an existing account"
    else
      die "No non-root user on this box (auto-detect fell through to '$TARGET_USER', which does not exist). Create the account first — cloud-init's 'users:' owns that — then set PROVISION_USER=<name>."
    fi
  fi
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
# Primary GROUP of the target user — do NOT assume it equals the username
# (true for stock Ubuntu users, not for custom/cloud-directory accounts).
TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"

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

# Run a command as the target (non-root) user.
# Deliberately a NON-login shell (`bash -c`, not `-lc`): a non-interactive LOGIN
# bash runs ~/.bash_logout on exit, and Ubuntu's default runs `clear_console`,
# which FAILS without a controlling tty (we have none under sudo). On an explicit
# `exit N` that failure overwrites the status — so an idempotent skip (`exit 0`)
# was wrongly reported as a step failure. We don't need login PATH: brew is
# eval'd by absolute path, rustup installs --no-modify-path, and blocks that need
# cargo source ~/.cargo/env themselves — so the profile never provided anything.
as_user() {
  if dry; then would "(as $TARGET_USER) $*"; return 0; fi
  if [ "$(id -un)" = "$TARGET_USER" ]; then
    bash -c "$*"
  else
    sudo -u "$TARGET_USER" -H bash -c "$*"
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
  # </dev/null: detach stdin so a maintainer script / trigger that reads the
  # terminal gets EOF instead of blocking or stopping the run on a tty (the
  # job-control "T (stopped)" symptom seen on an interactive run).
  $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
    apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
            -o DPkg::Lock::Timeout=600 "$@" </dev/null
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
    would "pause apt-daily/unattended-upgrades/packagekit units (30s cap each), then wait up to ${APT_PREFLIGHT_TIMEOUT:-300}s for any in-flight run"
    return 0
  fi
  # Everything here is BEST-EFFORT and time-bounded. apt's own
  # DPkg::Lock::Timeout=600 (see apt_get) is the real backstop, so this may
  # always give up and continue — it exists to avoid a lock wait, not to
  # guarantee one never happens.
  local wait_max="${APT_PREFLIGHT_TIMEOUT:-300}"
  log "apt preflight: pausing background updaters for this run (they resume on next boot)"
  for u in unattended-upgrades.service apt-daily.service apt-daily-upgrade.service \
           apt-daily.timer apt-daily-upgrade.timer packagekit.service; do
    # `systemctl stop` BLOCKS until the unit stops, and a stop queued behind a
    # still-running start job waits for that job to finish first — unbounded on
    # a fresh boot. Cap it; a unit we couldn't stop is not fatal.
    timeout 30 $SUDO systemctl stop "$u" 2>/dev/null \
      || warn "apt preflight: could not stop $u within 30s — continuing"
  done
  if command -v systemd-run >/dev/null 2>&1; then
    # Transient unit ordered After= the updaters: it runs once they're done, so
    # waiting on it waits for any in-flight run. MUST be bounded — on a freshly
    # booted desktop image unattended-upgrade can churn for many minutes, and an
    # unbounded silent wait here is indistinguishable from a hang (observed live,
    # S4: the run sat on this for minutes with no output). Announce the bound
    # BEFORE waiting so it never reads as frozen.
    log "apt preflight: waiting up to ${wait_max}s for any in-flight apt-daily / unattended-upgrade run (set APT_PREFLIGHT_TIMEOUT to change)"
    if timeout "$wait_max" $SUDO systemd-run --quiet --collect --wait \
         --property="After=apt-daily.service apt-daily-upgrade.service unattended-upgrades.service" \
         /bin/true 2>/dev/null; then
      log "apt preflight: no in-flight run (or it finished)"
    else
      warn "apt preflight: a background updater is STILL running after ${wait_max}s — continuing anyway; apt will wait for the dpkg lock (DPkg::Lock::Timeout=600)"
    fi
  fi
}

load_brew() {
  [ -x /home/linuxbrew/.linuxbrew/bin/brew ] && \
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
}

# Is rootless Docker actually SET UP for the target user? Keyed off the artifact
# `dockerd-rootless-setuptool.sh install` leaves behind, NOT off $DOCKER_ROOTLESS:
# step 25 soft-fails on a userns-restricted host and deliberately leaves the box
# rootful, so the flag says what was ASKED FOR and this says what HAPPENED.
# A file test rather than `docker info` on purpose: both callers run as root,
# where the user's rootless socket/context isn't reachable without their session
# bus. Weaker than the smoke-test audit (which must read the daemon) — and the
# right trade here, because this only decides which paragraph to print.
rootless_docker_ready() {
  [ -n "${TARGET_HOME:-}" ] && [ -f "$TARGET_HOME/.config/systemd/user/docker.service" ]
}

# The manual post-provision follow-ups. ONE source of truth: provision.sh prints
# this at the end of a normal run, and step 80 writes it to
# ~/PROVISION-NEXT-STEPS.md (+ an MOTD pointer) — a GOLDEN build exits + wipes
# before the end-of-run summary, so without the file a clone / cloud-init user
# would have no on-box record of these. Plain text that also reads as Markdown.
#
# THIS FUNCTION OWNS THE FACT. Any other surface (either README, the MOTD
# pointer, CLAUDE.md) must point at it rather than re-list the follow-ups —
# restating them is how the "jj/bun may warn" claim stayed wrong in two places.
#
# It branches on machine STATE, not only on flags: a bullet telling the user to
# do something this very run already did is worse than no bullet, because they
# do the work twice and lose trust in the rest of the list.
next_steps_text() {
  cat <<EOF
Manual follow-ups (need an interactive login session):

  - Open a new terminal so zsh + Powerlevel10k load.
  - Node:  nvm install --lts
  - corepack (was in your Brewfile as 'npm "corepack"' — it ships with Node):
        corepack enable
EOF
  # Step 36 (which installs the vendored Nerd Font) is skipped under
  # PROFILE=minimal, so the two profiles need opposite advice. Fonts render
  # CLIENT-side: over SSH the glyphs come from the font on the machine you're
  # sitting at, so a headless box genuinely doesn't need one. But if you open a
  # terminal ON a minimal box that happens to have a desktop, p10k's glyphs are
  # tofu — say so rather than staying silent (observed live, S11).
  if minimal; then
    cat <<EOF
  - No Nerd Font on this profile (PROFILE=minimal skips it). Over SSH that's
    fine — glyphs render with YOUR local terminal's font. Only if you open a
    terminal ON this box will p10k show boxes/tofu; then either install the
    font here (repo: fonts/MesloLGS-NF -> ~/.local/share/fonts && fc-cache -f)
    or re-provision without PROFILE=minimal.
EOF
  elif [ "${INSTALL_DESKTOP:-0}" = "1" ]; then
    # Step 55 pointed GNOME's monospace-font-name at it (f945b93), so the stock
    # terminals need no hand-editing any more — telling the user to go and set
    # it is work that is already done. Flag-keyed, unlike rootless_docker_ready:
    # step 55 is gated on exactly this flag, and a failed `dconf load` soft-fails
    # loudly in the run output rather than passing silently.
    cat <<EOF
  - MesloLGS NF (Nerd Font) is installed system-wide, Alacritty pins it, and
    GNOME's monospace font is already set to it — the stock terminals are
    covered. Only a NON-GNOME terminal you add later needs "MesloLGS NF"
    chosen by hand in its font settings.
EOF
  else
    cat <<EOF
  - MesloLGS NF (Nerd Font) is installed system-wide and Alacritty pins it. No
    desktop was installed here, so any other terminal you add later needs
    "MesloLGS NF" chosen by hand in its font settings.
EOF
  fi
  cat <<EOF
  - Set your real git identity in ~/.gitconfig.
EOF
  if rootless_docker_ready; then
    cat <<EOF
  - Docker for $TARGET_USER: rootless is ALREADY set up (systemd --user unit +
    linger; the CLI defaults to the 'rootless' context). Nothing to do. Confirm
    it any time with:
        docker info --format '{{.SecurityOptions}} {{.DockerRootDir}}'
    'name=rootless' plus a DockerRootDir under \$HOME means you really are on
    the rootless daemon — a context merely NAMED rootless proves nothing.
    The rootful system daemon is still installed but unused; to drop it:
        sudo systemctl disable --now docker.service docker.socket
EOF
  else
    cat <<EOF
  - Docker access for $TARGET_USER — choose ONE:
      - rootless (recommended, unprivileged): re-run with DOCKER_ROOTLESS=1, or:
            dockerd-rootless-setuptool.sh install && systemctl --user enable --now docker
            sudo loginctl enable-linger $TARGET_USER   # survive logout (headless)
            docker context use rootless
        If 'docker' then fails with a user-namespace/clone error, Ubuntu 24.04+
        blocks unprivileged userns via AppArmor by default. Allow it persistently
        (host-wide security trade-off), then re-run the rootless setup:
            echo kernel.apparmor_restrict_unprivileged_userns=0 | sudo tee /etc/sysctl.d/99-rootless-userns.conf
            sudo sysctl --system
      - rootful without sudo (convenience; the 'docker' group is ROOT-equivalent):
            sudo usermod -aG docker $TARGET_USER
EOF
  fi
  # Not a follow-up — an explanation, kept out of the actionable list above so
  # it doesn't dilute it. "N packages can be upgraded" at login is correct in
  # BOTH directions and surprised this repo's own author in both (2026-08-05,
  # then live in S12), which is exactly the case for saying it where the user
  # is looking rather than only in CLAUDE.md. Flag-keyed: step 10's upgrade
  # branch is gated on precisely this variable.
  echo
  echo "Expected, no action needed:"
  if [ "${APT_UPGRADE:-0}" = "1" ]; then
    cat <<EOF

  - "N packages can be upgraded" may STILL appear at login even though this run
    used APT_UPGRADE=1, and the count will not reach zero. Step 10 runs
    'apt-get upgrade', never 'full-upgrade', so anything whose new version would
    ADD or REMOVE a package is held back — a kernel ABI bump is a brand-new
    package NAME each time. That is the "no new kernels" promise the flag exists
    to keep. Ubuntu's per-machine phased updates hold back a second, unrelated
    slice. To see which is which:
        apt-get -s upgrade
        apt-get -s -o APT::Get::Always-Include-Phased-Updates=true upgrade
EOF
  else
    cat <<EOF

  - "N packages can be upgraded" at login is expected. This run installed the
    packages the lists name and deliberately did NOT upgrade what was already
    on the box — a blanket upgrade also bumps the kernel/grub point-releases
    (initramfs rebuild + a pending reboot). To bring the box fully up to date,
    re-run with APT_UPGRADE=1.
EOF
  fi
}
