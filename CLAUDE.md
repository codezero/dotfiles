# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

Personal dotfiles backup + full-machine provisioning for **Ubuntu 26.04 ("resolute", arm64)**.
Bash + config files only — no build system. The checks are `smoke-test.sh`'s tiers.

**The *why* behind most of this lives in [`docs/DESIGN-NOTES.md`](docs/DESIGN-NOTES.md)** — the
golden-image generations, the live-test record, what was tried and declined, and the gotchas
that outlive any one line of code. This file holds the rules; that one holds the reasons.

## Commands

- `bash install.sh` — lightweight bootstrap: **shell + dotfiles only** (zsh, tmux, oh-my-zsh,
  p10k, core brew CLI). Run **as yourself, not under sudo**. A first run prompts twice (sudo,
  then your **login** password for `chsh` — announced right before, because a fresh sudo
  timestamp makes it the only prompt); a converged re-run prompts for nothing.
- `bash provision/provision.sh --dry-run` — **the verification path**: prints every planned
  action, changes nothing, needs no sudo. Run it after editing any step script.
- `sudo bash provision/provision.sh` — full machine replication. Always `sudo env VAR=…` (a
  bare `sudo VAR=…` is subject to the sudoers policy). **`provision/README.md#flags` is the
  canonical flag reference** and `provision.sh --help` prints the recipes — keep those two the
  owners; don't restate flag syntax elsewhere.
- `bash provision/inventory-export.sh` — run on the **source** machine to regenerate
  `packages/{apt.list,flatpak.list,Brewfile}` from live state. Names only, never versions.
- `bash provision/versions-lock.sh emit|check` — **record what landed / report drift; never
  installs.** Step 85 writes `~/versions.lock` on every run as the target user, logging the
  drift since the previous lock first. Sorted TSV (`kind name version`), every kind optional so
  it is valid on a bare CI runner, and no usernames/hostnames/paths.
  `provision/README.md#versions--recorded-not-pinned` owns the fact.
- `bash smoke-test.sh lint && bash smoke-test.sh dry` — **run after ANY script change.**
  `smoke-test.sh` is the CLI; the tiers live in `tests/` (`lib.sh` helpers, `vocab.sh` the
  scenario→token map shared by dry and verify, then `lint|dry|verify|scenarios.sh`).
- `bash smoke-test.sh verify S4` — read-only end-state audit of a provisioned box; takes a
  runbook id and expands it (raw tokens and bare `verify` auto-detect also work).
- `bash smoke-test.sh scenarios` — the live runbook S1–S15, the id → token map, and how the
  tokens compose.
- Scripts are **not** executable — always invoke with `bash <script>`.
- **Lint every script you touch with `shellcheck`, not just `bash -n`.** Run it from the steps
  dir so the sourced `lib.sh` resolves: `cd provision/steps && shellcheck -x <script>`. The
  tree is clean at warning severity; the remaining **info**-level notes are intentional (SC2016
  on the `as_user '…$HOME…'` deferred-expansion pattern, SC2024 on root-side `dconf load`
  redirects) — don't "fix" them.

### What the tiers guarantee

- **lint** — shellcheck over every script in the tree at warning severity.
- **dry** — the `--dry-run` matrix: exit codes and output markers for every flag combination,
  plus offline functional tests (the dotfile installer in a scratch `$HOME`, `clone_pinned` /
  `fetch_pinned` against a local repo — `PINS_TEST_ALLOW_FILE=1` is that harness hook and
  nothing else may set it — and `versions-lock.sh` emit/check/mutate) and guards that
  keep invariants from regressing: no `curl | sh`, no raw `git clone`, no bare `apt-get`, no
  root-side write into `$TARGET_HOME`, no commit SHAs in the docs, both CI files present and
  running both tiers.
