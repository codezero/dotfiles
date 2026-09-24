# provision — replicate this machine on a clean Ubuntu 26.04

<!-- Rules and reference live here; the reasons (generations, live tests, what was
     declined) are in ../docs/DESIGN-NOTES.md. -->

A modular, **cloud-init-friendly** provisioning system. One master script
(`provision.sh`) installs everything silently and tolerantly (a single failing
step never aborts the rest). Captured from an Ubuntu 26.04 LTS ("resolute",
arm64) machine. **No credentials or PII** are stored — only package names.

## Layout

```
provision/
├── provision.sh          # master entrypoint (run as root; cloud-init target)
├── lib.sh                # shared helpers (logging, target-user, apt, as_user)
├── packages/
│   ├── apt.list          # apt packages (base/desktop/boot excluded)
│   ├── flatpak.list      # Flathub app IDs
│   ├── Brewfile          # Homebrew formulae (the CLI toolchain)
│   ├── apt.minimal.list  # lean apt set for PROFILE=minimal (headless agent box)
│   └── Brewfile.minimal  # lean brew set for PROFILE=minimal
├── gnome/
│   └── dconf-settings.ini # curated GNOME settings (loaded by step 55, desktop-only)
└── steps/
    ├── 10-apt.sh             # base apt packages
    ├── 20-apt-third-party.sh # Docker · VSCodium · Cursor (official repos)
    ├── 25-docker-rootless.sh # rootless Docker via setuptool (only DOCKER_ROOTLESS=1)
    ├── 30-brew.sh            # Homebrew + `brew bundle`  (runs as the user)
    ├── 35-rust.sh            # rustup + stable toolchain (as user)
    ├── 36-alacritty.sh       # Alacritty via `cargo install` + theme clone + desktop integration + completions + MesloLGS NF font
    ├── 37-claude-code.sh     # Claude Code CLI (native installer, latest; as user)
    ├── 50-flatpak.sh         # flatpak + Flathub remote
    ├── 55-gnome-dconf.sh     # GNOME dconf settings (only with INSTALL_DESKTOP=1)
    ├── 60-shell.sh           # zsh + oh-my-zsh + p10k + dotfile symlinks/copies (as user)
    ├── 80-next-steps.sh      # ~/PROVISION-NEXT-STEPS.md + MOTD pointer (persistent manual follow-ups)
    └── 90-finalize.sh        # image cleanup: machine-id/ssh-key/log/cargo-cache reset (only GOLDEN_IMAGE=1)
```

## Usage

```bash
# 1. Get the repo onto the clean machine (see cloud-init note about private repos).
#    git is the ONLY bootstrap dependency — a fresh/default Ubuntu ships without
#    it (cloud-init users: the user-data below installs it via `packages: [git]`).
#    Everything else the scripts need is installed by the provisioner itself.
sudo apt update && sudo apt install -y git
git clone <repo-url> ~/dotfiles
cd ~/dotfiles/provision

# 2. Preview first (no changes, no sudo needed) — prints every planned action
bash provision.sh --dry-run

# 3. Provision (root for system pkgs; per-user steps auto-drop to your account)
sudo bash provision.sh
```

Everything is idempotent — safe to re-run. `bash provision.sh --help` prints the
recipes; the table below is the full flag reference.

## Flags

