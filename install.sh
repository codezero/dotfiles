#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# Bootstrap a fresh Ubuntu (24.04 / 26.04) machine to use these dotfiles.
# Installs every prerequisite the .zshrc expects, then symlinks the dotfiles
# from this repo into $HOME.
#
# Run from inside the cloned repo:   bash install.sh
# Run it as YOURSELF, not under sudo — it sudo's only where it needs to (apt,
# Homebrew). If you tee/redirect the output, note step [0/7]: sudo prompts on
# the tty but prints to stderr, so an un-primed run can look like a silent hang.
# Safe to re-run (idempotent). Existing real files are backed up, not deleted.
#
# SCOPE: this is the lightweight "shell + dotfiles" bootstrap (zsh, oh-my-zsh,
# Powerlevel10k, the core brew CLI tools, and the dotfile symlinks). For a FULL
# machine replication (Docker, VSCodium, Cursor, Rust+Alacritty, Flatpak,
# the whole Brewfile, cloud-init support) use provision/provision.sh instead.
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The commits/hashes of every script and clone this bootstrap executes, plus
# clone_pinned/fetch_pinned — one owner, shared with provision/ (TODO J).
# shellcheck source=provision/pins.sh
source "$DOTFILES_DIR/provision/pins.sh"

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

# Prime the sudo timestamp in the FOREGROUND before anything else. Two reasons:
#  1. The password prompt then appears here, not minutes later inside apt or the
#     Homebrew installer. That matters because sudo writes its prompt to stderr
#     but reads the password from /dev/tty — so a run whose output is redirected
#     to a log file (`bash install.sh > log 2>&1`) looks like a SILENT HANG: the
#     prompt is sitting in the log while sudo waits on the terminal.
#  2. Fail fast with a clear message if this user can't sudo at all, instead of
#     a confusing apt error.
# NB: step [7/7]'s `chsh` prompts for YOUR OWN password via PAM regardless — that
# one is unrelated to sudo and cannot be primed away.
# Root is needed in exactly two places: apt ([1/7]) and Homebrew's FIRST install
# ([2/7] — its installer sudo's internally to create /home/linuxbrew). Everything
# else is user-level. So a CONVERGED box re-runs with no password at all: prime
# sudo only when one of those two actually has work to do. (Found live, S10
# re-run 2026-09-12: a re-run that stalls on a prompt has demonstrated nothing
# about idempotency, whatever the backup count says afterwards.)
APT_PKGS=(zsh git curl wget build-essential tmux zsh-autosuggestions zsh-syntax-highlighting)
# ^ tmux: we install .tmux.conf from dotfiles.list AND .zshrc loads omz's `tmux`
#   plugin, which prints "tmux not found. Please install tmux before using this
#   plugin." on every shell start when it's missing. Shipping the config without
#   the binary was incoherent (found live, S10).
# ^ zsh-autosuggestions & zsh-syntax-highlighting land in /usr/share/...,
#   which is exactly where .zshrc sources them from.
apt_needed=0
for p in "${APT_PKGS[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || apt_needed=1
done
brew_needed=0
[ -x /home/linuxbrew/.linuxbrew/bin/brew ] || command -v brew >/dev/null 2>&1 || brew_needed=1

if [ "$apt_needed" = 1 ] || [ "$brew_needed" = 1 ]; then
  echo "==> [0/7] sudo access (needed for apt + Homebrew's first install)"
  sudo -v || { echo "    this script needs sudo (apt + Homebrew) — aborting" >&2; exit 1; }
else
  echo "==> [0/7] sudo access — skipped: apt set + Homebrew already present, nothing needs root"
fi

if [ "$apt_needed" = 1 ]; then
  echo "==> [1/7] Base apt packages"
  sudo apt update
  sudo apt install -y "${APT_PKGS[@]}"
else
  # No `apt update` either: install.sh is not the bring-to-latest path (that is
  # provision.sh with APT_UPGRADE=1), and refreshing the index is root work.
  echo "==> [1/7] Base apt packages — all ${#APT_PKGS[@]} present, skipped"
fi

echo "==> [2/7] Homebrew (linuxbrew)"
if [ ! -x /home/linuxbrew/.linuxbrew/bin/brew ] && ! command -v brew >/dev/null 2>&1; then
  # Installer fetched at a pinned commit and verified before it runs (pins.sh).
  hb_installer="$(mktemp)"
  fetch_pinned "$HOMEBREW_INSTALL_URL" "$HOMEBREW_INSTALL_SHA256" "$hb_installer" \
    || { echo "    Homebrew installer could not be verified — aborting (see provision/pins.sh)" >&2; exit 1; }
  NONINTERACTIVE=1 /bin/bash "$hb_installer"; rm -f "$hb_installer"
fi
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

echo "==> [3/7] oh-my-zsh"
export ZSH="${ZSH:-$HOME/.oh-my-zsh}"
# A pinned clone (pins.sh OMZ_SHA) replaces the installer script from master;
# our .zshrc is never touched and chsh is step [7/7]'s. Every run: at the pin
# this is a no-op, otherwise the checkout is moved to the pin (2026-09-21).
clone_pinned "$OMZ_URL" "$OMZ_SHA" "$ZSH" \
  || { echo "    oh-my-zsh clone/converge failed (see provision/pins.sh)" >&2; exit 1; }
[ -f "$ZSH/oh-my-zsh.sh" ] || { echo "    oh-my-zsh incomplete: $ZSH/oh-my-zsh.sh missing" >&2; exit 1; }

echo "==> [4/7] Powerlevel10k theme"
ZSH_CUSTOM="${ZSH_CUSTOM:-$ZSH/custom}"
clone_pinned "$P10K_URL" "$P10K_SHA" "$ZSH_CUSTOM/themes/powerlevel10k" \
  || { echo "    powerlevel10k clone/converge failed (see provision/pins.sh)" >&2; exit 1; }
