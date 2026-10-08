# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set name of the theme to load --- if set to "random", it will
# load a random theme each time Oh My Zsh is loaded, in which case,
# to know which specific one was loaded, run: echo $RANDOM_THEME
# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
ZSH_THEME="powerlevel10k/powerlevel10k"

# oh-my-zsh is a PINNED checkout (provision/pins.sh OMZ_SHA). Remind, never
# act: the pin is bumped in the repo instead (TODO J, 2026-09-13), and every 30
# days matches the monthly cadence. The `omz update` command itself is routed
# to that bump below (after oh-my-zsh.sh defines `omz`).
zstyle ':omz:update' mode reminder
zstyle ':omz:update' frequency 30

# Plugins only add completions/aliases; each stays quiet when its binary is
# missing (verified on a fresh box), except tmux — install.sh installs tmux
# for that reason. kubectl and bun were dropped 2026-09-13: no profile installs
# either binary (re-add with the tool). Everything below the theme that oh-my-zsh's
# template ships commented out was removed the same day; `omz` reads variables,
# not comments — the template is at $ZSH/templates/zshrc.zsh-template.
plugins=(git golang httpie jj rust tmux alias-finder docker docker-compose)

source $ZSH/oh-my-zsh.sh

# `omz update` is not the way on a pinned checkout: it would make omz a second
# owner of code the repo pins (and fails here anyway — clone_pinned leaves no
# local master branch, and the updater starts with `git checkout master`). Route
# it to the repo's bump, which shows the upstream log, rewrites the pin,
# converges this checkout, and leaves a commit to review (2026-09-21).
if (( $+functions[omz] )); then
  functions[_omz_upstream]=$functions[omz]
  omz() {
    if [[ $1 == update ]]; then
      print -u2 "oh-my-zsh is PINNED by the dotfiles repo (provision/pins.sh OMZ_SHA); its updater is not the owner."
      print -u2 "Bump it in the repo instead:  bash <dotfiles>/provision/pins.sh bump omz   (shows the log, rewrites the pin, converges ~/.oh-my-zsh; then commit)"
      return 1
    fi
    _omz_upstream "$@"
  }
fi

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
export CLAUDE_CODE_NO_FLICKER=1
[ -x /home/linuxbrew/.linuxbrew/bin/brew ] && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"

# Rust toolchain (rustup) — installed per-user under ~/.cargo (provision step 35).
[ -s "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# Editor: git/gh/jj/crontab/`sudo -e` fall back to nano when this is unset —
# both were empty on the box (found on-box 2026-09-13). nvim is full-Brewfile
# only, so fall through to vim/vi on a lean box. Sits AFTER brew shellenv:
# nvim is a brew binary and is not on PATH before that line.
for _e in nvim vim vi; do
  command -v "$_e" >/dev/null && { export EDITOR="$_e" VISUAL="$_e"; break; }
done; unset _e

# Niceties — each guarded so a lean box (provision PROFILE=minimal installs
# no bat/eza/zoxide/atuin) gets a clean shell instead of "command not found" noise.
command -v eza    >/dev/null && alias ls="eza --icons=always"
command -v zoxide >/dev/null && eval "$(zoxide init zsh)"
# BAT_THEME rather than bat's config file: delta honours the same variable, so
# `cat`, `git diff` and lazygit share the terminal palette. The alias never
# pages; a direct `bat file` still does (paging stays auto in .config/bat/config).
command -v bat    >/dev/null && { export BAT_THEME="Catppuccin Mocha"; alias cat="bat --paging=never"; }
# fzf keybindings + completion: Ctrl-T (files), Alt-C (cd), `**<Tab>`. Sourced
# BEFORE atuin so atuin keeps Ctrl-R (last binding wins). `--zsh` needs fzf
# >= 0.48 — brew is current; the 2>/dev/null makes an older fzf a silent no-op.
# fd-backed sources when fd is present: hidden files show, .git is skipped.
if command -v fzf >/dev/null; then
  eval "$(fzf --zsh 2>/dev/null)"
  if command -v fd >/dev/null; then
    export FZF_DEFAULT_COMMAND='fd --type f --hidden --strip-cwd-prefix --exclude .git'
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_ALT_C_COMMAND='fd --type d --hidden --strip-cwd-prefix --exclude .git'
  fi
fi
# atuin takes Ctrl-R (inline fuzzy history search — .config/atuin/config.toml);
# --disable-up-arrow keeps zsh's native up-arrow. Its DB lives in
# ~/.local/share/atuin — finalize scrubs it.
command -v atuin  >/dev/null && eval "$(atuin init zsh --disable-up-arrow)"
# mise: runtimes (node/python/go…) — `mise use -g node@lts` writes the global
# source, ~/.config/mise/config.toml; a project's own mise.toml layers on top.
# Interactive activation only; for node in non-interactive shells put
# ~/.local/share/mise/shims on PATH (see ~/PROVISION-NEXT-STEPS.md).
command -v mise   >/dev/null && eval "$(mise activate zsh)"

[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] && \
  source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && \
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

zstyle ':omz:plugins:alias-finder' autoload yes
zstyle ':omz:plugins:alias-finder' longer yes
zstyle ':omz:plugins:alias-finder' exact yes
zstyle ':omz:plugins:alias-finder' cheaper yes
export PATH="$HOME/.local/bin:$PATH"
