#!/usr/bin/env bash
# Step 60 — zsh + oh-my-zsh + Powerlevel10k, symlink dotfiles, set default shell.
# Per-user step: runs installs as the target user.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

log "Shell setup for '$TARGET_USER'"

# oh-my-zsh: a PINNED clone (pins.sh OMZ_SHA) instead of its installer script
# from master (TODO J). With --unattended KEEP_ZSHRC=yes RUNZSH=no that script
# was a clone plus five git-config lines, which clone_pinned reproduces; our
# .zshrc is never touched and chsh is ours below. Called on EVERY run, no
# sentinel gate (2026-09-21): clone_pinned is idempotent — at the pin it is a
# no-op, at any other commit (an `omz update` by hand, a pin bumped after this
# box was built) it moves the checkout to the pin, a partial clone is
# completed. The sentinel test below is the post-condition, not the gate.
as_user "bash '$PINS' clone_pinned '$OMZ_URL' '$OMZ_SHA' \"\$HOME/.oh-my-zsh\"" \
  || soft_fail "oh-my-zsh clone/converge failed (see pins.sh)"
as_user 'test -f "$HOME/.oh-my-zsh/oh-my-zsh.sh"' \
  || soft_fail "oh-my-zsh incomplete: ~/.oh-my-zsh/oh-my-zsh.sh missing after install"

# Powerlevel10k theme (same sentinel-file pattern).
as_user "ZC=\"\${ZSH_CUSTOM:-\$HOME/.oh-my-zsh/custom}\"; \
  bash '$PINS' clone_pinned '$P10K_URL' '$P10K_SHA' \"\$ZC/themes/powerlevel10k\"" \
  || soft_fail "powerlevel10k clone failed (see pins.sh)"
as_user 'test -f "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k/powerlevel10k.zsh-theme"' \
  || soft_fail "powerlevel10k incomplete: powerlevel10k.zsh-theme missing after install"

# Install dotfiles from the repo into the target user's home — AS THE USER, via
# the shared dotfiles-install.sh (the same code install.sh runs; manifest =
# dotfiles.list at the repo root). GOLDEN_IMAGE or DOTFILES_COPY=1 -> copy
# (self-contained) instead of symlinking back to the repo path.
#
# Until 2026-09-22 this step did the mkdir/chown/mv/rm/cp/ln itself AS ROOT
# straight into $TARGET_HOME. That is the escalation the external assessment
# flagged: a user-made `~/.config -> /etc` symlink turns `chown user ~/.config`
# into `chown user /etc`, and cp/rm/mv follow it too. None of it needs root —
# the repo is readable and the home is the user's — so it now runs as the
# user, who cannot escalate against themselves, and the installer refuses a
# symlinked parent outright. The dry-run preview below is kept here so the
# plan stays visible per file without sudo.
copy_mode=0
{ [ "${GOLDEN_IMAGE:-0}" = "1" ] || [ "${DOTFILES_COPY:-0}" = "1" ]; } && copy_mode=1
if dry; then
  while IFS= read -r f; do
    case "$f" in ""|/*|*..*) warn "skip unsafe dotfiles.list entry: '$f'"; continue ;; esac
    [ -e "$DOTFILES_ROOT/$f" ] || { warn "missing $DOTFILES_ROOT/$f — skipping"; continue; }
    if [ "$copy_mode" = "1" ]; then would "copy $DOTFILES_ROOT/$f -> $TARGET_HOME/$f (self-contained)"
    else would "symlink $TARGET_HOME/$f -> $DOTFILES_ROOT/$f"; fi
  done < <(grep -vE '^[[:space:]]*(#|$)' "$DOTFILES_ROOT/dotfiles.list")
else
  # The user must be able to READ the repo (it is in /tmp or /opt in every
  # supported layout, cloned with umask 022); say so plainly if not.
  as_user "test -r '$DOTFILES_ROOT/dotfiles.list' && test -r '$DOTFILES_ROOT/dotfiles-install.sh'" \
    || soft_fail "dotfiles: $DOTFILES_ROOT is not readable by $TARGET_USER — chmod -R a+rX it (the installer runs as the user, never as root)"
  # soft_fail => STRICT/golden aborts rather than capturing an image with a
  # dotfile silently missing (the installer exits 1 on any per-file failure).
  copy_flag=""; [ "$copy_mode" = 1 ] && copy_flag="--copy"
  as_user "bash '$DOTFILES_ROOT/dotfiles-install.sh' $copy_flag --src '$DOTFILES_ROOT'" \
    || soft_fail "dotfile install failed for $TARGET_USER (see the lines above)"
fi

# Make zsh the login shell — only if it isn't already, so re-runs are a no-op.
ZSH_BIN="$(command -v zsh || echo /usr/bin/zsh)"
if [ "$(getent passwd "$TARGET_USER" | cut -d: -f7)" = "$ZSH_BIN" ]; then
  log "default shell already $ZSH_BIN"
else
  run $SUDO chsh -s "$ZSH_BIN" "$TARGET_USER" || soft_fail "chsh failed for $TARGET_USER (login shell not set to zsh)"
fi
