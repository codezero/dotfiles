#!/usr/bin/env bash
# ============================================================================
# Master provisioner — replicate the full machine setup on a clean Ubuntu 26.04.
# Designed to be safe for cloud-init: runs as root, non-interactive, idempotent,
# and tolerant (one failing step never aborts the rest).
#
#   sudo bash provision.sh         # full set, per-user steps drop to the invoking user
#   bash provision.sh --dry-run    # preview only; no changes, no sudo, no network
#
# The recipes and the full flag list live in `--help` and provision/README.md#flags
# (one owner per fact — don't restate them here).
#
# It installs:  apt base pkgs · Docker/VSCodium/Cursor · Homebrew formulae
#               · Rust (rustup) + Alacritty · Claude Code · Flatpak+Flathub
#               · GNOME dconf settings (desktop only)
#               · zsh/oh-my-zsh/p10k + dotfiles symlinks
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help) cat <<'EOF'
provision.sh — replicate a full machine on a clean Ubuntu 26.04.

usage: [sudo] [env VAR=val ...] bash provision.sh [--dry-run|-n]

Pick a recipe (run from the repo; `git` is the only bootstrap dependency):

  full machine, this user     sudo bash provision.sh
  lean headless agent box     sudo env PROFILE=minimal bash provision.sh
  daily desktop               sudo env INSTALL_DESKTOP=1 bash provision.sh
  golden image (strict)       sudo env GOLDEN_IMAGE=1 PROVISION_USER=ubuntu bash provision.sh
  bring a box up to date      sudo env APT_UPGRADE=1 bash provision.sh
  shell + dotfiles only       bash install.sh   (repo root; no root, other script)

Preview ANY of them by adding --dry-run: prints every planned action, makes no
changes, and needs neither sudo nor network.

Add-ons, combinable with any recipe above:
  PROVISION_USER=alice   target another account (it must already exist)
  DOCKER_ROOTLESS=1      rootless Docker for that user (step 25)
  DOTFILES_COPY=1        copy dotfiles into $HOME instead of symlinking
  STRICT=1               abort on the first failure instead of continuing

Every flag, its default, and how they combine: provision/README.md#flags
EOF
      exit 0 ;;
    *) echo "unknown argument: $a (try --help)" >&2; exit 2 ;;
  esac
done
export DRY_RUN

# Flags are UPPERCASE env vars; warn on the common lowercase typo before defaulting.
for _lc in install_desktop golden_image docker_rootless apt_upgrade profile strict dotfiles_copy; do
  _uc="${_lc^^}"
  [ -n "${!_lc:-}" ] && [ -z "${!_uc:-}" ] && \
    echo "[warn] env '$_lc' is set but IGNORED — flags are UPPERCASE; did you mean '$_uc'?" >&2
done
unset _lc _uc

export INSTALL_DESKTOP="${INSTALL_DESKTOP:-0}"   # 1 = also install the desktop/locale/IME set
export GOLDEN_IMAGE="${GOLDEN_IMAGE:-0}"         # 1 = strict build + finalize + self-contained dotfile copies
export DOCKER_ROOTLESS="${DOCKER_ROOTLESS:-0}"   # 1 = set up rootless Docker for the target user (step 25)
export APT_UPGRADE="${APT_UPGRADE:-0}"           # 1 = apt-get upgrade already-installed pkgs first (step 10)
export PROFILE="${PROFILE:-full}"                # minimal = lean headless agent box (no GUI steps/editors)

source "$HERE/lib.sh"

# Validate PROFILE early — a typo'd value would silently provision the FULL set.
case "$PROFILE" in
  full|minimal) : ;;
  *) die "PROFILE must be 'full' or 'minimal' (got '$PROFILE')" ;;
esac
# minimal + desktop contradict: step 10 would install the desktop apt set while
# the GUI steps (36/50/55) skip — a half-state. Refuse the combination outright.
if minimal && [ "$INSTALL_DESKTOP" = "1" ]; then
  die "PROFILE=minimal and INSTALL_DESKTOP=1 conflict — a minimal agent box has no GUI; drop one of the flags"
fi

if dry; then
  log "DRY RUN — no changes will be made; printing planned actions."
else
  is_root || die "Run with sudo/root (or pass --dry-run). Per-user steps drop to '$TARGET_USER'."
