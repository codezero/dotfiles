#!/usr/bin/env bash
# Step 60 — zsh + oh-my-zsh + Powerlevel10k, symlink dotfiles, set default shell.
# Per-user step: runs installs as the target user.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

log "Shell setup for '$TARGET_USER'"

# oh-my-zsh (unattended; don't let it run zsh or overwrite our .zshrc).
as_user 'test -d "$HOME/.oh-my-zsh" || \
  RUNZSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended' \
  || soft_fail "oh-my-zsh install failed"

# Powerlevel10k theme.
as_user 'ZC="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"; \
  test -d "$ZC/themes/powerlevel10k" || \
  git clone --depth=1 https://github.com/romkatv/powerlevel10k "$ZC/themes/powerlevel10k"' \
  || soft_fail "powerlevel10k clone failed"

# Install dotfiles from the repo into the target user's home (nested paths too).
# File set = the shared manifest at the repo root (also read by install.sh, so
# the two can't drift). GOLDEN_IMAGE or DOTFILES_COPY=1 -> COPY (self-contained)
# instead of symlinking back to the repo path.
copy_mode=0
{ [ "${GOLDEN_IMAGE:-0}" = "1" ] || [ "${DOTFILES_COPY:-0}" = "1" ]; } && copy_mode=1
mapfile -t dotfiles < <(grep -vE '^[[:space:]]*(#|$)' "$DOTFILES_ROOT/dotfiles.list")

for f in "${dotfiles[@]}"; do
  # Reject unsafe manifest entries before any root-backed mkdir/cp/chown/symlink.
  case "$f" in ""|/*|*..*) warn "skip unsafe dotfiles.list entry: '$f'"; continue ;; esac
  src="$DOTFILES_ROOT/$f"
  dst="$TARGET_HOME/$f"
  [ -e "$src" ] || { warn "missing $src — skipping"; continue; }
  if dry; then
    if [ "$copy_mode" = "1" ]; then would "copy $src -> $dst (self-contained)"; \
    else would "symlink $dst -> $src"; fi
    continue
  fi
  # Create any parent dirs and make the whole NEW chain user-owned. Everything
  # under $HOME should belong to the user, so re-chowning dirs that already
  # existed is a harmless no-op; this just avoids leaving a root-owned ~/.config
  # or ~/.claude behind when mkdir -p has to create them.
  rel="${f%/*}"
  if [ "$rel" != "$f" ]; then
    $SUDO mkdir -p "$TARGET_HOME/$rel"
    d="$rel"
    while [ "$d" != "." ] && [ "$d" != "/" ]; do
      $SUDO chown "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME/$d" 2>/dev/null || true
      d="$(dirname "$d")"
    done
  fi
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    $SUDO mv "$dst" "$dst.backup.$(date +%s)"
  fi
  if [ "$copy_mode" = "1" ]; then
    $SUDO rm -rf "$dst"           # drop any pre-existing symlink/dir before copying
    $SUDO cp -a "$src" "$dst"     # self-contained copy; -a handles files AND dirs (nvim)
    # cp -a preserves the repo's ownership, so re-own the WHOLE tree, not just top.
    $SUDO chown -R "$TARGET_USER":"$TARGET_USER" "$dst" 2>/dev/null || true
  else
    $SUDO ln -sfn "$src" "$dst"   # dir-capable (replaces an existing symlink)
    $SUDO chown -h "$TARGET_USER":"$TARGET_USER" "$dst" 2>/dev/null || true
  fi
done

# Make zsh the login shell — only if it isn't already, so re-runs are a no-op.
ZSH_BIN="$(command -v zsh || echo /usr/bin/zsh)"
if [ "$(getent passwd "$TARGET_USER" | cut -d: -f7)" = "$ZSH_BIN" ]; then
  log "default shell already $ZSH_BIN"
else
  run $SUDO chsh -s "$ZSH_BIN" "$TARGET_USER" || soft_fail "chsh failed for $TARGET_USER (login shell not set to zsh)"
fi
