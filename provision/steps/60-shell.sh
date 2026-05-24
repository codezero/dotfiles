#!/usr/bin/env bash
# Step 60 — zsh + oh-my-zsh + Powerlevel10k, symlink dotfiles, set default shell.
# Per-user step: runs installs as the target user.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

log "Shell setup for '$TARGET_USER'"

# oh-my-zsh (unattended; don't let it run zsh or overwrite our .zshrc).
as_user 'test -d "$HOME/.oh-my-zsh" || \
  RUNZSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended' \
  || warn "oh-my-zsh install failed"

# Powerlevel10k theme.
as_user 'ZC="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"; \
  test -d "$ZC/themes/powerlevel10k" || \
  git clone --depth=1 https://github.com/romkatv/powerlevel10k "$ZC/themes/powerlevel10k"' \
  || warn "powerlevel10k clone failed"

# Symlink dotfiles from the repo into the target user's home.
for f in .zshrc .p10k.zsh .gitconfig; do
  src="$DOTFILES_ROOT/$f"
  dst="$TARGET_HOME/$f"
  [ -e "$src" ] || { warn "missing $src — skipping"; continue; }
  if dry; then would "symlink $dst -> $src"; continue; fi
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    $SUDO mv "$dst" "$dst.backup.$(date +%s)"
  fi
  $SUDO ln -sfn "$src" "$dst"
  $SUDO chown -h "$TARGET_USER":"$TARGET_USER" "$dst" 2>/dev/null || true
done

# Make zsh the login shell — only if it isn't already, so re-runs are a no-op.
ZSH_BIN="$(command -v zsh || echo /usr/bin/zsh)"
if [ "$(getent passwd "$TARGET_USER" | cut -d: -f7)" = "$ZSH_BIN" ]; then
  log "default shell already $ZSH_BIN"
else
  run $SUDO chsh -s "$ZSH_BIN" "$TARGET_USER" || warn "chsh failed for $TARGET_USER"
fi