Every knob is an environment variable except `--dry-run`. **This table is the
canonical reference** — the [recipes in the root README](../README.md#pick-your-box)
and in `--help` are just common combinations of it.

| Flag | Default | Effect |
|------|---------|--------|
| `--dry-run` / `-n` | off | Print every planned action and change nothing. Needs neither root nor network — run it after any edit to a step script. |
| `PROVISION_USER` | invoking user → uid 1000 → `ubuntu` | The account that gets the per-user steps (Homebrew, rustup, Claude Code, dotfiles, login shell). **Must already exist** — a typo aborts the run instead of provisioning the wrong account, and so does a box with no non-root user at all (the fallback's last rung is a guess); provisioning never creates users, cloud-init owns that. `--dry-run` only warns. |
| `PROFILE` | `full` | `minimal` = lean headless agent box: skips Alacritty (36) and Flatpak (50), skips VSCodium + Cursor in step 20, and swaps in `apt.minimal.list` + `Brewfile.minimal`. **Keeps Docker**, Rust, Claude Code, zsh + p10k. Any other value aborts. |
| `HEADLESS` | `0` | `1` = the **full** manifests with **no GUI installs**: skips Alacritty (36), kitty (38), Flatpak (50) and VSCodium + Cursor in step 20, keeps everything else — btop/eza/bat/delta/atuin, Docker, Rust, Claude Code, zsh + p10k. The shared headless box a human and an agent both work on. `PROFILE=minimal` already implies it; with `INSTALL_DESKTOP=1` it is refused. |
| `INSTALL_DESKTOP` | `0` | Also install the desktop/locale/IME apt set and apply the GNOME dconf settings (step 55). |
| `GOLDEN_IMAGE` | `0` | Build a reusable image: implies `STRICT` **and** `DOTFILES_COPY`, and runs finalize (step 90). Destructive — throwaway build box only. |
| `GOLDEN_POWEROFF` | `0` | With `GOLDEN_IMAGE=1`: finalize powers the box off as its **last** action, so nothing is typed after the scrub (a post-finalize command in a zsh with atuin recreates its history DB and bakes it in). Recommended for every golden build. |
| `DOTFILES_COPY` | `0` | Copy the dotfiles into `$HOME` instead of symlinking them to the repo: self-contained, so the repo can be deleted afterwards, but edits no longer flow back. |
| `DOCKER_ROOTLESS` | `0` | Set up rootless Docker for the target user (step 25): the official setuptool, linger, the `--user` service, and the `rootless` context. Needs unprivileged user namespaces — see the note at the end of this file. |
| `APT_UPGRADE` | `0` | `apt-get upgrade` the already-installed packages before installing anything (step 10). Off by default because it bumps installed kernel/grub point-releases. |
| `STRICT` | `0` | Abort on the first real failure instead of completing every step and exiting non-zero. Implied by `GOLDEN_IMAGE`. |

### How they combine

- **`GOLDEN_IMAGE=1` implies `STRICT=1` and `DOTFILES_COPY=1`.** An explicit
  `STRICT=0` cannot weaken it: a partially built image must never be captured.
- **`PROFILE=minimal` + `INSTALL_DESKTOP=1` is refused** — the run dies rather
  than half-installing. A minimal box has no GUI, so the combination would pull in
  the desktop apt set while the GUI steps (36/50/55) skip.
- **`HEADLESS=1` + `INSTALL_DESKTOP=1` is refused** for the same reason on the
  other axis: a desktop with every GUI app skipped is not a box anyone asked for.
  `HEADLESS=1` + `PROFILE=minimal` is merely redundant and accepted.
- **`PROFILE` and `HEADLESS` are two axes, not three profiles.** `PROFILE` picks
  the package *manifests* (full lists or the lean ones); `HEADLESS` — or minimal,
  which implies it — turns the *GUI installs* off. So: `full` = everything;
  `HEADLESS=1` = full CLI set, no GUI; `PROFILE=minimal` = lean CLI set, no GUI.
  Before `HEADLESS` existed, "full without a desktop" cargo-built Alacritty and
  installed two Electron editors on boxes that could never display them.
- **`APT_UPGRADE=1` composes with any recipe** — `HEADLESS=1 APT_UPGRADE=1`,
  `PROFILE=minimal APT_UPGRADE=1`, a golden build. It stays opt-in everywhere
  because `apt install` already lands the *newest* version of everything the
  lists name; the only thing it adds is upgrading what the base image shipped
  (kernel, libc, systemd…) — which Ubuntu's `unattended-upgrades` patches for
  security on its own within a day, and which drags a reboot into the run.
- **`GOLDEN_IMAGE=1` + `DOCKER_ROOTLESS=1` is deliberately unsupported.** Rootless
  needs a host-wide AppArmor relaxation (below), which would bake into the image
  and be inherited by every clone. Build the image without it; each clone opts in.
- **Copy mode is sticky.** A re-run *on* a golden image must carry `GOLDEN_IMAGE=1`
  or `DOTFILES_COPY=1`, or step 60 replaces the copies with symlinks into a repo
  path the image may not keep.
- **Flags are UPPERCASE.** A lowercase `golden_image=1` is not the same variable,
  so the run warns about the likely typo rather than silently doing a default run.
- **The examples use `sudo env VAR=… bash provision.sh`, not `sudo VAR=…`.** Both
  work under the stock Ubuntu sudoers rule, but per sudo(8) a command-line
  assignment is subject to the security policy — under a restricted rule that lists
  specific commands without the `SETENV` tag, sudo refuses it. Passing the
  assignment to `env` instead keeps it out of sudo's policy entirely, and it is the
  form every live test scenario exercised.

## Building a golden image

`GOLDEN_IMAGE=1` turns the provisioner into a strict, self-finalizing image
builder. It changes three things versus a normal run:

- **Strict** — the first real failure aborts the whole run, so a partial image
  is never captured. (A normal run is failure-tolerant and merely exits
  non-zero, recording soft failures.)
- **Self-contained dotfiles** — step 60 *copies* the dotfiles into `$HOME`
  instead of symlinking them to the repo, so the image doesn't depend on the
  repo path surviving.
- **Finalize (step 90)** — strips machine-specific identity + build cruft:
  empties `/etc/machine-id` (regenerated uniquely per clone), removes SSH host
  keys, resets cloud-init state, and clears apt caches, logs, the journal, and
  shell history. **Every account** on the box is scrubbed — each uid ≥ 1000
  with a home under `/home`, plus root, each as its own owner — not just the
  target user: credential stores (`CRED_PATHS`), every private key,
  `known_hosts`, **`authorized_keys` (always, no opt-out)**, the
  `<dotfile>.backup.<ts>` files a re-run leaves, Docker registry auths. Then a
  strict verify fails the build if any of it remains anywhere under `/home` or
  `/root` (2026-09-22). Consequence for a **local** clone that carries sshd:
  nobody can SSH in until a key is added at the console — a cloud clone gets
  its keys back from cloud-init.

### Take-path: fresh Ubuntu 26.04 → image

```bash
# 1. On a throwaway build box, get the repo under /tmp — it is NOT needed at
#    runtime once the dotfiles are copied in, and finalize wipes /tmp LAST, so a
#    /tmp clone (and any /tmp logs) are swept from the image automatically.
#    (Fresh box: install git first — see Usage above.)
#    PIN THE REF: an image outlives its build and every clone inherits it, so
#    build from a commit you reviewed — not from whatever the default branch
#    happens to be at that moment. "cloud-init wiring" below owns the
#    tag-vs-SHA mechanics; this is the same rule for the manual path.
git clone <repo-url> /tmp/dotfiles && cd /tmp/dotfiles
git checkout <reviewed-sha> && git log -1 --format='%H %s'   # confirm the ref
cd provision

# 2. Preview, then build strictly. PROVISION_USER targets the image's login user;
#    add INSTALL_DESKTOP=1 for a desktop image. Log under /tmp so the same finalize
#    tmp-wipe removes the log too (never tee a golden build to /var/log or $HOME).
sudo env GOLDEN_IMAGE=1 PROVISION_USER=ubuntu bash provision.sh --dry-run
set -o pipefail   # else the pipeline's status is tee's, and a failed build reads as 0
sudo env GOLDEN_IMAGE=1 GOLDEN_POWEROFF=1 PROVISION_USER=ubuntu bash provision.sh 2>&1 | tee /tmp/golden.log
#    GOLDEN_POWEROFF=1 makes finalize power the box off as its LAST action, so
#    you type NOTHING after the scrub. That matters: in a zsh with atuin, every
#    command you run — a look around, `sudo poweroff` itself — is recorded at
#    pre-exec, recreating ~/.local/share/atuin after finalize wiped it and baking
#    your build session into the image (the Gen-4 first-boot audit caught exactly
#    this). `unset HISTFILE` protects zsh's own history only. Leave it off only
#    if you must inspect the box before capture — then power off from a shell
#    that records nothing (bash), and re-run `verify S8` on a clone to be sure.

# 3. Repo + log were under /tmp → finalize already removed them; nothing to clean.
#    (If you cloned into $HOME or logged there instead, finalize does NOT touch
#    $HOME — it WARNS about a leftover repo/*.log, but you must rm them yourself.)
# 4. Capture once the VM has stopped (with GOLDEN_POWEROFF=1 it stops itself):
#      cloud (AWS/GCP/Azure) : create an image/AMI from the stopped instance
#      Packer                : run provision.sh as the provisioner
#      local VM              : export/snapshot the disk
```

Each booted clone regenerates a unique machine-id + SSH host keys and re-runs
cloud-init on first boot.

The manual follow-ups survive into every clone: step 80 writes them to
`~/PROVISION-NEXT-STEPS.md` and adds an MOTD pointer
(`/etc/update-motd.d/99-provision-next-steps`), both of which finalize leaves
alone. The MOTD notice is self-silencing — delete the `.md` once done and it
stops printing. It names the owning user and how to read the file from another
account, because `$TARGET_HOME` is `0750` and on the cloud-init path the target
user usually is **not** the account you log in as.

**The follow-up list itself is not written down here.** `next_steps_text()` in
`lib.sh` owns it — the same text provision.sh prints at the end of a run and
step 80 writes on-box — and it varies with the machine: `PROFILE=minimal` and
`INSTALL_DESKTOP=1` change the font advice, and a box where rootless Docker
actually came up gets a "nothing to do" note instead of the setup recipe.

> **Destructive by design:** `GOLDEN_IMAGE=1` wipes host keys, machine-id, logs,
> shell history, and credential stores (`.aws`/`.gnupg`/`.config/{gh,gcloud}`/
> `.kube`/`.npmrc`/SSH keys/…) from the target user **and** root — only run it on
> a throwaway build box, never your daily machine. Keep the repo clone **and** any
> run logs under `/tmp` — finalize wipes `/tmp` last, so they're removed from the
> image automatically. Don't tee a golden build to `/var/log` (finalize truncates
> it last) and don't leave the clone/logs in `$HOME` (finalize does NOT touch
> `$HOME`, so they'd bake in — it warns about a leftover repo/`*.log`, but you must
> `rm` them yourself before capture).
> For a *full* image use `provision.sh`; `install.sh` only sets up shell +
> dotfiles and is for an existing box you don't want to fully provision.

