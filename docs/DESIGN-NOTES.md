# Design notes — why this repo is the way it is

This repo turns a fresh Ubuntu 26.04 into a working machine, and it is deliberately plain Bash.
Most of what follows was learned by **running it on real hardware and finding out**, which is
also why so much of the code is commented with a *reason* rather than a description.

`CLAUDE.md` and `provision/README.md` hold the **rules** — what a change must not break.
This file holds the **record**: what was built, what it cost to get right, and what was
deliberately not done. It exists because the repo was re-published from its last state
(2026-09) without its commit history; four months of `git log` and the owner's engineering
log are in a private archive, and everything below is what was worth carrying out of them.

---

## The two roles, and why they never merged

1. **Fresh Ubuntu → clean, credential-free machine.** A golden image is *never* built from the
   owner's daily box, because that box holds credentials. Credentials land on a clone
   afterwards, by hand.
2. **A re-runnable bring-to-latest layer** on top of an existing image, to keep it current.

Everything else follows from those two. Re-running must be safe (idempotent), a build must be
able to fail loudly (`STRICT`), and "reproducible" means *re-runnable to the same state and
recorded* — not version-pinned. See `provision/README.md#versions--recorded-not-pinned`.

---

## Golden images: the generations

Each generation is a full desktop image, built on a **throwaway** box from a reviewed commit,
captured, and then audited on a **booted clone** (`smoke-test.sh verify S8`). A generation's
value is what it proved and what it broke.

| Gen | When | Built with | What it proved / found |
|---|---|---|---|
| **Gen-1** | 2026-05-25 → 05-27 | `GOLDEN_IMAGE=1`, later `+INSTALL_DESKTOP=1` | First strict build. Both the pass *and* the abort proven: an unreadable credential (`chattr +i`) made finalize `die` instead of capturing a dirty image. Found three live-only bugs — `as_user` corrupting exit status through a login shell, dry-run text leaking into a real run, completions installed 0600 so `compinit` refused them. |
| **Gen-2** | 2026-06-07 | re-run *on* a Gen-1 clone | The iterate-on-golden path: a re-run reaches `Finalize done`, the post-provision notes survive the wipe, copies stay copies. The trap it taught: a manual re-run on a golden **must** keep `GOLDEN_IMAGE=1`/`DOTFILES_COPY=1`, or it symlinks over the copies. |
| **Gen-3** | 2026-09-12 | `+INSTALL_DESKTOP=1` | First image whose clone was audited live rather than by hand: 67/70. The dock lacked Alacritty because the GNOME favourites still named the *snap* id from a box that no longer existed — the exact drift the dogfooding exists to kill. Also: the SSH-host-key check assumed sshd, and `~/.gnupg`/atuin are legitimately recreated at first login. 84/84 after the fixes. |
| **Gen-4** | 2026-09-13 | `+APT_UPGRADE=1 +GOLDEN_POWEROFF=1` | First image with the versions lock emitted **in-build** and every install-time script pinned. First clone to pass its first-boot audit clean: 95/95, zero drift against the lock written inside the build. It took two attempts — see the needrestart and atuin entries under Gotchas. |
| **Gen-5** | not built | — | Will be the first with the 2026-09-22 security model (nothing root-side writes `$HOME`; finalize fail-closed for every account). |