fi
[ -n "${TARGET_HOME:-}" ] || { dry && warn "could not resolve home for '$TARGET_USER'" \
  || die "Could not resolve home dir for user '$TARGET_USER'."; }
log "Target user: $TARGET_USER   home: ${TARGET_HOME:-<unknown>}"

STEPS=(
  10-apt.sh
  20-apt-third-party.sh
  25-docker-rootless.sh
  30-brew.sh
  35-rust.sh
  36-alacritty.sh
  37-claude-code.sh
  50-flatpak.sh
  55-gnome-dconf.sh
  60-shell.sh
  80-next-steps.sh
  90-finalize.sh
)

# Pause the background apt updaters before any step touches apt (fresh-boot race).
apt_preflight

# Soft-failure log: tolerant helpers (apt_install, installer steps) append real
# failures here so the run finishes every step yet still exits non-zero —
# automation / golden-image builds must not bake a partial install as success.
if ! dry; then
  # die on mktemp failure: without this log we can't track soft failures, so the
  # run could exit 0 despite them — honest exit codes are the whole point.
  SOFT_FAIL_LOG="$(mktemp)" || die "could not create soft-failure log (mktemp failed)"
  export SOFT_FAIL_LOG
fi

failed=()
for s in "${STEPS[@]}"; do
  echo; log "──────── step: $s ────────"
  if ! bash "$STEPS_DIR/$s"; then
    strict && die "step '$s' failed (STRICT/GOLDEN_IMAGE — aborting before any image capture)"
    warn "step '$s' exited non-zero — continuing"
    failed+=("$s")
  fi
done

# Normal runs tidy here. In GOLDEN_IMAGE mode the finalize step (90) owns cleanup
# and must run LAST (it autoremoves + clears logs), so don't rewrite apt/dpkg
# state after it.
if [ "${GOLDEN_IMAGE:-0}" != "1" ]; then
  log "Tidying apt"
  apt_get autoremove -y >/dev/null 2>&1 || true
fi

# GOLDEN: finalize (step 90) is the LAST guest-side action — it wiped logs,
# history, and tmp. Print/write NOTHING after it (the summary below could
# otherwise be captured into the image). The per-clone manual follow-ups are
# already on-box: step 80 wrote ~/PROVISION-NEXT-STEPS.md + an MOTD pointer,
# both of which survive finalize. A golden run is STRICT, so any failure
# already aborted; reaching here means success.
if [ "${GOLDEN_IMAGE:-0}" = "1" ] && ! dry; then
  exit 0
fi

soft_n=0
if [ -n "${SOFT_FAIL_LOG:-}" ] && [ -f "$SOFT_FAIL_LOG" ]; then
  soft_n="$(wc -l < "$SOFT_FAIL_LOG" | tr -d ' ')"
fi

echo
if dry; then
  log "DRY RUN finished — nothing was changed. Re-run without --dry-run to apply."
elif [ "${#failed[@]}" -eq 0 ] && [ "$soft_n" -eq 0 ]; then
  log "✅ Provisioning complete — no failures."
else
  [ "${#failed[@]}" -gt 0 ] && warn "steps that exited non-zero: ${failed[*]}"
  if [ "$soft_n" -gt 0 ]; then
    warn "$soft_n soft failure(s) recorded:"
    sed 's/^/    - /' "$SOFT_FAIL_LOG" >&2
  fi
fi

# Real runs only — a dry-run changed nothing, so post-install follow-ups would
# be misleading (and look like it actually ran). Golden already exited above.
# Text lives in lib.sh (next_steps_text) — step 80 wrote the same content to
# ~/PROVISION-NEXT-STEPS.md so it persists beyond this one-time print.
if ! dry; then
  echo
  next_steps_text
  echo
  log "Also saved on-box: $TARGET_HOME/PROVISION-NEXT-STEPS.md (MOTD reminds at login; delete the file when done)"
fi

# Every step ran regardless of failures; this only sets the exit code so that
# image-build automation can detect a partial/failed provision.
[ -n "${SOFT_FAIL_LOG:-}" ] && rm -f "$SOFT_FAIL_LOG"
if ! dry && { [ "${#failed[@]}" -gt 0 ] || [ "${soft_n:-0}" -gt 0 ]; }; then
  exit 1
fi