## Versions — recorded, not pinned

Every install source here floats by design (brew, rustup, mise, Claude, kitty,
flatpak, three git clones at HEAD), and Homebrew — the largest group — cannot be
version-pinned at all. So "reproducible" means *re-runnable*, and the honest
claim for a golden is **"SHA X built on DATE produced these versions."** The
record that makes the claim checkable is `versions.lock`:

- **Every run writes `~/versions.lock`** (step 85, as the target user): sorted
  `kind  name  version` lines for what the repo *names* — the apt manifests, the
  third-party debs, brew formulae and casks, flatpaks, the rustup toolchain, the
  cargo-built Alacritty, Claude, kitty, mise's global tools, and the commit of
  each git clone. No hostnames, usernames, paths or tokens. Its header records
  when, from which repo SHA, and with which flags.
- **A golden carries its own lock** — finalize leaves `$HOME` alone — so every
  clone boots with "what this image contains" on the box, and `verify` on a
  clone asserts **zero drift** against it — with `--ignore-boot`. Two rows are
  Ubuntu's, not provisioning's: `system kernel` is `uname -r` *at emit time*,
  which inside a golden build is the **build box's** running kernel (step 85
  runs before any reboot), so a clone that boots a newer installed kernel is
  correct, not drifted; and the kernel/bootloader packages `apt.list` names
  (`linux-generic-*`, `grub-*`, `shim-signed`, `efibootmgr` — one list,
  `boot-pkgs.sh`, shared with step 10, which never installs them) are bumped by
  unattended-upgrades minutes after a fresh boot. Without the flag the Gen-4
  clone passed only *because* it booted the stale kernel (2026-09-13). The rows
  stay in the lock — a re-run's drift log still shows a kernel move — the
  first-boot audit just doesn't count them.
