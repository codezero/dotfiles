# provision — replicate this machine on a clean Ubuntu 26.04

A modular, **cloud-init-friendly** provisioning system. One master script
(`provision.sh`) installs everything silently and tolerantly (a single failing
step never aborts the rest). Captured from an Ubuntu 26.04 LTS ("resolute",
arm64) machine. **No credentials or PII** are stored — only package names.

## Layout

```
provision/
├── provision.sh          # master entrypoint (run as root; cloud-init target)
├── inventory-export.sh   # run on the SOURCE machine to refresh the lists exactly
├── lib.sh                # shared helpers (logging, target-user, apt, as_user)
├── packages/
│   ├── apt.list          # apt packages (base/desktop/boot excluded)
│   ├── flatpak.list      # Flathub app IDs
│   └── Brewfile          # Homebrew formulae (the CLI toolchain)
├── gnome/
│   └── dconf-settings.ini # curated GNOME settings (loaded by step 55, desktop-only)
└── steps/
    ├── 10-apt.sh             # base apt packages
    ├── 20-apt-third-party.sh # Docker · VSCodium · Bruno · Cursor (official repos)
    ├── 30-brew.sh            # Homebrew + `brew bundle`  (runs as the user)
    ├── 35-rust.sh            # rustup + stable toolchain (as user)
    ├── 36-alacritty.sh       # Alacritty via `cargo install` + theme clone + desktop integration
    ├── 37-claude-code.sh     # Claude Code CLI (native installer, stable; as user)
    ├── 50-flatpak.sh         # flatpak + Flathub remote
    ├── 55-gnome-dconf.sh     # GNOME dconf settings (only with INSTALL_DESKTOP=1)
    └── 60-shell.sh           # zsh + oh-my-zsh + p10k + dotfile symlinks (as user)
```

## Usage

```bash
# 1. Get the repo onto the clean machine (see cloud-init note about private repos)
git clone <repo-url> ~/dotfiles
cd ~/dotfiles/provision

# 2. Preview first (no changes, no sudo needed) — prints every planned action
bash provision.sh --dry-run

# 3. Provision (root for system pkgs; per-user steps auto-drop to your account)
sudo bash provision.sh
# target a specific user:        sudo PROVISION_USER=alice bash provision.sh
# also install the desktop set:  sudo INSTALL_DESKTOP=1 bash provision.sh
```

Everything is idempotent — safe to re-run.

## Key design points

- **Root vs user.** cloud-init runs as root, but **Homebrew/oh-my-zsh/rustup/
  Claude Code refuse to or shouldn't run as root**. `lib.sh` resolves a
  `TARGET_USER` and runs those steps via `sudo -u "$TARGET_USER"`. Keep the repo
  somewhere that user can read (their home, or `/opt` with world-read) so
  `brew bundle` can read the `Brewfile`. An explicitly-set `PROVISION_USER` must
  exist or provisioning aborts with a clear error (a typo'd username won't
  silently land on the wrong account); an existing user like the AWS AMI default
  `ubuntu` is honored as-is. Left unset, it falls back to the invoking user, then
  the uid-1000 user, then `ubuntu`. `--dry-run` only warns, so previews never block.
- **Silent.** apt runs through `env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a`
  (the `env` wrapper is required so the settings survive `sudo`, which resets the
  environment), with `--force-confdef/--force-confold` to auto-resolve dpkg config
  prompts and the msttcorefonts EULA pre-accepted via debconf.
- **apt.list is filtered at install time** (step 10). The exported list is the full
  `apt-mark showmanual` set, so the script always skips **boot/firmware** (`grub*`,
  `shim-signed`, `efibootmgr`) and **kernel** metapackages (they'd reconfigure the
  bootloader / rebuild initramfs), and the **third-party** packages that step 20
  owns (`docker-*`, `containerd.io`, `codium`, `cursor`, `bruno`, `uidmap`) — those
  have no repo yet at step 10, and a single unlocatable package would otherwise
  abort the entire `apt-get install` batch. The **desktop/locale/IME** set is
  skipped unless `INSTALL_DESKTOP=1`. The batch also falls back to per-package
  installs if it fails.
- **Brewfile is filtered at install time** (step 30) to Homebrew-native lines
  (`tap`/`brew`/`cask`). `brew bundle dump` also records `flatpak`, `npm`, `mas`,
  and `vscode` entries; feeding those to `brew bundle` here would install flatpaks
  before the Flathub remote exists (step 50) or need Node for npm packages, so they
  are dropped (flatpaks are owned by `flatpak.list`). **Casks are kept** —
  Linux-capable casks such as `codex` install fine on linuxbrew (arm64/x86_64);
  any macOS-only cask simply fails-soft. `corepack` is a manual follow-up.
- **Tolerant.** Each step and each apt batch is wrapped so failures warn and
  continue; `provision.sh` prints a summary of any steps that had issues.
- **Official sources, verified 2026-05-24.** Docker, VSCodium, and Bruno use
  their official signed apt repos. Cursor uses its official download **API → .deb**
  (arch-aware, self-updating) because it has no documented apt key.
- **Arch-aware.** Docker codename auto-falls back to `noble` if the repo lacks
  your release; Bruno falls back to a GitHub `arm64` .deb (its apt repo is
  amd64-only); Cursor picks `linux-arm64`/`linux-x64` automatically.

## Refreshing the lists (do this on the source machine)

The committed lists were seeded by inspecting on-disk state and **may not be
exhaustive** (Homebrew especially). Regenerate them exactly:

```bash
bash inventory-export.sh      # writes packages/{apt.list,flatpak.list,Brewfile}
```
The exporter now self-cleans the **Brewfile** (moves `flatpak` entries into
`flatpak.list`, strips `npm`/`mas`/`vscode`, warns about Linux-unsupported casks),
so the duplication doesn't recur on re-export.

`apt.list` keeps the full `showmanual` set on purpose — step 10 filters it (see
above), so you don't have to. **Snaps are not exported or installed**: Alacritty
— the only user snap — is built from crates.io via cargo in step 36, so the
machine needs no snapd.

## cloud-init wiring

`provision.sh` is the single entrypoint. Minimal `user-data`:

```yaml
#cloud-config
package_update: true
runcmd:
  - [ bash, -lc, "git clone https://github.com/<you>/dotfiles /opt/dotfiles && chmod -R a+rX /opt/dotfiles" ]
  - [ bash, -lc, "PROVISION_USER=ubuntu bash /opt/dotfiles/provision/provision.sh 2>&1 | tee /var/log/provision.log" ]
```

**Private repo + "no credentials":** don't bake a token into cloud-init.
Either (a) make the dotfiles repo **public**, or (b) ship the files via
cloud-init `write_files` instead of cloning, or (c) pull from a private store
using the instance's existing cloud IAM/SSM role (no static secret). Logs land
in `/var/log/provision.log`.

> Heads-up: rootless Docker and anything needing unprivileged user namespaces
> may not work on hosts that restrict nested userns (the same limitation seen on
> the source VM). Rootful Docker is installed and works regardless.
