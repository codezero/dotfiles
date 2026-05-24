#!/usr/bin/env bash
# ============================================================================
# Master provisioner — replicate the full machine setup on a clean Ubuntu 26.04.
# Designed to be safe for cloud-init: runs as root, non-interactive, idempotent,
# and tolerant (one failing step never aborts the rest).
#
#   sudo bash provision.sh                    # auto-detect the target user
#   sudo PROVISION_USER=alice bash provision.sh
#   bash provision.sh --dry-run               # preview only; no changes, no sudo needed
#
# It installs:  apt base pkgs · Docker/VSCodium/Bruno/Cursor · Homebrew formulae
#               · Rust (rustup) + Alacritty · Claude Code · Flatpak+Flathub
#               · zsh/oh-my-zsh/p10k + dotfiles symlinks
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help) echo "usage: [sudo] bash provision.sh [--dry-run|-n]"; exit 0 ;;
    *) echo "unknown argument: $a (try --help)" >&2; exit 2 ;;
  esac
done
export DRY_RUN
export INSTALL_DESKTOP="${INSTALL_DESKTOP:-0}"   # 1 = also install the desktop/locale/IME set

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
  60-shell.sh
)

failed=()
for s in "${STEPS[@]}"; do
  echo; log "──────── step: $s ────────"
  if ! bash "$STEPS_DIR/$s"; then
    warn "step '$s' exited non-zero — continuing"
    failed+=("$s")
  fi
done

log "Tidying apt"
apt_get autoremove -y >/dev/null 2>&1 || true

echo
if dry; then
  log "DRY RUN finished — nothing was changed. Re-run without --dry-run to apply."
elif [ "${#failed[@]}" -eq 0 ]; then
  log "✅ Provisioning complete — no step-level failures."
else
  warn "Completed, but these steps had issues: ${failed[*]}"
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