- **Every re-run says what moved.** Step 85 compares the previous lock before
  overwriting it, so a bring-to-latest (`APT_UPGRADE=1`, or just re-running
  `brew bundle`) is an observed act: `brew bat 0.26.0 -> 0.26.1`, not a silent
  change.
- **`provision/versions.lock` in the repo is the latest golden's copy.** After
  each golden build, copy the lock from a booted clone into the repo and commit
  it; the build SHA gets an annotated tag `golden/gen-N`. Git history is the
  Gen-N series, and `git diff <a> <b> -- provision/versions.lock` is the
  generation-to-generation diff.

```bash
bash provision/versions-lock.sh emit -o ~/versions.lock     # record this box
bash provision/versions-lock.sh check ~/versions.lock        # drift since then: exit 0 none, 1 drift, 2 error
bash provision/versions-lock.sh check provision/versions.lock # this box vs the latest golden
bash provision/versions-lock.sh check ~/versions.lock --ignore-boot  # what verify runs on a clone
```

What it never does: install, upgrade, or downgrade anything. A `PIN_VERSIONS`
mode was considered and rejected — it would be ~70 % real with an invisible
30 % hole (brew), and a flag that *reads* as reproducible while the largest
group floats underneath is worse than no flag.

## Supply chain — what is pinned, what is verified, what floats

