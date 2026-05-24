#!/usr/bin/env bash
# ============================================================================
# Master provisioner — replicate the full machine setup on a clean Ubuntu 26.04.
# Designed to be safe for cloud-init: runs as root, non-interactive, idempotent,
# and tolerant (one failing step never aborts the rest).
#
#   sudo bash provision.sh                    # auto-detect the target user
#   sudo PROVISION_USER=alice bash provision.sh
#   bash provision.sh --dry-run               # preview only; no changes, no sudo needed
#   sudo GOLDEN_IMAGE=1 bash provision.sh     # strict build + finalize, ready to snapshot
#
# It installs:  apt base pkgs · Docker/VSCodium/Bruno/Cursor · Homebrew formulae
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
    -h|--help) echo "usage: [sudo] [PROVISION_USER=u] [INSTALL_DESKTOP=1] [GOLDEN_IMAGE=1] bash provision.sh [--dry-run|-n]"; exit 0 ;;
    *) echo "unknown argument: $a (try --help)" >&2; exit 2 ;;
  esac
done
export DRY_RUN
export INSTALL_DESKTOP="${INSTALL_DESKTOP:-0}"   # 1 = also install the desktop/locale/IME set
export GOLDEN_IMAGE="${GOLDEN_IMAGE:-0}"         # 1 = strict build + finalize + self-contained dotfile copies

source "$HERE/lib.sh"

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
  30-brew.sh
  35-rust.sh
  36-alacritty.sh
  37-claude-code.sh
  50-flatpak.sh
  55-gnome-dconf.sh
  60-shell.sh
  90-finalize.sh
)

# Soft-failure log: tolerant helpers (apt_install, installer steps) append real
# failures here so the run finishes every step yet still exits non-zero —
# automation / golden-image builds must not bake a partial install as success.
if ! dry; then SOFT_FAIL_LOG="$(mktemp)"; export SOFT_FAIL_LOG; fi

failed=()
for s in "${STEPS[@]}"; do
  echo; log "──────── step: $s ────────"
  if ! bash "$STEPS_DIR/$s"; then
    strict && die "step '$s' failed (STRICT/GOLDEN_IMAGE — aborting before any image capture)"
    warn "step '$s' exited non-zero — continuing"
    failed+=("$s")
  fi
done

log "Tidying apt"
apt_get autoremove -y >/dev/null 2>&1 || true

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

cat <<EOF

Manual follow-ups (need an interactive login session):
  • Open a new terminal so zsh + Powerlevel10k load.
  • Node:  nvm install --lts
  • corepack (was in your Brewfile as 'npm "corepack"' — it ships with Node):
        corepack enable
  • Install a Nerd Font for the prompt glyphs (e.g. MesloLGS NF) and select it
    in your terminal: https://github.com/romkatv/powerlevel10k#fonts
  • Set your real git identity in ~/.gitconfig.
  • (optional, security trade-off) docker without sudo:
        sudo usermod -aG docker $TARGET_USER   # 'docker' group == root-equivalent
EOF

# Every step ran regardless of failures; this only sets the exit code so that
# image-build automation can detect a partial/failed provision.
[ -n "${SOFT_FAIL_LOG:-}" ] && rm -f "$SOFT_FAIL_LOG"
if ! dry && { [ "${#failed[@]}" -gt 0 ] || [ "${soft_n:-0}" -gt 0 ]; }; then
  exit 1
fi
