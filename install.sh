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
# machine replication (Docker, VSCodium, Cursor, Rust+Alacritty, Flatpak,
# the whole Brewfile, cloud-init support) use provision/provision.sh instead.
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Link vs. override: symlink the dotfiles by default (repo stays the source of
# truth), or copy them in with DOTFILES_COPY=1 / --copy (self-contained — the
# repo can then be deleted, but edits no longer flow back). Same knob as
# provision's GOLDEN_IMAGE/DOTFILES_COPY.
DOTFILES_COPY="${DOTFILES_COPY:-0}"
for a in "$@"; do
  case "$a" in
    --copy) DOTFILES_COPY=1 ;;
    -h|--help) echo "usage: [DOTFILES_COPY=1] bash install.sh [--copy]"; exit 0 ;;
    *) echo "unknown argument: $a (try --help)" >&2; exit 2 ;;
  esac
done

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

echo "==> [5/7] CLI tools via brew (nvm, eza, bat, zoxide, jq)"
# Installed via brew on purpose: brew's 'bat' binary is named `bat`, so the
# `alias cat="bat"` in .zshrc works. Ubuntu's apt 'bat' is named `batcat`.
# jq is required by the Claude Code statusline script symlinked below.
brew install nvm eza bat zoxide jq
mkdir -p "$HOME/.nvm"   # required by brew's nvm

echo "==> [6/7] Install dotfiles (+ Alacritty theme) into \$HOME ($([ "$DOTFILES_COPY" = 1 ] && echo copy || echo symlink) mode)"
link() {
  local name="$1"
  case "$name" in ""|/*|*..*) echo "    skip (unsafe dotfiles.list entry): $name"; return ;; esac
  local src="$DOTFILES_DIR/$name"
  local dest="$HOME/$name"
  [ -e "$src" ] || { echo "    skip (missing in repo): $name"; return; }
  mkdir -p "$(dirname "$dest")"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    mv "$dest" "$dest.backup.$(date +%s)"
    echo "    backed up existing $dest"
  fi
  if [ "$DOTFILES_COPY" = "1" ]; then
    rm -rf "$dest"; cp -a "$src" "$dest"   # -a/-rf so files AND dirs (e.g. nvim) work
    echo "    copied  $dest <- $src"
  else
    ln -sfn "$src" "$dest"                 # dir-capable (replaces an existing symlink)
    echo "    linked  $dest -> $src"
  fi
}
# File set = the shared manifest at the repo root (also read by provision step 60).
mapfile -t _dotfiles < <(grep -vE '^[[:space:]]*(#|$)' "$DOTFILES_DIR/dotfiles.list")
for f in "${_dotfiles[@]}"; do link "$f"; done

# Alacritty's alacritty.toml imports a theme from this repo (don't vendor ~190 files).
# Skip if already a checkout; clone if empty/missing; leave a non-empty non-git
# dir alone (could be your own themes).
themes_dir="$HOME/.config/alacritty/themes"
if [ -d "$themes_dir/.git" ]; then
  :  # already a theme checkout
elif [ -e "$themes_dir" ] && [ -n "$(ls -A "$themes_dir" 2>/dev/null)" ]; then
  echo "    alacritty themes dir exists and isn't a git checkout — leaving it"
else
  rm -rf "$themes_dir"
  git clone --depth=1 https://github.com/alacritty/alacritty-theme "$themes_dir" 2>/dev/null \
    && echo "    cloned alacritty themes" \
    || echo "    (alacritty theme clone failed)"
fi
[ -f "$themes_dir/themes/catppuccin_mocha.toml" ] || \
  echo "    note: alacritty theme catppuccin_mocha.toml missing — alacritty.toml import will fail"

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