Two different things get installed here, and they are treated differently on
purpose:

- **Tools** — brew formulae, the rustup *toolchain*, mise runtimes, Claude,
  kitty, flatpaks — **float** (bring-to-latest is the design) and are
  **recorded** by `versions.lock`. Each is verified at install by its own
  channel: apt repos and kitty by pinned signing keys, cargo by crates.io
  checksums, rustup's toolchain by its channel manifest, Claude's binary by its
  version manifest, brew bottles by the sha256 in homebrew-core.
- **Code executed at install time** — installer scripts and the git clones whose
  code runs in every shell — is **pinned** in `provision/pins.sh`, one owner
  shared by `provision/` and `install.sh`. Nothing there moves except by editing
  that file, i.e. a reviewed commit:

| What | Was | Now |
|---|---|---|
| Homebrew installer | `curl …/HEAD/install.sh \| bash` | raw URL at a pinned **commit**, file verified against a pinned sha256, then run |
| `rustup-init` | `curl https://sh.rustup.rs \| sh` — no checksum anywhere | the **versioned** binary from `static.rust-lang.org/rustup/archive/<ver>`, verified against a hash recorded **in the repo**; saved under its own name (rustup dispatches on argv[0]) |
| Claude bootstrap | `curl https://claude.ai/install.sh \| bash` | the 302 target `bootstrap.sh` verified against a pinned sha256, then `bash … latest` |
| oh-my-zsh | its installer script from `master`, cloning `master` | `clone_pinned` at `OMZ_SHA` — shallow, detached; the installer's five `git config` lines reproduced so `omz` works |
| powerlevel10k, alacritty-theme | `git clone --depth=1` at HEAD | `clone_pinned` at their SHAs |

Both helpers **refuse, never fall back**: a hash mismatch names the URL and both
hashes and says to read the upstream change and re-pin; an unreachable commit
fails the clone. Under `STRICT`/`GOLDEN_IMAGE` that aborts the build — correct,
an unreviewed installer must not be baked into every clone. The dry tier
asserts that no `curl … | sh` pipeline and no raw `git clone` remain in any
install path, that every pin has the right shape, and exercises both helpers
with a local repo and a `file://` URL (happy path and refusal). `verify` asserts
the three checkouts sit at their pins. oh-my-zsh's updater is set to *remind*,
not act (`.zshrc`): `omz update` would move the checkout off its pin, which the
lock and `verify` then report — bump the pin instead.

**Honest limits.** A pinned installer still installs a moving payload: the
Homebrew installer clones `Homebrew/brew` at its current release, the Claude
bootstrap fetches the current manifest (and verifies its binary itself),
`rustup-init` installs the current stable toolchain (verified by rustup). This
closes the *scripts*, not the ecosystem. And a compromised homebrew-core formula
or a genuinely malicious upstream release is caught by nobody at install time —
the defense there is lag: re-provision on your cadence, never daily.

