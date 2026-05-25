# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Personal dotfiles backup + full-machine provisioning for **Ubuntu 26.04 ("resolute", arm64)**.
Everything here is Bash + config files — there is no build system, test suite, or linter.

## Commands
- `bash install.sh` — lightweight bootstrap: **shell + dotfiles only** (zsh, oh-my-zsh, p10k, core brew CLI, symlinks).
- `bash provision/provision.sh --dry-run` — **the verification path**. Prints every planned action, makes no changes, needs no sudo. Run this after editing any step script.
- `sudo bash provision/provision.sh` — full machine replication. `sudo PROVISION_USER=alice bash …` targets a user; `sudo INSTALL_DESKTOP=1 bash …` adds the desktop/locale/IME set.
- `bash provision/inventory-export.sh` — run on the **source** machine to regenerate `packages/{apt.list,flatpak.list,Brewfile}` from live state.
- Scripts are **not** executable — always invoke with `bash <script>`. Lint with `bash -n <script>` / `shellcheck` if available.

## Layout
- `.zshrc`, `.p10k.zsh`, `.gitconfig` — the dotfiles (symlinked into `$HOME`).
- `install.sh` — lightweight bootstrap (see Commands).
- `provision/` — **canonical** full-machine replication. `provision.sh` is the entrypoint; numbered step scripts in `provision/steps/` (run 10→60), package lists in `provision/packages/`, shared helpers in `provision/lib.sh`. Details in `provision/README.md`.

## Architecture
`provision.sh` sources `lib.sh`, then runs `steps/*.sh` in numeric order, tolerating per-step failure and printing a summary. Order is load-bearing: 10-apt (base) → 20-apt-third-party (Docker/VSCodium/Cursor repos) → 25-docker-rootless (only `DOCKER_ROOTLESS=1`) → 30-brew → 35-rust (rustup) → 36-alacritty (`cargo install` + desktop integration + shell completions + vendored MesloLGS NF font) → 37-claude-code (native installer, stable channel) → 50-flatpak (adds Flathub remote) → 55-gnome-dconf (desktop-only) → 60-shell → 90-finalize (only `GOLDEN_IMAGE=1`). There is **no snap step** — Alacritty (the only user snap) is built via cargo, so the machine needs no snapd.

`lib.sh` resolves a non-root `TARGET_USER` because cloud-init runs as root but **Homebrew, oh-my-zsh, rustup, and Claude Code refuse to / shouldn't run as root** — those steps drop to that user via `as_user` (a `sudo -u … bash -lc` login shell). An explicitly-set `PROVISION_USER` **must exist or `lib.sh` dies** (catches a cloud-init typo before provisioning the wrong account; `--dry-run` only warns). Unset, it falls back `SUDO_USER` > uid 1000 > `ubuntu`.

### Editing step scripts — the helper contract
Every mutating action must go through a `lib.sh` helper so `--dry-run` stays accurate and runs stay non-interactive/idempotent. **Calling `apt-get`, `curl … | sudo tee`, etc. directly silently breaks `--dry-run`.**
- `run <cmd>` — runs a plain command, or prints `[would] …` under dry-run.
- `apt_get <args>` / `apt_install <pkgs>` — non-interactive apt (returns real status / tolerant). Wrapped in `env` so noninteractive+needrestart survive `sudo`, with `--force-conf*` and `DPkg::Lock::Timeout=600`.
- `as_user <cmd>` — run as `$TARGET_USER` via login shell (brew, oh-my-zsh, dotfile symlinks).
- For anything with pipes/redirects (key downloads, repo files), guard manually: `if dry; then would "…"; else …; fi`.
- `log`/`warn`/`die` for output; `dry`, `is_root`, `$SUDO`, `load_brew` are also provided.