- **verify** — the on-box audit. Contradictory token combos (`full minimal`, `plain copy`,
  `installsh full`, `plain golden-clone`) are **refused with exit 2** before anything runs.
  Never calls an Electron app's `--version` (hangs headless). `golden-clone` is a **first-boot**
  audit: a credential path passes only if it was born after the clone's first boot (measured by
  `/etc/machine-id`'s mtime, which finalize empties and systemd rewrites), and the lock must
  show zero drift **with `--ignore-boot`** — an in-build lock's `system kernel` is the *build
  box's* `uname -r`, and the kernel/bootloader apt rows are unattended-upgrades' to bump, so a
  clone that boots a newer kernel is correct, not drifted. Once a clone is adopted and
  upgraded, audit it as `verify copy full desktop` instead — its drift is the owner's doing.

**CI runs lint + dry on every push/PR**, on `ubuntu-24.04-arm` (the target arch) and
`ubuntu-24.04`, with shellcheck **pinned to 0.11.0 by sha256** — upstream publishes no checksum
file, so both hashes are TOFU pins; re-pin when bumping. `.gitlab-ci.yml` is the same gate for
the community GitLab fork this repo expects downstream (images pinned by digest, arch chosen at
run time, an arm64 leg only when `ARM64_RUNNER_TAG` is set, tiers run as a created user because
the container is root and the dry tier refuses a uid-0 target). gitleaks runs on both with this
repo's `.gitleaks.toml`; the GitHub action needs `GITLEAKS_VERSION` **without** a leading `v`.
Rehearse any CI change in a stock container first: `docker run --rm -v "$PWD":/repo:ro
ubuntu:24.04` + a non-root user + git/curl/xz + the pinned tarball is all it needs.

## Layout

- `.zshrc`, `.p10k.zsh`, `.gitconfig`, `.tmux.conf`, `.config/…`, `.claude/…` — the dotfiles.
- `dotfiles.list` — the manifest; **the single source of truth** for the file set.
- `dotfiles-install.sh` — the one installer both entry points run (see the helper contract).
- `install.sh` — lightweight bootstrap.
- `provision/` — canonical full-machine replication; `provision.sh` is the entrypoint, steps in
  `provision/steps/`, manifests in `provision/packages/`, helpers in `provision/lib.sh`.
  Details in `provision/README.md`.
- `tests/` — the smoke tiers. `docs/` — design notes.

## Architecture

`provision.sh` sources `lib.sh`, then runs the steps in numeric order, tolerating per-step
failure and printing a summary. **Order is load-bearing:**

10-apt (base) → 20-apt-third-party (Docker/VSCodium/Cursor repos) → 25-docker-rootless
(`DOCKER_ROOTLESS=1` only) → 30-brew → 35-rust → 36-alacritty → 37-claude-code → 38-kitty →
50-flatpak (adds the Flathub remote) → 55-gnome-dconf (desktop only) → 60-shell →
80-next-steps → 85-versions-lock → 90-finalize (`GOLDEN_IMAGE=1` only).

- Step 80 writes `~/PROVISION-NEXT-STEPS.md` + a self-silencing MOTD pointer, so a golden clone
  still gets the manual follow-ups. Its text is `lib.sh`'s `next_steps_text()` — **that
  function owns the fact**, shared with provision.sh's end-of-run print, and branched on
  machine state (profile, desktop, whether rootless Docker actually came up).
- Step 90 leaves step 80's files and step 85's lock alone.
- There is **no snap step** — Alacritty, the only thing that wanted one, is built with cargo.
- `STEPS` in `provision.sh` is **hand-maintained, not a glob**: a new `steps/NN-*.sh` is inert
  until registered there, so the dry tier asserts both directions (no orphan file, no phantom
  entry).

