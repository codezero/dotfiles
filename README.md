# dotfiles

Personal shell environment: Zsh + oh-my-zsh + Powerlevel10k on a Homebrew toolchain.

## What's in here

| Path | Purpose |
|------|---------|
| `.zshrc` | Zsh config: oh-my-zsh, plugins, aliases, brew/nvm/zoxide |
| `.p10k.zsh` | Powerlevel10k prompt (from `p10k configure`) |
| `.gitconfig` | Git identity — **set your real name/email** |
| `.config/`, `.claude/` | Ported app configs symlinked into `$HOME`: Alacritty (`alacritty.toml` + cloned theme repo), Claude Code (`settings.json`, `statusline-command.sh`) |
| `dotfiles.list` | Manifest of the files installed into `$HOME` — single source of truth shared by `install.sh` and provision step 60 |
| `.gitignore` | Keeps secrets/credentials out of the repo |
| `install.sh` | Lightweight bootstrap: shell + dotfiles only |
| `provision/` | Full-machine replication (Docker, editors, Rust+Alacritty, Flatpak, Brewfile); cloud-init ready |

> **Never committed:** SSH/GPG keys, `~/.claude/`, cloud creds, shell history
> (see `.gitignore`). `.bashrc` is the stock Ubuntu default, so it's omitted.

> **Secret scanning:** `gitleaks` backs up the `.gitignore` with content-based
> detection. Enable the local pre-commit hook once per clone:
> `git config core.hooksPath .githooks` (needs `gitleaks` — it's in the Brewfile).
> CI also scans every push via `.github/workflows/gitleaks.yml`.

## Two ways to use it

- **Just my shell on an existing box** → `install.sh` (below).
- **Replicate the whole machine / cloud-init** → [`provision/`](provision/README.md).

## Quick start (install.sh)

```bash
git clone <your-repo-url> ~/dotfiles
cd ~/dotfiles
bash install.sh        # not chmod +x in the repo, so invoke with bash
exec zsh
```

Installs zsh + oh-my-zsh + Powerlevel10k + the core brew CLI tools, then symlinks
`.zshrc`/`.p10k.zsh`/`.gitconfig` into `$HOME` (existing files are backed up). Idempotent.

## What `.zshrc` needs (install.sh handles all of it)

A bare Ubuntu lacks these and `.zshrc` errors without them — **brew and oh-my-zsh
must exist before it's sourced**:

- **apt:** `zsh`, `git`, `curl`, `build-essential`, `zsh-autosuggestions`,
  `zsh-syntax-highlighting` (the last two are sourced from `/usr/share/...`)
- **Homebrew** at `/home/linuxbrew/.linuxbrew` (hardcoded), providing **nvm, eza, bat, zoxide**
- **oh-my-zsh** + **Powerlevel10k** (in `$ZSH_CUSTOM/themes`)
- A **Nerd Font** (e.g. MesloLGS NF) selected in your terminal

⚠️ **`bat`:** install via **brew** (binary `bat`) — apt's package is `batcat`, which
breaks `.zshrc`'s `alias cat="bat"`.

ℹ️ **Plugins** `jj`/`bun` only add completions; a missing tool just prints a harmless
warning (`brew install jj bun` if you use them).

## Back up / restore

```bash
# initialize + push (needs a real terminal)
git init && git add -A && git commit -m "dotfiles" && git branch -M main
gh repo create dotfiles --private --source=. --push    # or: git remote add origin <url> && git push -u origin main
```

`install.sh` symlinks the files, so editing `~/.zshrc` edits the repo copy — commit
and push to save. `p10k configure` writes back through the symlink too.
