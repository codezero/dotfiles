# Living with your VM

A VM built by this repo — cloned from a golden image or provisioned from scratch, terminal-only
or desktop — is ready to use at first boot. This page is everything **after** that: the first
hour, the house rules, the routine, and the end.

How to *build* one: [README → Pick your box](README.md#pick-your-box) and
[Building a golden image](provision/README.md#building-a-golden-image). What one particular
machine still needs: `~/PROVISION-NEXT-STEPS.md`, on the VM itself.

## Ephemeral or persistent?

Decide up front — it decides how much of this page applies to you.

| | **Ephemeral** | **Persistent** |
|---|---|---|
| Lives for | one task, one agent run, a few days | weeks or months — a workstation |
| Maintenance | none — replace it instead | weekly updates, a monthly refresh |
| Credentials | only what the task needs, short-lived, revoked at the end | yours, added by hand |
| When it's done | delete it | move to a fresh VM from a newer image |

When in doubt, choose ephemeral. A fresh clone is cheaper than a long repair, and an agent
working unattended belongs on a VM you can throw away.

## Day 1 — every new VM

1. **Read `~/PROVISION-NEXT-STEPS.md`.** It lists what this machine still needs — Node and Go
   via mise, the Docker choice, fonts — and the SSH/console login banner points to it.
2. **Update Ubuntu and reboot.**

   ```bash
   sudo apt update && sudo apt upgrade
   sudo reboot
   ```

   This is expected, not a sign that something is wrong. The build never installs a *new*
   kernel package, so it never needs a reboot halfway through and stays safe to run unattended
   from cloud-init. The newer kernel is yours to take, and `apt upgrade` takes it.
   - *"Waiting for cache lock"* right after first boot — Ubuntu's own updater is running. Let it finish.
   - *A dialog asking which services to restart* — accept the defaults; you are rebooting anyway.
   - *"deferred due to phasing"* — Ubuntu rolls some updates out gradually. They arrive on their own.
3. **Add credentials by hand — only the ones this VM needs:** `gh auth login`, an SSH key,
   your AI tools' logins. Never copy a whole home directory from another machine. On a desktop
   VM, `gh` keeps its token in the GNOME keyring, so you log in again on every new VM.
4. **Personalize the way that survives** — read [Your own changes](#your-own-changes) before
   you edit anything in your home directory.

## House rules

### You can

- **Install anything new** — `apt install`, `brew install`, `flatpak install`, `mise use`,
  `cargo install`, packages inside your mise runtimes, Docker images.
- **Upgrade through the package managers** — `apt upgrade` (kernels included), `brew upgrade`,
  `flatpak update`, `mise upgrade`, `rustup update`, `claude update`.
- **Change your desktop and terminal preferences.**

### Don't

- **Never run a golden build (`GOLDEN_IMAGE=1`) on a VM you use.** It deletes keys, credentials
  and history from every account on the machine. Images are built only on a fresh, throwaway
  VM — never from one that has been used.
- **Don't install a second copy of something already here, from another source** — a second
  Homebrew, a snap Alacritty, apt's `bat` (its binary is `batcat`, which breaks the alias), or a
  vendor's `curl | sh` installer for Homebrew, rustup, oh-my-zsh or kitty. Those skip the checks
  this repo makes before anything runs (pinned commits, checksums, signatures), and a duplicate
  shadows the original on `PATH`. The [monthly refresh](#the-monthly-refresh) updates them.
- **Don't edit or `git pull` inside the pinned checkouts** — `~/.oh-my-zsh` (the powerlevel10k
  theme lives inside it) and `~/.config/alacritty/themes`. They move only when the repo's pin
  moves; `omz update` is switched off on purpose and tells you so. Adding your *own* files
  directly in `~/.oh-my-zsh/custom/` is fine.
- **Don't hand-edit the Docker, VSCodium or Cursor apt sources or keyrings** under `/etc/apt/`.
  Each one is tied to a signing key this repo verified.
- **Don't run `install.sh`, `brew` or `pins.sh` with `sudo`.** Only `provision.sh` runs as root.

### Do regularly (persistent VMs)

| When | What |
|---|---|
| Weekly, or when the login banner says so | `sudo apt update && sudo apt upgrade`. Reboot when the banner says *System restart required*. Ubuntu installs security updates daily on its own, but never reboots for you. |
| After a kernel update and reboot | `sudo apt autoremove` — removes old kernels, keeps the running one and a fallback. |
| Monthly | [The monthly refresh](#the-monthly-refresh). |
| A new golden generation, or a new Ubuntu release | [Move to a fresh VM](#moving-on). Don't `do-release-upgrade` a provisioned VM — this repo targets Ubuntu 26.04. |

## Your own changes

The files this repo puts in your home are listed in [`dotfiles.list`](dotfiles.list):
`.zshrc`, `.gitconfig`, `.tmux.conf`, the terminal configs, the whole `~/.config/nvim`, and a
few more. **The repo owns them.** The monthly refresh puts the repo's version back; if you had
edited yours, it is kept beside it as `<name>.backup.<timestamp>`. Nothing is lost, but your
change is no longer in effect.

| To change… | Put it in… | Not in… |
|---|---|---|
| Shell aliases, functions, environment variables | a file of your own in `~/.oh-my-zsh/custom/`, such as `my.zsh`. oh-my-zsh loads every `*.zsh` there, and nothing here ever touches it. | `~/.zshrc` |
| Git identity | `~/.gitconfig.local` — `git config --file ~/.gitconfig.local user.name "Your Name"`, the same for `user.email`. It is read last and nothing here ever touches it. | `~/.gitconfig`, `git config --global` |
| nvim, tmux, terminal settings | your fork of this repo, then the monthly refresh | the copies in your home |
| GNOME dock, theme, fonts | Settings, as usual. A refresh with the desktop flag re-applies the keys in `provision/gnome/dconf-settings.ini`; put the ones you want to keep in your fork's copy. | — |
| Installed software | just install it | — |

Two exceptions:
- A VM built **from scratch in symlink mode** (not a golden clone): the files in your home
  *are* links into the repo checkout. Edit them there, and commit to your fork.
- Claude Code rewrites `~/.claude/settings.json` itself, so expect a backup of that one after a refresh.

## The monthly refresh

Persistent VMs only. Bring everything up to date in one step that you watch, not from a cron.

1. **Snapshot the VM** if your platform can.
2. **Get your fork at a commit you have reviewed:**

   ```bash
   git clone <your-fork-url> /tmp/dotfiles && cd /tmp/dotfiles && git checkout <commit>
   ```

3. **Re-run the recipe the VM was built with, plus `APT_UPGRADE=1`.** Line 2 of
   `~/versions.lock` shows the flags it was built with. Use all of them **except
   `GOLDEN_IMAGE=1` — never that one.** On a golden clone, keep `DOTFILES_COPY=1`, so your files
   stay copies. For a desktop golden clone, preview first, then run:

   ```bash
   sudo env INSTALL_DESKTOP=1 DOTFILES_COPY=1 APT_UPGRADE=1 PROVISION_USER=$USER bash provision/provision.sh --dry-run
   sudo env INSTALL_DESKTOP=1 DOTFILES_COPY=1 APT_UPGRADE=1 PROVISION_USER=$USER bash provision/provision.sh
   ```

   What each flag means: [Flags](provision/README.md#flags).
4. **Read the end of the output:** what moved since last time, every warning, and whether the
   VM wants a reboot.
5. **Look for backups** — `find ~ -maxdepth 3 -name '*.backup.*'`. Each one was an edit of
   yours that the refresh replaced. Move the change to [where it belongs](#your-own-changes).

oh-my-zsh, powerlevel10k, the Alacritty themes and the installers are pinned, and change only
when someone **bumps** them in the repo: `bash provision/pins.sh bump` shows what changed
upstream, you review it, and you commit. The next refresh then moves the VM to the new pins.
That is the only update path for them, on purpose — see
[Bring-to-latest cadence](provision/README.md#bring-to-latest-cadence--monthly-observed-never-a-cron).

Optional health check, read-only, from the checkout: `bash smoke-test.sh verify` (on a desktop
golden clone you have been using: `bash smoke-test.sh verify copy full desktop`).

## Moving on

**Ephemeral:** push your work, revoke the tokens you gave the VM, delete it.

**Persistent, to a newer image:** start a fresh VM from the new golden image (or from scratch),
and carry over only:
- **your credentials** — for example `~/.ssh`, `~/.gnupg`, `~/.config/gh`, `~/.docker`, and your
  AI tools' logins (`~/.claude`, `~/.claude.json`, `~/.codex`);
- **your work** — repositories, notes.

Not the whole home directory, not shell history, not caches or keyrings. Then do
[Day 1](#day-1--every-new-vm) on the new VM, including `gh auth login` (the token lived in the
old VM's keyring). Retire the old VM once the new one has proved itself.

## AI agents on these VMs

- **Choose the VM kind by trust.** Unattended or experimental agent work goes on an ephemeral
  VM. Your own daily work with an assistant can live on a persistent one.
- **An agent runs as you.** It can read what you can read and use every credential you added.
  Give the VM narrow, short-lived tokens — one repository, read-only where possible — rather
  than your personal keys.
- **Know the two ways to root.** On most cloud images the default account has password-less
  `sudo`, so an agent running as that account can become root. Membership of the `docker` group
  is root-equivalent too. If that matters, run agents as a separate account without either:
  cloud-init's `users:` creates it, and `PROVISION_USER` points provisioning at it
  ([cloud-init wiring](provision/README.md#cloud-init-wiring)).
- **Agents use non-interactive shells**, which don't read `~/.zshrc`. Put the mise shims on
  their `PATH` — the line is in `~/PROVISION-NEXT-STEPS.md`.
- **Never put credentials in the repo or your fork.** Enable the pre-commit hook once per clone
  (`git config core.hooksPath .githooks`); it runs gitleaks, when installed, before every commit.
