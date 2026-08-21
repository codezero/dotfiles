# dotfiles

Personal shell environment: Zsh + oh-my-zsh + Powerlevel10k on a Homebrew toolchain.

## Pick your box

Two entry points, both first-class: **`install.sh`** sets up shell + dotfiles on a
box you already have; **`provision/provision.sh`** builds a whole machine and is
what cloud-init runs. Five recipes cover nearly every use — each is one line, run
from the repo root.

| I want… | Run this |
|---------|----------|
| **Just my shell** on an existing box — zsh, p10k, dotfiles, core CLI tools. No Docker, no editors. | `bash install.sh` |
| **A headless agent box** — lean apt/brew set, Docker, Rust, Claude Code, zsh + p10k. Skips every GUI package. | `sudo env PROFILE=minimal bash provision/provision.sh` |
| **My daily desktop** — the full set, plus the desktop/locale/IME packages and GNOME settings. | `sudo env INSTALL_DESKTOP=1 bash provision/provision.sh` |
| **A golden image** to clone from — strict, self-contained, machine identity wiped. [Throwaway build box only](provision/README.md#building-a-golden-image). | `sudo env GOLDEN_IMAGE=1 PROVISION_USER=ubuntu bash provision/provision.sh` |
| **To bring a box up to date** — re-run whichever recipe built it, plus an `apt upgrade` of what's installed. | `sudo env APT_UPGRADE=1 bash provision/provision.sh` |

On a fresh Ubuntu, first: `sudo apt update && sudo apt install -y git`, then clone
the repo — **git is the only bootstrap dependency**; the scripts install the rest.

**Preview before you commit to anything.** Adding `--dry-run` to any provision
line prints every planned action and changes nothing — no sudo, no network:

```bash
bash provision/provision.sh --dry-run
```

Three things are deliberately *not* recipes, because they combine with any of them:

- **Rootless Docker** — add `DOCKER_ROOTLESS=1`. On Ubuntu 24.04+ this needs one
  host-wide AppArmor change first; the run says exactly what, and
  `~/PROVISION-NEXT-STEPS.md` keeps the instructions on the box afterwards.
- **Another account** — add `PROVISION_USER=alice`. It must already exist:
  provisioning never creates users (on a cloud box, cloud-init owns that).
- **cloud-init** — the same script is the payload, run as root from `runcmd`. See
  [cloud-init wiring](provision/README.md#cloud-init-wiring).

Every flag, its default, and how they interact:
[**provision/README — Flags**](provision/README.md#flags). `provision.sh --help`
prints the recipes above at the point of use.

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

## Smoke tests

`bash smoke-test.sh lint` + `bash smoke-test.sh dry` run anywhere (no sudo, no
changes): shellcheck the tree + assert the `--dry-run` behavior of every
provisioning flag. `bash smoke-test.sh verify S4` audits a provisioned box's end
state read-only — it takes the runbook's scenario id and expands it to the right
assertions. `bash smoke-test.sh scenarios` prints the runbook, the id → token
map, and how the tokens compose.

## `install.sh` in detail

```bash
sudo apt update && sudo apt install -y git   # fresh/default Ubuntu ships no git
git clone <your-repo-url> ~/dotfiles
cd ~/dotfiles
bash install.sh        # not chmod +x in the repo, so invoke with bash — as
                       # YOURSELF, not under sudo (it sudo's only where needed)
exec zsh
```

Two password prompts are expected: sudo (apt + Homebrew — step `[0/7]` primes it
up front) and `chsh` at step `[7/7]`, which asks for **your own** password via
PAM to change your login shell. If you redirect the output to a log
(`bash install.sh > log 2>&1`), run `sudo -v` first — otherwise sudo's prompt
goes to the log while it waits on the terminal, and the run looks like a hang.

Installs zsh + tmux + oh-my-zsh + Powerlevel10k + the core brew CLI tools, then installs
the dotfiles listed in `dotfiles.list` into `$HOME` — `.zshrc`, `.p10k.zsh`,
`.gitconfig`, `.tmux.conf`, `.config/alacritty/alacritty.toml` (+ theme clone),
`.config/nvim/` (LazyVim) and the tracked `.claude/` configs — symlinked by
default (`--copy` to copy instead), plus the MesloLGS NF Nerd Font. Existing
files are backed up. Idempotent.

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

ℹ️ **Plugins** `.zshrc` loads oh-my-zsh plugins for tools this bootstrap doesn't
install (`golang`, `httpie`, `kubectl`, `rust`, `docker`, `docker-compose`, `jj`,
`bun`). They only add completions/aliases and stay quiet when the binary is
missing — verified on a fresh box. Install what you use (`brew install jj bun`)
or trim the `plugins=()` line. `tmux` is the exception: its plugin nags on every
shell start, so `install.sh` installs tmux (it also ships `.tmux.conf`).

## Back up / restore

```bash
# initialize + push (needs a real terminal)
git init && git add -A && git commit -m "dotfiles" && git branch -M main
gh repo create dotfiles --private --source=. --push    # or: git remote add origin <url> && git push -u origin main
```

`install.sh` symlinks the files, so editing `~/.zshrc` edits the repo copy — commit
and push to save. `p10k configure` writes back through the symlink too.

### Symlink vs. copy mode — copies are sticky

`--copy` / `DOTFILES_COPY=1` installs real files instead of symlinks (self-contained;
the repo can then be deleted, but edits no longer flow back). Note the asymmetry:

- **symlink → copy** is a plain `bash install.sh --copy`. No backups are made — the
  old dest is a symlink, which holds no content of its own.
- **copy → symlink does NOT happen on a re-run.** A plain `bash install.sh` leaves
  identical copies alone, on purpose: that same guard is what stops a fresh
  `.backup.<timestamp>` being minted on every re-run. To go back, remove the files
  first (e.g. `rm ~/.zshrc` — or delete each entry in `dotfiles.list`), then re-run.

Provision has the mirror-image trap: a re-run **on** a golden image must keep
`GOLDEN_IMAGE=1` or `DOTFILES_COPY=1`, or it will symlink over the copies.

A `~/.zshrc.backup.<timestamp>` on a fresh box is expected once: oh-my-zsh's
installer writes a template `.zshrc` before ours is installed, and that template
gets backed up rather than deleted.