The daily desktop has been a clone of the current generation since Gen-3 — the repo is
developed on a machine it built. That removed a standing caveat from every test note ("the dev
box is old and is not a verification target") and immediately surfaced three bugs that only a
real desktop session shows (kitty's font fallback, a tripled prompt glyph, a missing git
credential helper).

---

## Live-test record

Every scenario below ran on real hardware — `smoke-test.sh scenarios` prints the current
runbook and the audit each one maps to. The point of the table is what each *found*.

| # | Scenario | Found |
|---|---|---|
| S1 | lint + dry tier | (the pre-commit gate itself) |
| S2/S3 | plain run, then re-run | idempotence; a non-login `as_user` shell is required — a login shell runs `~/.bash_logout`, which fails without a tty and corrupts the step's exit status |
| S4 | desktop | `apt_preflight`'s wait for the background updaters was **unbounded** and could hang longer than the problem it solved; the Nerd Font was installed but GNOME's `monospace-font-name` never pointed at it, so the stock terminal drew tofu while Alacritty looked fine |
| S5 | rootless Docker | a context *named* `rootless` proves nothing — the audit has to read `docker info` (`SecurityOptions`, `DockerRootDir`) |
| S6 | copy mode | "the run logged the word copy" is not evidence; only a byte-for-byte comparison is |
| S7/S8 | golden, golden-desktop | see the generations above |
| S9 | iterate on a golden | the keep-the-flag trap (Gen-2) |
| S10 | `install.sh` | a redirected run parked on an **invisible** sudo prompt (sudo reads the tty, prints to stderr) — hence the explicit `[0/7]` priming; and the tmux plugin nagged on every shell start because the bootstrap shipped `.tmux.conf` without tmux. Re-proven bare-metal later: **it needs its own box** — Homebrew is one owner per prefix, so a second user on someone else's provisioned box cannot get past `[5/7]` |
| S11/S14 | `PROFILE=minimal`, ± rootless | the lean box keeps Docker on purpose; `command -v` guards in `.zshrc` are what make it start silently |
| S12 | `APT_UPGRADE=1` | "N packages can be upgraded" never reaches zero, by design — see Gotchas |
| S13 | real cloud-init | cloud-init does **not** assign uid 1000 in `users:` list order; `chsh` works with no controlling terminal; a primary group ≠ username exercises code that had never run |
| S13×S11 | cloud-init **and** `PROFILE=minimal`, one box | the versions lock had **no `repo:` field**: it is emitted as the target user, and git refuses to parse a repo owned by someone else — under cloud-init the repo is root-owned in `/opt`, so the one field saying *which commit produced this* silently vanished. Only this path could show it; four months of desktop runs never did |
| S15 | `HEADLESS=1` | the full CLI set with every GUI install skipped — one `gui_wanted` gate, not a third profile |

**Every scenario in that table has now run on real hardware**, most recently the two that had
drifted furthest behind the code (cloud-init and `install.sh`, 2026-09-24). The pattern worth
keeping: each live run since has found exactly one defect, and never the one that was expected —
which is the argument for running them at all rather than reasoning about them.

A second pattern produced most of the guards in `tests/`: **writing a rule down precisely is
what exposes that nothing enforces it.** It happened at least six times — two flags documented
in the table but missing from the typo guard, composition rules stated in the runbook but not
refused by `verify`, a "boot package" definition that lived in two places, the no-non-root-user
edge that turned out to need code rather than a sentence. The habit that follows: when a fact
gets written down, check the same commit that something goes red when it stops being true.

---

## Decisions, and what would reopen them

- **Plain Bash, no build layer.** Packer and chezmoi were evaluated in detail and declined.
  Packer is *mismatched*, not merely unnecessary: finalize deletes the SSH host keys and wipes
  `/tmp` as its last acts, so a build driven over SSH would destroy its own transport, and the
  audit that matters runs on a **booted clone**, which no build-time provisioner can do.
  chezmoi would replace the one mechanism proven in every scenario and would cost `install.sh`
  its "git is the only dependency" property. *Reopen if*: images must be built unattended from
  CI (write a shellcheck'd Bash script, not HCL), or two machines need genuinely different
  dotfile **content** rather than different file sets.
- **No `PIN_VERSIONS=1` mode.** Homebrew cannot be version-pinned — versioned formulae exist
  only where a maintainer made one, `brew pin` only freezes what is already installed, and the
  Brewfile has no version field. A flag that *reads* as reproducible while the largest group
  floats underneath is worse than no flag. The honest claim is "this commit, built on this
  date, produced these versions" — which is what `versions.lock` records.
- **Code that executes at install time IS pinned** (`provision/pins.sh`) — installer scripts
  and the shell-code clones that run in every shell. That is a security control, not a version
  policy, and the distinction is deliberate: *tools* float and the lock records them.
- **Homebrew attestations: documented, not enabled.** Verification needs a GitHub token;
  a credential-free build box has none, so enabling it would break every golden. `brew verify`
  post hoc is documented instead.
- **No inventory exporter.** `inventory-export.sh` regenerated `apt.list`, `flatpak.list` and
  the `Brewfile` from `apt-mark showmanual` and `brew bundle dump`. It was deleted once
  re-running it had come to make the lists strictly worse. Measured on the daily box, it took
  `apt.list` from 65 entries to 95, and all thirty additions were noise: the Essential/required
  set its own header promised to exclude, that box's kernel ABI, the build dependencies step 36
  installs itself, and step 20's rootless prerequisites — while silently dropping a real entry
  that no live state could justify. It also flattened the Brewfile's per-tool rationale
  comments into Homebrew's generic blurbs. Underneath sat a genuine bug: `sort` under a UTF-8
  locale ignores the hyphen, so `ibus-table-cangjie-big` sorts after `…cangjie5` while `comm`
  compares bytes, and both subtractions stopped working from the first mismatch onward. The
  lists had quietly stopped being an export and become curated inputs. What is lost is real and
  small: nothing now notices a package installed by hand months ago and never written down —
  but at thirty noise lines to zero real ones, the script was not delivering that signal
  either. *Reopen if*: the lists must track a machine automatically rather than be chosen — in
  which case it needs `LC_ALL=C` on every sort and a pruning pass, not a revert.

- **Dependencies are recorded, not named.** `apt.list` holds what to *ask for*; apt resolves the
  rest. Naming the closure there would be actively wrong — anything named gets installed and
  therefore marked `manual`, which permanently defeats the `apt-get autoremove` finalize runs —
  and it would duplicate a resolver that already does the job. But the lock's claim is "what
  landed", and until 2026-09 it covered 64 of a real box's 1,882 packages: `cursor` has 29 direct
  dependencies and exactly one was recorded, so a generation diff could not see a library move.
  The defence that `apt.list` is "pinned by the Ubuntu release" holds for the archive at a point
  in time and not at all for Docker, VSCodium and Cursor, which come from vendor CDNs. Hence a
  `dep` kind: every installed package not already recorded, **reported and never asserted**, on
  the `--ignore-boot` precedent that some rows are somebody else's to bump. *Reopen if*: the dep
  section starts being read as an install list, or someone wants a true closure rather than
  "what is installed" — the latter is a different claim and should get a different kind.
- **The git identity stays in the tracked `.gitconfig`.** It is the owner's, and a placeholder
  that refuses to commit would only add ceremony.
- **No tmux session persistence, no btop config.** Persistence would add two more pinned clones
  and a footgun (its autosave can recreate files *after* the golden scrub) for something the
  terminal's own tabs cover; btop rewrites its config on every exit, which would make a
  symlinked repo copy churn.
- **No snap.** Alacritty — the one thing that wanted it — is built with `cargo install`, so the
  machine needs no snapd at all. A pleasing side effect: snap's confinement was what blocked
  the AI agent's sandbox on the old box.
- **No `KEEP_AUTHORIZED_KEYS` escape hatch.** A golden keeps no access material for any
  account. A cloud clone gets its keys back from cloud-init; a local clone is logged into at
  the console first.

---

## Gotchas that outlive the code

- **A bare `apt-get` is interactive.** With a newer kernel installed than the one running,
  needrestart draws a dialog — into `/dev/null` if stdin was detached — and the build hangs
  forever. Everything goes through the `apt_get` wrapper; the dry tier rejects `apt-get` in
  command position in any step.
- **`apt-get upgrade` never installs a new package *name*,** so a kernel ABI bump (a new
  `linux-image-…` name every time) is held back by design, and Ubuntu's phased updates hold
  back another slice. "N can be upgraded" reaching zero is not the goal.
- **A shell with `atuin` records at pre-exec** — including the `poweroff` you type after the
  scrub, which recreates the history database *inside* the image. `unset HISTFILE` never
  covered that. `GOLDEN_POWEROFF=1` exists so nothing is typed after finalize at all.
- **`unshare --user --map-root-user true` is a false OK** for user namespaces on 24.04+:
  Ubuntu ships an AppArmor profile for `unshare`, and the restriction strips capabilities
  *inside* the namespace rather than denying its creation. Read
  `/proc/sys/kernel/apparmor_restrict_unprivileged_userns` instead.
- **Never run an Electron app's `--version` in a headless audit** (VSCodium, Cursor) — it can
  hang with no output. Use `dpkg-query -W`.
- **`gh`'s token lives in the system keyring,** not in `~/.config/gh`. Copying that directory
  to a new machine carries the account name and nothing else; `gh auth login` is a per-machine
  step, and until it runs `git push` fails through the credential helper.
- **kitty's `window_padding_width` is in points, not pixels** — copying Alacritty's numbers
  makes the window a third roomier than intended. kitty also ignores GNOME's monospace font
  setting, so it has to pin the family itself.
- **lazygit rewrites its own config** in place when the schema changes, which shows up as
  drift on a copy-mode box. Keep the shipped file on the current schema.
- **ssh forwards `TERM`, not the terminfo behind it.** A modern terminal sets `TERM` to its own
  name, so connecting from kitty to a box with no `xterm-kitty` entry makes every ncurses tool
  there fail with "unknown terminal type" — `less`, `vim`, `clear`, and the prompt's own
  probing. What a box needs is therefore decided by the *client*, and is independent of which
  terminal (if any) the box has: it belongs in the apt lists, not in a terminal's install step.
  The first fix missed this twice — it reached for `kitty-terminfo` while the signature-verified
  kitty tarball already carried a newer copy, and it left `install.sh`, the entry point most
  likely to be run on a box you only ever ssh into. `ncurses-term` turned out to cover
  alacritty, wezterm and foot already; Ubuntu has no ghostty entry at all, and never will for
  whatever ships next — that case is the client's (`infocmp -x … | ssh host 'tic -x -'`).
- **An audit that *replaces* another inherits none of its later checks.** `verify installsh`
  deliberately does not run `v_core` — install.sh installs about nine fewer things — so a check
  added to `v_core` silently does not apply to an install.sh box, which is the shape most likely
  to be reached only over ssh. That is how S10 scored 28/28 on a box that answered "unknown
  terminal type" at every prompt for the person who connected to it. Shared checks now live in
  their own function that both audits call, with a dry-tier assertion that they still do.
- **A per-user `~/.terminfo` hides a missing system entry.** Step 36 used to `tic` Alacritty's
  entry into `$TARGET_HOME`, which covered exactly one account: a second user, or root via
  `sudo -i`, had nothing, and the invoking user's own copy made every check look green. Audits
  of system-wide state have to probe with `env -i`, or they pass off the one home that happens
  to be populated. `~/.terminfo` is the user's space and the repo no longer writes it.
- **A regex built in `awk -v` is not portable across mawk versions.** A test guard that
  extracted a shell function with `awk -v f="^name\(\) \{"` matched on Ubuntu 26.04's mawk
  and matched *nothing* on 24.04's, so the guard reported every function as missing its call —
  green locally, red on both CI runners, and not reproducible on the machine that wrote it. In
  a POSIX sed BRE `(`, `)` and `{` are literal and need no escaping, so `sed -n "/^name() {/,
  /^}/p"` has nothing left to differ. The wider rule this repo already states and that pass
  ignored: rehearse anything CI-visible in a stock `ubuntu:24.04` container first.
- **`setsid` does not simulate cloud-init** — `logname` resolves from the audit loginuid, which
  survives it. Only a systemd unit (or real cloud-init) has none.

---

## Security model

Two external assessments (2026-09-08, 2026-09-22) shaped the parts of this repo that look
paranoid. What they changed:

- **Identity pins must bind the check.** kitty's release is verified by signature, and the
  pinned fingerprint is passed to `gpg --assert-signer` at the call site. Without that, a key
  file with the real key *first* and an attacker key **appended** passed the pin and then
  validated a tarball signed by the appended key — the pin would have constrained nothing.
- **Nothing root-side writes into `$HOME`.** A root `chown`/`cp`/`rm`/`tar` through a path the
  user controls follows a planted symlink (`~/.config → /etc` turns `chown user ~/.config`
  into `chown user /etc`). Every write into a home goes through the user; `dotfiles-install.sh`
  is the single installer both entry points run, and it refuses uid 0 and any symlinked parent.
  Root may *read* a home (the finalize audit) but never writes one, and never executes a
  user-owned binary.
- **Finalize is fail-closed and covers every account** — each uid ≥ 1000 plus root, scrubbed as
  its own owner, `authorized_keys` always removed, and a verify pass that fails the build on
  any credential, private key, dotfile backup or registry auth left anywhere under `/home` or
  `/root`. Proven against planted credentials in a container, including a private key outside
  every list, which the whole-image sweep caught.
- **A pin means the code, not the label.** A checkout sitting at the pinned commit with locally
  modified tracked files is refused rather than silently accepted or silently reset.

The limits that remain, stated plainly: nothing here defends against a malicious *upstream
release* except lag (re-provision on a monthly, observed cadence — never a cron), and nothing
short of freezing homebrew-core defends against a malicious formula. What the repo does is
narrow the surface from "trusts four moving branches at execution time" to "trusts reviewed
commits and checksums", and make everything else **visible** — which is what `versions.lock`
is for.
