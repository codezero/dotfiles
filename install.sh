#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# Bootstrap a fresh Ubuntu (24.04 / 26.04) machine to use these dotfiles.
# Installs every prerequisite the .zshrc expects, then symlinks the dotfiles
# from this repo into $HOME.
#
# Run from inside the cloned repo:   ./install.sh
# Safe to re-run (idempotent). Existing real files are backed up, not deleted.
#
# SCOPE: this is the lightweight "shell + dotfiles" bootstrap (zsh, oh-my-zsh,
# Powerlevel10k, the core brew CLI tools, and the dotfile symlinks). For a FULL
# machine replication (Docker, VSCodium, Cursor, Bruno, snaps, Flatpak, the whole
# Brewfile, cloud-init support) use provision/provision.sh instead.
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> [1/7] Base apt packages"
sudo apt update
sudo apt install -y \
  zsh git curl wget build-essential \
  zsh-autosuggestions zsh-syntax-highlighting
# ^ zsh-autosuggestions & zsh-syntax-highlighting land in /usr/share/...,
#   which is exactly where .zshrc sources them from.

echo "==> [2/7] Homebrew (linuxbrew)"
if [ ! -x /home/linuxbrew/.linuxbrew/bin/brew ] && ! command -v brew >/dev/null 2>&1; then
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

echo "==> [3/7] oh-my-zsh"
export ZSH="${ZSH:-$HOME/.oh-my-zsh}"
if [ ! -d "$ZSH" ]; then
  # --unattended = don't run zsh or chsh here; KEEP_ZSHRC so our .zshrc wins.
  RUNZSH=no KEEP_ZSHRC=yes sh -c \
    "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
    "" --unattended
fi

echo "==> [4/7] Powerlevel10k theme"
ZSH_CUSTOM="${ZSH_CUSTOM:-$ZSH/custom}"
if [ ! -d "$ZSH_CUSTOM/themes/powerlevel10k" ]; then
  git clone --depth=1 https://github.com/romkatv/powerlevel10k \
    "$ZSH_CUSTOM/themes/powerlevel10k"
fi

echo "==> [5/7] CLI tools via brew (nvm, eza, bat, zoxide)"
# Installed via brew on purpose: brew's 'bat' binary is named `bat`, so the
# `alias cat="bat"` in .zshrc works. Ubuntu's apt 'bat' is named `batcat`.
brew install nvm eza bat zoxide
mkdir -p "$HOME/.nvm"   # required by brew's nvm

echo "==> [6/7] Symlink dotfiles into \$HOME"
link() {
  local name="$1"
  local src="$DOTFILES_DIR/$name"
  local dest="$HOME/$name"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    mv "$dest" "$dest.backup.$(date +%s)"
    echo "    backed up existing $dest"
  fi
  ln -sfn "$src" "$dest"
  echo "    linked  $dest -> $src"
}
link .zshrc
link .p10k.zsh
link .gitconfig

echo "==> [7/7] Make zsh the default shell"
if [ "${SHELL:-}" != "$(command -v zsh)" ]; then
  chsh -s "$(command -v zsh)" || \
    echo "    chsh failed — run manually: chsh -s $(command -v zsh)"
fi

cat <<'EOF'

✅ Done. A few things you must still do by hand:

  1. Install a Nerd Font (the prompt icons need it), e.g. MesloLGS NF:
     https://github.com/romkatv/powerlevel10k#fonts
     Then select that font in your terminal emulator's settings.

  2. Edit ~/.gitconfig — set your real name and email (it ships with a
     placeholder identity).

  3. Open a new terminal, or run:  exec zsh

Notes:
  - The omz plugins `jj` and `bun` only add completions/aliases. If you don't
    have jujutsu (jj) or bun installed, zsh may print a harmless warning.
    Install them if you use them:  brew install jj  /  brew install bun
EOF