**Bottle provenance.** Homebrew can verify that a bottle was built by Homebrew's
CI from its formula (sigstore attestations), but that check **needs a GitHub
token** — without one `brew install` fails outright — and a golden build box
holds no credentials by rule. So goldens' bottles are checksum-verified, not
provenance-verified. On an adopted box with `gh` logged in, verify them after the
fact: `HOMEBREW_DEVELOPER=1 brew verify $(brew list --formula)` re-fetches every
bottle and checks its attestation.

### Bring-to-latest cadence — monthly, observed, never a cron

1. `bash provision/versions-lock.sh check ~/versions.lock` — read what moved
   since the last baseline.
2. `bash provision/pins.sh bump --check all` — which pins are behind upstream
   (exit 1 if any). Then `bash provision/pins.sh bump <name>` (or `all`): it
   prints the review — `git log OLD..NEW` for a clone, the script diff for the
   Homebrew installer, the new script for Claude's bootstrap, the version for
   rustup (its hashes come from upstream's `.sha256` files, recorded here so
   they are no longer same-host) — rewrites the pin line, converges this box's
   checkout, and **stages** `pins.sh`. **Read what it printed, then commit.**
   That commit is the control; `bump` only makes it as cheap as a tool's own
   updater. On a pinned box `omz update` is routed to this (`.zshrc`) — omz's
   updater would be a second owner of code the pin owns, and it fails on a
   detached checkout anyway.
3. Re-run the box's recipe with `APT_UPGRADE=1` (copy-mode boxes keep
   `DOTFILES_COPY=1`). Step 85 prints the drift. The three pinned checkouts
   **converge** on that run: `clone_pinned` is a no-op at the pin and moves a
   checkout at any other commit to it — so a bumped pin reaches existing boxes,
   and an `omz update` done by hand is undone (untracked `custom/` survives).
   (A sentinel-file gate in front of `clone_pinned` would undo that: a bump
   would reach fresh boxes only, and `verify` would stay red on every existing
   one. The dry tier asserts no such gate exists.)
4. `HOMEBREW_DEVELOPER=1 brew verify …` if `gh` is logged in.
5. `bash provision/versions-lock.sh emit -o ~/versions.lock` to re-baseline.

Goldens: rebuild from the reviewed SHA, commit the clone's lock as
`provision/versions.lock`, tag `golden/gen-N`.

## Key design points

- **Root vs user.** cloud-init runs as root, but **Homebrew/oh-my-zsh/rustup/
  Claude Code refuse to or shouldn't run as root**. `lib.sh` resolves a
  `TARGET_USER` and runs those steps via `sudo -u "$TARGET_USER"`. Keep the repo
  somewhere that user can read (their home, or `/opt` with world-read) so
  `brew bundle` can read the `Brewfile`. An explicitly-set `PROVISION_USER` must
  exist or provisioning aborts with a clear error (a typo'd username won't
  silently land on the wrong account); an existing user like the AWS AMI default
  `ubuntu` is honored as-is. Left unset, it falls back to the invoking user, then
  the uid-1000 user, then `ubuntu` — and if even that account doesn't exist (a
  bare container image, or a hardened cloud image with the default user removed)
  the run **aborts the same way** rather than provisioning into an empty home:
  set `PROVISION_USER` to an account that exists. `--dry-run` only warns, so
  previews never block.
- **Silent.** apt runs through `env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a`
  (the `env` wrapper is required so the settings survive `sudo`, which resets the
  environment), with `--force-confdef/--force-confold` to auto-resolve dpkg config
  prompts and the msttcorefonts EULA pre-accepted via debconf.