[ -f "$ZSH_CUSTOM/themes/powerlevel10k/powerlevel10k.zsh-theme" ] \
  || { echo "    powerlevel10k incomplete: powerlevel10k.zsh-theme missing" >&2; exit 1; }

echo "==> [5/7] CLI tools via brew (mise, eza, bat, zoxide, jq)"
# Installed via brew on purpose: brew's 'bat' binary is named `bat`, so the
# `alias cat="bat"` in .zshrc works. Ubuntu's apt 'bat' is named `batcat`.
# jq is required by the Claude Code statusline script symlinked below.
# mise manages runtimes (node/python/go…): `mise use -g` writes
# ~/.config/mise/config.toml, a project's mise.toml layers on top. It replaced
# nvm 2026-09-11 — one tool instead of one per language, built-in core plugins.
brew install mise eza bat zoxide jq

echo "==> [6/7] Install dotfiles (+ Alacritty theme) into \$HOME ($([ "$DOTFILES_COPY" = 1 ] && echo copy || echo symlink) mode)"
# The dotfile policy (manifest, identical-content skip, backup-once, copy vs
# symlink, symlinked-parent refusal) lives in dotfiles-install.sh — ONE
# implementation shared with provision step 60, which runs it as the target
# user (2026-09-22). This script already runs as the user, so it calls it.
_di_args=(--src "$DOTFILES_DIR"); [ "$DOTFILES_COPY" = 1 ] && _di_args+=(--copy)
bash "$DOTFILES_DIR/dotfiles-install.sh" "${_di_args[@]}" \
  || { echo "    dotfile install reported failures (see above)" >&2; exit 1; }

# Alacritty's alacritty.toml imports a theme from this repo (don't vendor ~190 files).
# Every run: clone_pinned is a no-op at the pin, moves an existing checkout to
# the pin, clones if empty/missing, and refuses (never wipes) a non-empty
# non-git dir — which could be your own themes; its message says so.
themes_dir="$HOME/.config/alacritty/themes"
clone_pinned "$ALACRITTY_THEME_URL" "$ALACRITTY_THEME_SHA" "$themes_dir" \
  && echo "    alacritty themes at the pinned commit" \
  || echo "    (alacritty theme clone/converge failed — see provision/pins.sh)"
[ -f "$themes_dir/themes/catppuccin_mocha.toml" ] || \
  echo "    note: alacritty theme catppuccin_mocha.toml missing — alacritty.toml import will fail"

# MesloLGS NF — the Nerd Font p10k (nerdfont-v3) and alacritty.toml's font family
# both expect. A fresh Ubuntu doesn't ship it; without it prompt/TUI glyphs are
# tofu. The TTFs are vendored in the repo (fonts/MesloLGS-NF) — copy them into the
# user font dir (no network). Idempotent.
font_src="$DOTFILES_DIR/fonts/MesloLGS-NF"
font_dir="$HOME/.local/share/fonts"
if [ -d "$font_src" ]; then
  echo "    installing MesloLGS NF (vendored Nerd Font) into $font_dir"
  mkdir -p "$font_dir"
  cp -f "$font_src"/*.ttf "$font_dir/" || echo "    (failed to copy MesloLGS NF)"
  command -v fc-cache >/dev/null 2>&1 && fc-cache -f "$font_dir" >/dev/null 2>&1 || true
else
  echo "    note: vendored fonts dir missing ($font_src) — install MesloLGS NF manually"
fi

echo "==> [7/7] Make zsh the default shell"
# Gate on the passwd entry, NOT $SHELL: $SHELL is the CURRENT session's value
# and only changes at login, so after a successful chsh a re-run in the same
# terminal would prompt for the password again for nothing (found live, S10
# re-run 2026-09-12). getent is the source of truth; $SHELL is the fallback.
login_shell="$(getent passwd "$USER" 2>/dev/null | cut -d: -f7)"
login_shell="${login_shell:-${SHELL:-}}"
if [ "$login_shell" != "$(command -v zsh)" ]; then
  # chsh authenticates YOU via PAM — it prompts for your own password (bare
  # "Password:", not "[sudo] password for …"). Expected, and not primeable.
  # Say so right before it happens: with sudo's timestamp still fresh from an
  # earlier command, this can be the ONLY prompt of the run, and it was read
  # as a sudo prompt live (wrong password -> PAM failure -> bash stayed).
  echo "    chsh asks for YOUR login password (not sudo's) — answer the next prompt:"
  chsh -s "$(command -v zsh)" || \
    echo "    chsh failed — run manually: chsh -s $(command -v zsh)"
else
  echo "    already zsh — skipped"
fi

cat <<'EOF'

✅ Done. A few things you must still do by hand:

  1. MesloLGS NF (Nerd Font) was installed for you (~/.local/share/fonts).
     Alacritty already uses it; in any OTHER terminal, select "MesloLGS NF"
     in its font settings. (provision.sh words this differently on a desktop
     box because it also points GNOME's monospace font at the font — this
     script installs no desktop, so nothing picks it up for you here.)

  2. Edit ~/.gitconfig — set your real name and email (it ships with a
     placeholder identity).

  3. Open a new terminal, or run:  exec zsh

Notes:
  - .zshrc loads oh-my-zsh plugins for tools this lightweight bootstrap does
    NOT install (golang, httpie, rust, docker, docker-compose, jj).
    Those plugins only add completions/aliases and stay quiet when the
    binary is absent — verified on a fresh box. Install what you actually use
    (`brew install jj`), or trim the plugins=() line in .zshrc.
    For the full set, use provision/provision.sh instead.
EOF
