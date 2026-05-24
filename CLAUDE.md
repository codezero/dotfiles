# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Personal dotfiles backup + full-machine provisioning for **Ubuntu 26.04 ("resolute", arm64)**.
Everything here is Bash + config files — there is no build system, test suite, or linter.

## Commands
- `bash install.sh` — lightweight bootstrap: **shell + dotfiles only** (zsh, oh-my-zsh, p10k, core brew CLI, symlinks).
- `bash provision.sh --dry-run` — **the verification path**. Prints every planned action, makes no changes, needs no sudo. Run this after editing any step script.
- `sudo bash provision.sh` — full machine replication. `sudo PROVISION_USER=alice bash …` targets a user; `sudo INSTALL_DESKTOP=1 bash …` adds the desktop/locale/IME set.
- `bash provision/inventory-export.sh` — run on the **source** machine to regenerate `packages/{apt.list,flatpak.list,Brewfile}` from live state.
- Scripts are **not** executable — always invoke with `bash <script>`. Lint with `bash -n <script>` / `shellcheck` if available.

## Layout
- `.zshrc`, `.p10k.zsh`, `.gitconfig` — the dotfiles (symlinked into `$HOME`).
- `install.sh` — lightweight bootstrap (see Commands).
- `provision/` — **canonical** full-machine replication. `provision.sh` is the entrypoint; numbered step scripts in `provision/steps/` (run 10→60), package lists in `provision/packages/`, shared helpers in `provision/lib.sh`. Details in `provision/README.md`.

## Architecture
`provision.sh` sources `lib.sh`, then runs `steps/*.sh` in numeric order, tolerating per-step failure and printing a summary. Order is load-bearing: 10-apt (base) → 20-apt-third-party (Docker/VSCodium/Bruno/Cursor repos) → 30-brew → 35-rust (rustup) → 36-alacritty (`cargo install` + desktop integration) → 37-claude-code (native installer, stable channel) → 50-flatpak (adds Flathub remote) → 55-gnome-dconf (desktop-only) → 60-shell. There is **no snap step** — Alacritty (the only user snap) is built via cargo, so the machine needs no snapd.

`lib.sh` resolves a non-root `TARGET_USER` because cloud-init runs as root but **Homebrew, oh-my-zsh, rustup, and Claude Code refuse to / shouldn't run as root** — those steps drop to that user via `as_user` (a `sudo -u … bash -lc` login shell). An explicitly-set `PROVISION_USER` **must exist or `lib.sh` dies** (catches a cloud-init typo before provisioning the wrong account; `--dry-run` only warns). Unset, it falls back `SUDO_USER` > uid 1000 > `ubuntu`.

### Editing step scripts — the helper contract
Every mutating action must go through a `lib.sh` helper so `--dry-run` stays accurate and runs stay non-interactive/idempotent. **Calling `apt-get`, `curl … | sudo tee`, etc. directly silently breaks `--dry-run`.**
- `run <cmd>` — runs a plain command, or prints `[would] …` under dry-run.
- `apt_get <args>` / `apt_install <pkgs>` — non-interactive apt (returns real status / tolerant). Wrapped in `env` so noninteractive+needrestart survive `sudo`, with `--force-conf*` and `DPkg::Lock::Timeout=600`.
- `as_user <cmd>` — run as `$TARGET_USER` via login shell (brew, oh-my-zsh, dotfile symlinks).
- For anything with pipes/redirects (key downloads, repo files), guard manually: `if dry; then would "…"; else …; fi`.
- `log`/`warn`/`die` for output; `dry`, `is_root`, `$SUDO`, `load_brew` are also provided.

### Ported dotfiles & configs
Both `install.sh` and step 60 symlink a shared set into `$HOME`: `.zshrc`, `.p10k.zsh`, `.gitconfig`, `.config/alacritty/alacritty.toml`, and `.claude/{settings.json,statusline-command.sh}` (the repo mirrors `$HOME` layout; nested parents are created). The Alacritty theme repo is **cloned, not vendored** (step 36 / install.sh → `~/.config/alacritty/themes`). GNOME settings live in `provision/gnome/dconf-settings.ini`, applied by step 55 via `dconf load` **only when `INSTALL_DESKTOP=1`**. `.gitignore` keeps `.claude/` ignored *except* those two tracked files, and blocks the AI/API token files the config audit surfaced (`**/auth.json`, `**/.credentials.json`, `.claude.json`, `.codex/`, bruno cookies, etc.). Configs with hardcoded `/home/<user>` paths are templated to `$HOME` so they survive a different target username.

## Conventions / gotchas
- `provision.sh` is cloud-init-ready: root, idempotent, failure-tolerant. `--dry-run` previews with no changes and no sudo.
- Step 10 filters boot/kernel/third-party/desktop out of `apt.list` at install time (the list is the full `apt-mark showmanual` set on purpose); step 20 owns Docker/VSCodium/Bruno/Cursor in **key → repo → install** order — those packages have no repo at step 10.
- Step 30 filters the `Brewfile` to `tap`/`brew`/`cask` lines; `flatpak`/`npm`/`mas`/`vscode` entries from `brew bundle dump` are dropped (flatpaks are owned by `flatpak.list`).
- `bat` must come from **brew** (binary `bat`); apt's is `batcat` and breaks `.zshrc`'s `alias cat="bat"`.
- **Casks are kept** in the Brewfile — Linux-capable casks (e.g. `codex`) install on linuxbrew arm64; macOS-only casks fail-soft.
- Arch-aware fallbacks: Docker codename falls back to `noble`; Bruno's apt repo is amd64-only so arm64 pulls a GitHub `arm64` .deb; Cursor uses its download API (`linux-arm64`/`linux-x64`).
- `.deb` downloads (Cursor/Bruno) use `mktemp` (0600), not predictable `/tmp` paths, to avoid a TOCTOU swap of the file apt installs as root.
- Homebrew is hardcoded at `/home/linuxbrew/.linuxbrew`. The omz `jj`/`bun` plugins only add completions; a missing tool just warns.
- **Never committed** (see `.gitignore`): SSH/GPG keys, `~/.claude/`, cloud creds, shell history. `.gitconfig` ships a placeholder identity — set the real one.

## Open TODOs
- [ ] Smoke-test Cursor + Bruno install on a real arm64 box (URL parsing was hardened but not run live).
