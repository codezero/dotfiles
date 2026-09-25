# Contributing

This is one person's machine spec, published because it is more useful in the open than in a
private repo. That shapes what contribution means here:

- **Forking is the main event.** Take it, change the package lists, delete the steps you don't
  want. `docs/DESIGN-NOTES.md` exists so you can diverge *knowingly* — it says why each thing
  is the way it is, and what was tried and rejected.
- **Bug reports are welcome**, especially "it broke on a fresh box". Say which recipe you ran,
  paste the failing step's output, and note the release and architecture.
- **Pull requests are welcome in a narrow band**: real bugs, Ubuntu-release breakage, a
  genuinely missing guard, or documentation that is wrong. Please open an issue first for
  anything larger — the answer to "add my favourite tool" is usually *fork it*, and that is not
  a brush-off.
- **Security issues go through [`SECURITY.md`](SECURITY.md)**, not Issues.

## Before you open a PR

```bash
bash smoke-test.sh lint      # shellcheck the tree
bash smoke-test.sh dry       # the --dry-run matrix + offline functional tests
bash provision/provision.sh --dry-run    # read what your change would actually do
```

Both tiers need no sudo, no network and change nothing, and CI runs them on every PR on arm64
and x86_64. If your change touches a step script, `--dry-run` is the review: it prints every
planned action.

**If you changed behaviour that only a real box exercises, say what you ran.** The dry tier
cannot prove a live path; `bash smoke-test.sh scenarios` lists the runbook (S1–S15) and the
audit each scenario maps to. "I ran S11 on a fresh 26.04 VM and `verify S11` was green" is
worth more than any amount of review.

## The rules a PR is checked against

These are not restated here — **[`CLAUDE.md`](CLAUDE.md) owns them**, and duplicating a rule is
how the two copies start to disagree. In short, it will be checked that:

- scripts are invoked with `bash` and stay non-executable;
- every mutating action goes through a `lib.sh` helper, or `--dry-run` silently starts lying;
- nothing runs as root against `$TARGET_HOME` — writes into a home go through the user;
- a new `steps/NN-*.sh` is registered in `STEPS` (it is inert until it is, and the dry tier
  fails both ways);
- `shellcheck -x` is clean at warning severity — run it from `provision/steps/` so the sourced
  `lib.sh` resolves. The remaining **info**-level notes are deliberate; don't "fix" them;
- docs keep **one owner per fact**: add a pointer, not a second copy. Tracked `*.md` must cite
  no commit SHAs (this repo was re-published without its history — they would resolve to
  nothing).

A new guard is welcome, and it should come with an assertion in the dry tier that goes **red**
when the guard is removed. Mutation-check it; an assertion that cannot fail is decoration.

## What will not be merged

- **Softening a guard to be friendlier.** Fail-closed is the point: a vendor whose signing key
  does not verify is skipped rather than half-configured, a strict build aborts, contradictory
  audit tokens are refused with exit 2, `PROFILE=minimal` with `INSTALL_DESKTOP=1` dies instead
  of guessing. Friendliness belongs in messages and docs, not in the rails.
- **Default version pins for tools.** Bring-to-latest is deliberate, and the lock file records
  what landed. Pinning *code that executes at install time* is the opposite case and already
  exists (`provision/pins.sh`) — extend that instead.
- **Fetching executable code at run time** without a pin and a refusal path. No `curl | sh`,
  no `git clone` of a moving branch; the dry tier rejects both.
- **snap.** The one thing that wanted it is built from source instead, so the machine needs no
  snapd.
- **Anything that puts credentials or personal data in the repo** — including a hostname or a
  username in a package list. The package lists and the versions lock hold names and versions
  only, for that reason.

## Commit messages

This repo's history is unusually explanatory on purpose: six months later, the reason is the
part nobody can reconstruct, and the diff is the part anyone can read. The house style:

```
type(scope): imperative outcome — the short reason it was needed

Why, not what: the failure it fixes or the property it adds, and the evidence
that it works — which tiers ran and their counts, what was mutation-checked,
which live scenario it was tested with, what is still unproven.
```

- **Subject** says the *outcome*, not the diff (`fix(finalize): apt through the wrapper — a
  bare autoremove hung the build`, not `change apt call`). Types in use: `feat`, `fix`, `docs`,
  `test`, `ci`, `security`, `pins`, `lock`; the scope is a step or file when one dominates.
- **Body** carries the reasoning and the proof. "Dry tier 213 → 215, mutation-checked" is worth
  more than three sentences of intent.
- **Say what you did *not* verify.** A commit that admits "the live path is unexercised" is
  worth more than one that implies otherwise.

## Licensing

Inbound = outbound: contributions are accepted under **AGPL-3.0-only**, the licence in
[`LICENSE`](LICENSE). Vendored third-party components keep their own licences and notices;
don't relicense them or strip their `LICENSE`/`NOTICE` files.

There is **no CLA to sign**, but one grant is asked for in exchange, and it is stated here
rather than buried: **by submitting a contribution you grant the maintainer a perpetual,
worldwide, irrevocable, royalty-free right to license your contribution under other terms**,
alongside the AGPL — you keep your copyright, and you keep every right you already had to your
own work.

Why ask at all: without it, changing this project's licence later would need the agreement of
every contributor whose code is still in the tree, so a single unreachable person freezes the
licence permanently. The grant keeps that door open without a signing ceremony on a repo whose
realistic volume is a handful of patches. It applies to contributions made after this text
existed; if you'd rather not give it, say so in the PR and we'll find another way — a narrower
fix, or leaving it out.
