#!/usr/bin/env bash
# Step 60 — zsh + oh-my-zsh + Powerlevel10k, symlink dotfiles, set default shell.
# Per-user step: runs installs as the target user.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

log "Shell setup for '$TARGET_USER'"

# oh-my-zsh: a PINNED clone (pins.sh OMZ_SHA) instead of its installer script
# from master (TODO J). With --unattended KEEP_ZSHRC=yes RUNZSH=no that script
# was a clone plus five git-config lines, which clone_pinned reproduces; our
# .zshrc is never touched and chsh is ours below. Gate on the SENTINEL FILE,
# not the directory: an interrupted clone leaves a partial ~/.oh-my-zsh that a
# dir-only check would skip forever; clone_pinned replaces the dir wholesale.
as_user "test -f \"\$HOME/.oh-my-zsh/oh-my-zsh.sh\" || \
  bash '$PINS' clone_pinned '$OMZ_URL' '$OMZ_SHA' \"\$HOME/.oh-my-zsh\"" \
  || soft_fail "oh-my-zsh clone failed (see pins.sh)"
as_user 'test -f "$HOME/.oh-my-zsh/oh-my-zsh.sh"' \
  || soft_fail "oh-my-zsh incomplete: ~/.oh-my-zsh/oh-my-zsh.sh missing after install"

# Powerlevel10k theme (same sentinel-file pattern).
as_user "ZC=\"\${ZSH_CUSTOM:-\$HOME/.oh-my-zsh/custom}\"; \
  test -f \"\$ZC/themes/powerlevel10k/powerlevel10k.zsh-theme\" || \
  bash '$PINS' clone_pinned '$P10K_URL' '$P10K_SHA' \"\$ZC/themes/powerlevel10k\"" \
  || soft_fail "powerlevel10k clone failed (see pins.sh)"
as_user 'test -f "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k/powerlevel10k.zsh-theme"' \
  || soft_fail "powerlevel10k incomplete: powerlevel10k.zsh-theme missing after install"

# Install dotfiles from the repo into the target user's home (nested paths too).
# File set = the shared manifest at the repo root (also read by install.sh, so
# the two can't drift). GOLDEN_IMAGE or DOTFILES_COPY=1 -> COPY (self-contained)
# instead of symlinking back to the repo path.
copy_mode=0
{ [ "${GOLDEN_IMAGE:-0}" = "1" ] || [ "${DOTFILES_COPY:-0}" = "1" ]; } && copy_mode=1
mapfile -t dotfiles < <(grep -vE '^[[:space:]]*(#|$)' "$DOTFILES_ROOT/dotfiles.list")

# True if src and dst already hold identical content (file OR whole dir tree).
# Lets copy-mode reruns skip the backup + re-copy of unchanged dotfiles instead
# of churning out a fresh $dst.backup.<ts> every time.
unchanged() {
  if [ -d "$1" ]; then diff -rq "$1" "$2" >/dev/null 2>&1
  else cmp -s "$1" "$2"; fi
}

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
      $SUDO chown "$TARGET_USER":"$TARGET_GROUP" "$TARGET_HOME/$d" 2>/dev/null || true
      d="$(dirname "$d")"
    done
  fi
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    # Existing REAL file/dir. If it already matches what we install (a previous
    # copy-mode run), leave it — no backup, no re-copy. Only a genuinely
    # DIFFERENT pre-existing file gets backed up (once per content change).
    if unchanged "$src" "$dst"; then continue; fi
    $SUDO mv "$dst" "$dst.backup.$(date +%s)"
  fi
  if [ "$copy_mode" = "1" ]; then
    $SUDO rm -rf "$dst"           # drop any pre-existing symlink/dir before copying
    # -a handles files AND dirs (nvim). soft_fail => STRICT/golden aborts rather
    # than capturing an image with a dotfile silently missing.
    $SUDO cp -a "$src" "$dst" || { soft_fail "dotfile copy failed: $f"; continue; }
    # cp -a preserves the repo's ownership, so re-own the WHOLE tree, not just top.
    $SUDO chown -R "$TARGET_USER":"$TARGET_GROUP" "$dst" 2>/dev/null || true
  else
    $SUDO ln -sfn "$src" "$dst" || { soft_fail "dotfile symlink failed: $f"; continue; }
    $SUDO chown -h "$TARGET_USER":"$TARGET_GROUP" "$dst" 2>/dev/null || true
  fi
done

# Make zsh the login shell — only if it isn't already, so re-runs are a no-op.
ZSH_BIN="$(command -v zsh || echo /usr/bin/zsh)"
if [ "$(getent passwd "$TARGET_USER" | cut -d: -f7)" = "$ZSH_BIN" ]; then
  log "default shell already $ZSH_BIN"
else
  run $SUDO chsh -s "$ZSH_BIN" "$TARGET_USER" || soft_fail "chsh failed for $TARGET_USER (login shell not set to zsh)"
fi