`lib.sh` resolves a non-root `TARGET_USER`, because cloud-init runs as root but Homebrew,
oh-my-zsh, rustup and Claude Code refuse to (or shouldn't) run as root. An explicitly set
`PROVISION_USER` **must exist or lib.sh dies** (catching a cloud-init typo before the wrong
account is provisioned; `--dry-run` only warns). Unset, it falls back `SUDO_USER` → uid 1000 →
`ubuntu`, and **the fallback result is checked too** — no non-root user at all is a `die`, not
an empty `TARGET_HOME`. This repo **never creates users**; cloud-init's `users:` owns that.

### Editing step scripts — the helper contract

Every mutating action goes through a `lib.sh` helper, so `--dry-run` stays accurate and runs
stay non-interactive and idempotent. Calling `apt-get` or `curl … | sudo tee` directly
silently breaks `--dry-run`.

- **Nothing runs as root against `$TARGET_HOME`.** A root `mkdir`/`chown`/`cp`/`rm`/`tar`/`tee`
  through a path the user controls follows a planted symlink. Every write into a home goes
  through `as_user`; the dotfile set is installed by `dotfiles-install.sh` (refuses uid 0 and
  any symlinked parent); kitty extracts and swaps as the user; step 80 pipes its text through
  `as_user`'s stdin; finalize scrubs each home **as that home's owner**. Root may *read* a home
  (finalize's verify) but never writes one, and never executes a user-owned binary. The dry
  tier greps the steps for `$SUDO` + a home path on one line and fails on any.
- `run <cmd>` — run it, or print `[would] …` under dry-run.
- `apt_get <args>` / `apt_install <pkgs>` — non-interactive apt (real status / tolerant),
  wrapped in `env` so noninteractive + needrestart survive `sudo`, with `--force-conf*` and
  `DPkg::Lock::Timeout=600`. **A bare `apt-get` is interactive and will hang a build** — the
  dry tier rejects it in command position in any step.
- `as_user <cmd>` — run as `$TARGET_USER` via a **non-login** `sudo -u … bash -c` shell
  (deliberately: a non-interactive login bash runs `~/.bash_logout`, which fails without a tty
  and corrupts exit status). Sourced `lib.sh` functions are out of reach inside it — which is
  why `pins.sh` is also runnable as a command.
- Anything with pipes or redirects: guard by hand — `if dry; then would "…"; else …; fi`.
- `log`/`warn`/`die` for output; `dry`, `is_root`, `$SUDO`, `load_brew`, `gui_wanted`,
  `stale_warn` are also provided. `warn` records to `$WARN_LOG` and every tolerated warning is
  listed in the end-of-run summary, so "no failures" never hides "and three things were
  skipped".

### Terminals — two, installed differently on purpose

- **Alacritty (step 36) is built** with `cargo install --locked`: upstream ships no Linux
  binary at all. Its terminfo, `.desktop`, icon and shell completions come from the **crate**
  — re-fetched from crates.io and verified against the sha256 in the sparse index (the same
  checksum cargo used), never from a raw GitHub URL: the zsh completion is code every shell
  sources, installed system-wide.
- **kitty (step 38) is installed from upstream's signed `.txz`**, verified two ways: the
  fail-closed `verify_keyring` fingerprint pin, **plus** `gpg --verify --assert-signer
  "$KITTY_FP"` on the tarball. The second is not redundant — see the design notes. A mismatch
  **skips** the install; it never falls back to unverified. An old gpg without
  `--assert-signer` refuses rather than verifying unbound.
- Both **pin the font themselves** (`alacritty.toml`, `kitty.conf`) — kitty does not read
  GNOME's `monospace-font-name`. kitty's `window_padding_width` is in **points**.
- kitty's colour theme is a **vendored** file with provenance + licence in its header (data, so
  vendored like the font — never `kitten themes`, which fetches at run time). Local overrides
  go *after* the `include`.
- `kitty.conf` mirrors `alacritty.toml` including the security-relevant pair:
  `clipboard_control write-clipboard write-primary` (OSC 52 reads refused outright, stricter
  than kitty's default) and `update_check_interval 0`.
- Step 38 deliberately does **not** write `~/.config/xdg-terminals.list` — which terminal is
  default is a user preference. Both are pinned in the dock; both skip when no GUI is wanted
  (`gui_wanted`).

### Ported dotfiles & configs

`install.sh` and step 60 install the same set into `$HOME` through the same script,
**`dotfiles-install.sh`** (as the user). The set is listed **once** in `dotfiles.list`, which
both read, so they cannot drift: shell + git + tmux dotfiles, the Alacritty and kitty configs
(+ the vendored kitty theme), the whole `.config/nvim/` LazyVim tree (`lazy-lock.json`
excluded so plugins track latest), the tool configs (`.config/git/ignore`, `atuin`, `lazygit`,
`bat`), and the two tracked `.claude/` files. Entries may be files or whole directories; the
repo mirrors `$HOME` layout.

- Every tool-dependent line is `command -v`-guarded and every config file is inert without its
  tool, so the same set ships to `PROFILE=minimal` and a lean shell starts silently.
- **Ordering that matters in `.zshrc`:** `$EDITOR` is set *after* brew's shellenv (nvim is a
  brew binary), and fzf is sourced *before* atuin so atuin keeps Ctrl-R. The dry tier asserts
  the fzf/atuin order and parses `.zshrc`, `.gitconfig` and `.tmux.conf` with their own tools.
- `.config/lazygit/config.yml` must stay on the **current** lazygit schema — lazygit rewrites
  an old-schema file in place, which copy-mode `verify` then reports as drift.
- Default is **symlink** (repo stays the source of truth); `DOTFILES_COPY=1` /
  `install.sh --copy` / `GOLDEN_IMAGE=1` **copy** instead (self-contained). Copy mode is
  sticky — a later plain run leaves identical copies alone.
- The Alacritty **theme repo is cloned** (pinned), the **MesloLGS NF font is vendored** (no
  apt/brew package exists for it on Linux/arm64).
- GNOME settings live in `provision/gnome/dconf-settings.ini`, applied by step 55 only with
  `INSTALL_DESKTOP=1`. Its `favorite-apps` ids must be the ids of the apps **this repo
  provisions** — a stale id is silently dropped by GNOME, which is how a dock ends up missing
  an app.
- `.claude/settings.json` is installed from the repo but **owned by Claude Code afterwards**
  (it rewrites runtime preferences), so `v_mode` asserts its presence, not its content —
  exactly like `.config/nvim`.
- `.gitignore` keeps `.claude/` out **except** those two tracked files, and blocks the AI/API
  token files (`**/auth.json`, `**/.credentials.json`, `.claude.json`, `.codex/`, …).
- Configs with hardcoded `/home/<user>` paths are templated to `$HOME`, so they survive a
  different target username.

## Modes (env flags)

Full table with defaults and how they combine: **`provision/README.md#flags`**. What matters
when editing code:

- `--dry-run`/`-n` — preview only: no changes, no sudo, no network.
- `INSTALL_DESKTOP=1` — desktop/locale/IME apt set + the GNOME dconf step.
- `APT_UPGRADE=1` — `apt-get upgrade` what is already installed, before installing (step 10).
  Off by default. Uses `upgrade`, never `full-upgrade`, so **no new kernel package names**.
- `GOLDEN_IMAGE=1` — build a reusable image: implies **STRICT** (first real failure aborts) and
  copy-mode dotfiles, and runs finalize (step 90), which scrubs machine identity and **every
  account** (uid ≥ 1000 + root, each as its owner): credential stores, private keys,
  `authorized_keys` **always** (no keep branch, no flag), dotfile backups, Docker auths — then
  a verify that fails the build on any residue under `/home` or `/root`. A failed
  `rustup update`/`brew update` is a `soft_fail` here, not a warning: stale toolchains must not
  bake into every clone. **Destructive — throwaway build box only.** Clone the repo and write
  run logs under `/tmp`; finalize wipes `/tmp` last and warns about a leftover repo or `*.log`
  in `$HOME`.
- `GOLDEN_POWEROFF=1` — finalize powers the box off as its **last** action, so nothing is typed
  after the scrub. Recommended for every golden build.
- `DOTFILES_COPY=1` — copy dotfiles without the rest of golden mode.
- `PROFILE=minimal` — lean agent box: GUI steps skip, step 20 drops the GUI editors (**Docker
  stays**), steps 10/30 swap in the minimal manifests. Validated (`full|minimal`, else die) and
  **conflicts with `INSTALL_DESKTOP=1` (die)**.
- `HEADLESS=1` — the **full** manifests with **no GUI installs**: a second axis, not a third
  profile. `PROFILE` picks the manifests; `gui_wanted` (`! minimal && HEADLESS != 1`) gates
  every GUI install, with `no_gui_reason` supplying the skip marker. A new GUI step needs one
  line: `gui_wanted || { log "x: skipped ($(no_gui_reason))"; exit 0; }`. Conflicts with
  `INSTALL_DESKTOP=1` (die).
- `DOCKER_ROOTLESS=1` — rootless Docker for the target user (step 25). Needs unprivileged user
  namespaces; soft-fails where AppArmor restricts them (rootful still works). Do **not** also
  `usermod -aG docker` — that is the root-equivalent path.
- **Failure handling:** tolerant helpers call `soft_fail` → warn + record; a normal run
  finishes every step but exits non-zero if any soft failure occurred. Under `STRICT`/
  `GOLDEN_IMAGE` a soft failure **dies** immediately. `lib.sh` refuses a uid-0 target user.

## Commits

- **The author and committer are always the repository owner** (`codezero`) — an agent never
  commits under its own name. An agent's share of the work is recorded in **trailers**, so
  `git log --format='%an'` answers "whose machine spec is this" and `%(trailers)` answers "who
  wrote this commit":

  ```
  Co-Authored-By: Claude <model> <noreply@anthropic.com>
  Claude-Session: <session URL>
  ```

  Add both when an agent did the work; omit them when it did not. The same applies to a PR
  description. Never set `user.name`/`user.email` to anything else for a commit.
- **Style is owned by [`CONTRIBUTING.md`](CONTRIBUTING.md#commit-messages)** — `type(scope):
  imperative outcome — the reason`, a body that gives the *why* and the evidence (which tiers
  ran and their counts, what was mutation-checked, which live scenario was used), and an
  explicit note of what was **not** verified. Don't restate that style here.
- **Don't commit on a red tree.** `lint` and `dry` pass before a commit that touches a script;
  if something is knowingly left failing, the commit message says so in as many words.
- **One commit per reviewable idea.** A refactor and the behaviour change it enables are two
  commits, so a bisect can tell them apart.

## Conventions / gotchas

- `provision.sh` is cloud-init-ready: root, idempotent, failure-tolerant. `apt_preflight`
  pauses Ubuntu's apt-daily timers for the run (they hold the dpkg lock on a fresh boot) and
  **waits a bounded time** for any in-flight run; a normal run restarts them at the end
  (`apt_preflight_restore`) — a golden build is captured instead, and the enabled timers return
  at the clone's first boot.
- Step 10 filters boot/kernel/third-party/desktop out of `apt.list` at install time (the list is
  the full `apt-mark showmanual` export on purpose). `provision/boot-pkgs.sh` is the **one
  owner** of "boot package", shared with `versions-lock.sh --ignore-boot`.
- Step 20 owns Docker/VSCodium/Cursor in **key → verify → repo → install** order. Every repo
  add is gated on a pinned, verified signing key; a mismatch `soft_fail`s and skips that vendor
  rather than adding a half-configured repo. Its index refresh (`vendor_apt_update`) touches
  **only that vendor's source file**, retries, and on persistent failure warns even under
  STRICT — a vendor CDN hiccup must not abort a golden, while a genuinely missing package
  still does (the `apt_install` right after soft_fails).
- Step 30 filters the Brewfile to `tap`/`brew`/`cask` lines. **Casks are kept** (Linux-capable
  ones install on linuxbrew arm64; macOS-only fail soft). Homebrew is hardcoded at
  `/home/linuxbrew/.linuxbrew`.
- `bat` must come from **brew** — apt's binary is `batcat` and breaks `.zshrc`'s alias.
- **Never committed** (see `.gitignore`): SSH/GPG keys, `~/.claude/` state, cloud creds, shell
  history. `.gitconfig` ships a placeholder identity.
- **License: AGPL-3.0-only.** `LICENSE` is the verbatim FSF text — **never edit it**; GitHub's
  detection needs it byte-exact. README's `## License` owns the copyright notice and the
  plain-English summary. Vendored components keep their own licences (`fonts/MesloLGS-NF/` and
  `.config/nvim/` Apache-2.0 with their own files, `.p10k.zsh` from powerlevel10k (MIT), the
  kitty theme MIT) — never relicense them or strip those notices.
- **Pins: code that EXECUTES at install time is pinned in `provision/pins.sh`** — one owner
  sourced by `lib.sh` and `install.sh`, also runnable as a command because steps call it inside
  `as_user`. Covered: Homebrew's installer (commit + sha256), `rustup-init` (versioned archive
  + in-repo hash per arch — **it must be saved under its own name; rustup dispatches on
  argv[0]**), Claude's bootstrap, and the three shell-code clones. Both helpers **refuse on
  mismatch** and never fall back.
  - **Bumping a pin is a commit, never a run-time fetch.** `bash provision/pins.sh bump
    [--check] <name>|all` is that act as one command: it prints the review (upstream log /
    script diff / version), rewrites the pin line, converges the local checkout and stages the
    file — you read it and commit.
  - `clone_pinned` is idempotent and **converging**: a no-op at the pin, otherwise it moves the
    checkout to the pin (untracked content such as omz's `custom/` survives); it refuses a
    checkout whose *tracked* files were edited, and refuses (never wipes) a non-checkout dir.
    Every site calls it on every run — the sentinel file is a post-condition, not a gate.
  - **The pin owns `~/.oh-my-zsh`, not omz's updater.** `.zshrc` routes `omz update` to the
    bump and sets the reminder to the cadence interval.
  - This is a security control, distinct from the bring-to-latest *tool* policy.
    `provision/README.md#supply-chain` owns the fact and the monthly, observed cadence.
- **Secret scanning:** `gitleaks` (in the Brewfile) scans content as defence in depth beyond
  the filename-based `.gitignore`. A versioned pre-commit hook lives in `.githooks/` — enable
  per clone with `git config core.hooksPath .githooks`. CI scans full history.

## Open TODOs

Closed work is summarized in [`docs/DESIGN-NOTES.md`](docs/DESIGN-NOTES.md); the owner also
keeps a verbatim log in `CLAUDE.local.md` (gitignored — hand-carried between machines with
`~/.claude/projects/…/memory/`).

**No open TODOs.** Every scenario in `smoke-test.sh scenarios` has run on real hardware; the
last two (cloud-init × `PROFILE=minimal`, and `install.sh` bare metal) closed 2026-09-24.

One harness nit is parked rather than filed: `verify`'s `cursor debconf preseed (needs sudo)`
check skips on an adopted clone even right after `sudo -v`. It is desktop-only — the minimal
box never installs Cursor — so the live runs could not chase it. Find out rather than accept
the skip, next time a desktop clone is in front of you.

## Project direction & philosophy

- **Two entry points, both first-class:** `install.sh` = shell + dotfiles on an existing box;
  `provision/` = full machine / cloud-init / golden image. They share the set via
  `dotfiles.list` and install it with the same script.
- **Bring-to-latest is intentional, not a gap.** brew, `cargo install`, rustup, Claude and
  Cursor channels all float. "Reproducible" here means *re-runnable to the same state* and
  **recorded** (`versions.lock`) — not version-pinned. Don't add default version pins for
  *tools*. The exception is deliberate and separate: code that *executes* at install time is
  pinned in `pins.sh`, as a security control. Bit-for-bit pinning, if ever wanted, belongs in a
  separate layer on top — that layer was evaluated and declined (design notes).
- **The dual role is permanent:** (1) fresh Ubuntu → clean, credential-free state — no golden
  is built from the owner's daily box, because it holds credentials; (2) a re-runnable
  bring-to-latest layer over an existing image.
- **No creds/PII ever** — enforced by `.gitignore`, the names-only inventory export, and
  finalize's fail-closed audit.