- **apt.list is filtered at install time** (step 10). The list has the shape of an
  `apt-mark showmanual` dump, so the script always skips **boot/firmware** (`grub*`,
  `shim-signed`, `efibootmgr`) and **kernel** metapackages (they'd reconfigure the
  bootloader / rebuild initramfs), and the **third-party** packages that step 20
  owns (`docker-*`, `containerd.io`, `codium`, `cursor`, `uidmap`) — those
  have no repo yet at step 10, and a single unlocatable package would otherwise
  abort the entire `apt-get install` batch. The **desktop/locale/IME** set is
  skipped unless `INSTALL_DESKTOP=1`. The batch also falls back to per-package
  installs if it fails.
- **`APT_UPGRADE=1` (opt-in, off by default)** runs `apt-get upgrade` right after
  the step-10 index refresh, bringing already-installed packages up to date before
  the toolchain installs. It uses `upgrade` (not `full-upgrade`) so no brand-new
  kernel packages are pulled, runs prompt-free via the noninteractive wrapper, and is
  convergent (idempotent). It *will* bump installed kernel/grub point-releases
  (reboot-required), which is why it's opt-in; cloud-init users can use
  `package_upgrade: true` instead.
- **Brewfile is filtered at install time** (step 30) to Homebrew-native lines
  (`tap`/`brew`/`cask`). `brew bundle dump` also records `flatpak`, `npm`, `mas`,
  and `vscode` entries; feeding those to `brew bundle` here would install flatpaks
  before the Flathub remote exists (step 50) or need Node for npm packages, so they
  are dropped (flatpaks are owned by `flatpak.list`). **Casks are kept** —
  Linux-capable casks such as `codex` install fine on linuxbrew (arm64/x86_64);
  any macOS-only cask simply fails-soft. `corepack` is a manual follow-up.
- **Tolerant.** Each step and each apt batch is wrapped so failures warn and
  continue; `provision.sh` prints a summary of any steps that had issues.
- **Official sources, verified 2026-05-24.** Docker, VSCodium, and Cursor all
  use their official **signed apt repos** (Cursor moved off the old download-URL
  API to `downloads.cursor.com/aptrepo`).
- **Signing keys are verified + gated.** Each repo add + install only proceeds
  after `verify_keyring` confirms a valid, non-empty GPG key landed (no
  half-configured repo behind a failed/tampered key). Docker, Cursor, and
  VSCodium fingerprints are all **pinned** (each verified against the live key).
  A failed/mismatched key skips just that vendor (never bricks).
- **Arch-aware.** Docker codename auto-falls back to `noble` if the repo lacks
  your release. Cursor's signed apt repo serves both arches (`stable` suite).

## The package lists (curated by hand)

Everything in `packages/` is **maintained by hand** — adding a tool means adding
a line. There is no exporter: one existed, and it was removed once re-running it
had come to make the lists worse rather than better (`docs/DESIGN-NOTES.md` has
the measurements). `apt.list` still has the shape of an `apt-mark showmanual`
dump and step 10 filters it (see above), so a line a step already owns is
harmless noise rather than a bug.

**Forking, and want to start from your own box?** Three one-liners, no script:

```bash
LC_ALL=C apt-mark showmanual | sort -u                     # -> apt.list (prune it)
flatpak list --app --columns=application                   # -> flatpak.list
brew bundle dump --file=- | grep -E '^(tap|brew|cask) '    # -> Brewfile
```

`LC_ALL=C` is load-bearing, not decoration: under a UTF-8 locale `sort` ignores
the hyphen, so `ibus-table-cangjie-big` lands *after* `…cangjie5`, while `comm`
compares bytes — subtract one list from another and it silently stops working at
the first mismatch. That bug is what finished the exporter off.

**Snaps are neither exported nor installed**: Alacritty — the only user snap —
is built from crates.io via cargo in step 36, so the machine needs no snapd.

## Terminfo — ssh in from whatever terminal you use

Every box gets `kitty-terminfo` + `ncurses-term` from the apt lists, on **every
profile**, whether or not a terminal is installed locally. The reason is that
ssh forwards `TERM` but not the terminfo behind it, so what a box needs is
decided by the **client**, not by the box: connect from kitty and the far side
needs `xterm-kitty` even though it will never run kitty.