### Ported dotfiles & configs
Both `install.sh` and step 60 install a shared set into `$HOME` — the file set is listed **once** in `dotfiles.list` at the repo root (single source of truth both read, so they can't drift): `.zshrc`, `.p10k.zsh`, `.gitconfig`, `.tmux.conf`, `.config/alacritty/alacritty.toml`, `.config/nvim/` (whole LazyVim tree; `lazy-lock.json` excluded so plugins track latest), and `.claude/{settings.json,statusline-command.sh}` (the repo mirrors `$HOME` layout; nested parents created; manifest entries may be files or whole directories). Default is **symlink** (repo stays source of truth); `DOTFILES_COPY=1` / `install.sh --copy` / `GOLDEN_IMAGE=1` **copy** instead (self-contained). The Alacritty theme repo is **cloned, not vendored** (step 36 / install.sh → `~/.config/alacritty/themes`). The **MesloLGS NF** Nerd Font, by contrast, **is** vendored (`fonts/MesloLGS-NF/` — no apt/brew package exists for it on Linux/arm64, and alacritty.toml pins it as the font family), copied into place system-wide by step 36 and into `~/.local/share/fonts` by install.sh (`.gitleaks.toml` allowlists the binary `.ttf` path). GNOME settings live in `provision/gnome/dconf-settings.ini`, applied by step 55 via `dconf load` **only when `INSTALL_DESKTOP=1`**. `.gitignore` keeps `.claude/` ignored *except* those two tracked files, and blocks the AI/API token files the config audit surfaced (`**/auth.json`, `**/.credentials.json`, `.claude.json`, `.codex/`, etc.). Configs with hardcoded `/home/<user>` paths are templated to `$HOME` so they survive a different target username.

### Modes (env flags)
- `--dry-run`/`-n` — preview only, no changes, no sudo, no network.
- `INSTALL_DESKTOP=1` — also install the desktop/locale/IME apt set + run the GNOME dconf step (55).
- `GOLDEN_IMAGE=1` — build a reusable image: implies **STRICT** (first real failure aborts), step 60 **copies** dotfiles instead of symlinking (self-contained), and the **finalize** step (90) resets machine-id / SSH host keys / cloud-init state / logs / history. Destructive — throwaway build box only.
- `DOTFILES_COPY=1` (or `install.sh --copy`) — copy dotfiles into `$HOME` instead of symlinking, *without* the rest of golden-image mode (`GOLDEN_IMAGE` implies it).
- `DOCKER_ROOTLESS=1` — set up rootless Docker for `TARGET_USER` (step 25): runs the official `dockerd-rootless-setuptool.sh` as the user, enables linger + the `--user` service, and sets the `rootless` context. Needs the step-20 prereqs (`uidmap`, `docker-ce-rootless-extras`, `dbus-user-session`) and **unprivileged user namespaces** (host-dependent — soft-fails where userns is restricted; rootful Docker still works). Do **not** also `usermod -aG docker` (that's the root-equivalent rootful path).
- Failure handling: tolerant helpers call `soft_fail` → warns + records to `$SOFT_FAIL_LOG`; a normal run completes every step but **exits non-zero** if any soft failure occurred. Under `STRICT`/`GOLDEN_IMAGE`, `soft_fail` and a failing step **die** immediately. `lib.sh` refuses a root/uid-0 `TARGET_USER`.

## Conventions / gotchas
- `provision.sh` is cloud-init-ready: root, idempotent, failure-tolerant. `--dry-run` previews with no changes and no sudo.
- Step 10 filters boot/kernel/third-party/desktop out of `apt.list` at install time (the list is the full `apt-mark showmanual` set on purpose); step 20 owns Docker/VSCodium/Cursor in **key → verify → repo → install** order — those packages have no repo at step 10. The repo add + install are **gated on a valid signing key** (`verify_keyring`): Docker, Cursor, and VSCodium fingerprints are all pinned (`DOCKER_FP`/`CURSOR_FP`/`VSCODIUM_KEY_FP`, each verified against the live key). A failed/mismatched key `soft_fail`s and skips that vendor rather than adding a half-configured repo. (Bruno was removed from the project — use httpie / VSCodium extensions instead.)
- Step 30 filters the `Brewfile` to `tap`/`brew`/`cask` lines; `flatpak`/`npm`/`mas`/`vscode` entries from `brew bundle dump` are dropped (flatpaks are owned by `flatpak.list`).
- `bat` must come from **brew** (binary `bat`); apt's is `batcat` and breaks `.zshrc`'s `alias cat="bat"`.
- **Casks are kept** in the Brewfile — Linux-capable casks (e.g. `codex`) install on linuxbrew arm64; macOS-only casks fail-soft.
- Arch-aware fallbacks: Docker codename falls back to `noble`. Cursor uses its signed apt repo (`downloads.cursor.com/aptrepo`, suite `stable`, both arches — codename-agnostic).
- Homebrew is hardcoded at `/home/linuxbrew/.linuxbrew`. The omz `jj`/`bun` plugins only add completions; a missing tool just warns.
- **Never committed** (see `.gitignore`): SSH/GPG keys, `~/.claude/`, cloud creds, shell history. `.gitconfig` ships a placeholder identity — set the real one.
- **Secret scanning** (defense-in-depth beyond the filename-based `.gitignore`): `gitleaks` (in the Brewfile) scans content. A versioned pre-commit hook lives in `.githooks/` — enable per clone with `git config core.hooksPath .githooks`. CI runs `.github/workflows/gitleaks.yml` on push/PR. `.gitleaks.toml` allowlists the pinned public key fingerprints (Docker/Cursor/VSCodium). The hook prefers `gitleaks git --staged`; CI scans full history.

## Open TODOs
- [ ] **Live smoke-test on a real arm64 box** — none of the mutating paths have been run live (only dry-run + `shellcheck`): `cargo install alacritty`, the Claude native installer, `rustup`, `dconf load` + the finalize step, the Cursor signed-repo install, rootless Docker (`DOCKER_ROOTLESS=1` — needs unprivileged userns; the headless setuptool + linger path is the least-exercised), the vendored MesloLGS NF font copy + `fc-cache` (step 36 → `/usr/local/share/fonts`, `install.sh` → `~/.local/share/fonts`), the Alacritty shell-completions fetch (step 36 — needs the `alacritty --version` probe + GitHub `extra/completions` for that tag), the cargo-registry-cache prune (step 90), and a full `sudo GOLDEN_IMAGE=1 bash provision/provision.sh`.

## Project direction & philosophy
- **Two entry points, both first-class:** `install.sh` = lightweight shell+dotfiles on an *existing* box; `provision/` = full machine / cloud-init / golden image. They share the dotfile set via `dotfiles.list`.
- **Bring-to-latest is intentional, not a gap:** brew / `cargo install` / `rustup` / Claude+Cursor stable channels all float. "Reproducible" here means *re-runnable to the same state* (idempotent), **not** version-pinned. Don't add default version pins — bit-for-bit pinning, if ever wanted, belongs at a future **packer** layer.
- **The repo's dual role is permanent** (even after a possible future packer + chezmoi split): (1) fresh Ubuntu → clean, cred-free state — no golden image is built from the owner's daily box because it holds creds; (2) a re-runnable "bring-to-latest" layer on top of an existing golden image to keep it current.
- **No creds/PII ever** — enforced by `.gitignore` + the package-names-only `inventory-export.sh`.
