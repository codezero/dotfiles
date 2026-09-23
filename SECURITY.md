# Security policy

This repo provisions a whole machine: it adds third-party apt repositories, installs software
**as root**, and builds images that other machines are cloned from. That is a large blast
radius for a personal project, so reports are genuinely welcome.

## Reporting a vulnerability

Use GitHub's **[Private Vulnerability Reporting](https://github.com/codezero/dotfiles/security/advisories/new)**
(Security → Report a vulnerability). It keeps the report private until there is a fix, and it
needs no email address from either of us. **Please don't open a public issue for a
vulnerability** — ordinary bugs are fine in Issues.

Useful in a report: the file and line, which run mode it applies to (`--dry-run`, a normal run,
`GOLDEN_IMAGE=1`, cloud-init), and what an attacker would need to control — a network position,
an upstream host, a local account, a file in `$HOME`. A rough proof beats a precise theory.

This is one person's side project: expect a first reply in days, not hours, and a fix when a
fix is possible. Credit in the commit if you want it; there is no bounty.

## What is in scope

The provisioning path, roughly in order of how much I care:

- **Local privilege escalation** — anything that lets the target user (or a file they control)
  get root during a run. Root never writes into `$HOME`, never follows a path the user owns,
  and never executes a user-owned binary; a hole in that is the most serious thing here.
- **Credentials surviving into a golden image.** `GOLDEN_IMAGE=1` must leave no credential,
  private key, `authorized_keys`, dotfile backup or registry auth in *any* account, and the
  build must **fail** rather than capture a dirty image.
- **Unverified code execution at install time.** Every installer script and every git clone
  this repo executes is pinned by commit or sha256 in `provision/pins.sh`, and the helpers
  refuse on mismatch rather than falling back. A path that executes something unverified — or
  that can be made to — is in scope.
- **Identity checks that do not bind.** apt signing keys and kitty's release signature are
  pinned by fingerprint and fail closed. A check that passes when it should not (for example a
  signature validated against the wrong key) is in scope even without a practical exploit.
- **`--dry-run` doing anything.** It must make no change, need no sudo and touch no network.

## What is out of scope (accepted, by design)

- **Bring-to-latest.** brew, `cargo install`, rustup toolchains, Claude and Cursor channels all
  float on purpose; a malicious *upstream release* will be installed, and the only defence is
  lag — re-provisioning on an observed monthly cadence, never a cron. Homebrew formulae cannot
  be version-pinned at all (see `docs/DESIGN-NOTES.md`).
- **Trust-on-first-use key pins.** Pinned fingerprints live in this repo, but the keys
  themselves were fetched over TLS once. A compromise that predates the pin is not detectable
  here.
- **"It installs software as root."** That is the stated purpose. Report a way to make it
  install *something else*, not the fact that it installs.
- **Anything requiring that you already have root** on the box being provisioned.
- **The owner's own configuration choices** — which packages are installed, that the tracked
  `.gitconfig` carries a placeholder identity, that Docker's rootful socket is root-equivalent.

## Already reviewed — please don't re-report

Each of these was raised, investigated and closed with a reason:

- **`chown -R` into a user-writable directory** is not symlink-planting escalation: GNU chown
  defaults to `-P` and does not dereference symlinks found during traversal (verified, not
  assumed). Most of these call sites are gone anyway, now that nothing root-side touches `$HOME`.
- **The loose version glob in the kitty step** (`[0-9]*.[0-9]*.[0-9]*`) does accept a traversal
  string, but `curl -o` creates no intermediate directories, so it dies on `ENOENT` before any
  write; the value is quoted everywhere and never `eval`ed. Anchoring it is hygiene, not a fix.
- **`verify_keyring` compares only the first key in a file** — which is why the kitty step
  *also* passes the pinned fingerprint to `gpg --assert-signer`, binding the signature to that
  key. Without the second check an appended attacker key would have validated a tarball; with
  it, it does not.

If you think one of those was closed wrongly, say so — that is a fine report.