`ncurses-base` (Essential, always present) already covers `xterm-256color`,
`screen-*` and `tmux-256color`. `ncurses-term` adds alacritty, wezterm, foot,
vte and ~2,900 more; `kitty-terminfo` adds `xterm-kitty`, which `ncurses-term`
does not carry. Together ~4.5 MB.

`~/.terminfo` belongs to the user — nothing here writes it, and ncurses searches
it *before* `/etc` and `/usr/share`, so anything you put there wins.

**Ghostty has no entry anywhere in Ubuntu**, and neither will the next new
terminal. That one is the client's job, once per host:

```bash
infocmp -x xterm-ghostty | ssh user@host 'tic -x -'   # or: ghostty +ssh-cache
```

kitty has its own version of this — `kitten ssh user@host` copies the terminfo
over on connect. Worth knowing for boxes this repo did *not* provision; aliasing
`ssh` to it globally is not recommended (it breaks outside kitty and adds a
handshake to hosts that already work).

## cloud-init wiring

`provision.sh` is the single entrypoint. Minimal `user-data`:

```yaml
#cloud-config
package_update: true
packages: [git]          # ensure git exists before the clone (don't assume it)

# This repo NEVER creates users — cloud-init's `users:` owns that, and lib.sh
# dies if PROVISION_USER names an account that doesn't exist.
users:
  - default              # the image's own user
  - name: agent
    uid: 1100            # PIN IT. Listing `- default` first does NOT win uid 1000
                         # (proven live): cloud-init assigns uids in its own order,
                         # so without an explicit uid the target can collide with
                         # the image user — and then lib.sh's explicit branch and
                         # its uid-1000 fallback pick the same account, which makes
                         # a broken fallback undetectable.
    primary_group: staff # a group != the username is the only thing that exercises
                         # TARGET_GROUP; that code shipped unrun for months.
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true

runcmd:
  # Pin to a TAG for image builds (--branch takes a branch/tag NAME, not a raw
  # commit SHA). For a specific commit: clone, then `git -C /opt/dotfiles fetch
  # --depth=1 origin <sha> && git -C /opt/dotfiles checkout <sha>`.
  - [ bash, -lc, "git clone --branch <tag> --depth=1 https://github.com/<you>/dotfiles /opt/dotfiles && chmod -R a+rX /opt/dotfiles" ]
  # `set -o pipefail` so a provision failure isn't masked by tee's exit 0.
  - [ bash, -lc, "set -o pipefail; PROVISION_USER=ubuntu bash /opt/dotfiles/provision/provision.sh 2>&1 | tee /var/log/provision.log" ]
```

For reproducible images, build from a ref you reviewed rather than from the
default branch, and confirm it before running. A **known commit SHA** works
today (fetch + checkout, as shown above) — compare what you get against the
SHA you reviewed. A **tag** is tidier and is what the example uses, but this
repo doesn't tag releases yet, so treat that form as available once it does;
`git verify-tag` only helps if the tag is signed.

**Private repo + "no credentials":** don't bake a token into cloud-init.
Either (a) make the dotfiles repo **public**, or (b) ship the files via
cloud-init `write_files` instead of cloning, or (c) pull from a private store
using the instance's existing cloud IAM/SSM role (no static secret). Logs land
in `/var/log/provision.log`.

> Heads-up: `DOCKER_ROOTLESS=1` wires up rootless Docker for the user (step 25 —
> the official setuptool + `loginctl enable-linger` so it survives logout + the
> `rootless` context). It — and anything needing unprivileged user namespaces —
> won't work on hosts that restrict nested userns (the same limitation seen on
> the source VM); there it soft-fails and rootful Docker still works. On Ubuntu
> 24.04+/26.04 the block is AppArmor's `kernel.apparmor_restrict_unprivileged_userns=1`
> (default — even when the `kernel.unprivileged_userns_clone` sysctl is `1`); to
> allow rootless persistently, drop a `sysctl.d` file setting it to `0` and run
> `sudo sysctl --system` (a host-wide security trade-off). For rootless you do
> **not** `usermod -aG docker` (that group is root-equivalent). The exact
> commands, and whether this box still needs them at all, are in
> `~/PROVISION-NEXT-STEPS.md` on the box itself — this note is the *why*.
