#!/usr/bin/env bash
# tests/scenarios.sh — part of the smoke tier. Sourced by ../smoke-test.sh, which owns the
# CLI; this file only defines functions. Split out of the single 1,350-line
# smoke-test.sh (2026-09-22) so each tier is readable on its own — the
# external assessment's last open item. Shared helpers: tests/lib.sh.

# ── scenarios runbook ───────────────────────────────────────────────────────
cmd_scenarios() {
  cat <<'EOF'
Live smoke scenarios (sunny-day set — fresh box unless noted).
After each live run:  bash smoke-test.sh verify S<n>   (e.g. `verify S4` —
the tokens it expands to, and how they compose, are listed at the bottom.)

 S1  dry            bash smoke-test.sh lint && bash smoke-test.sh dry     (any box)
 S2  plain          sudo env PROVISION_USER=$USER bash provision/provision.sh
                    -> verify S2
 S3  re-run         repeat S2; expect exit 0, idempotent     -> verify S3
 S4  desktop        sudo env INSTALL_DESKTOP=1 PROVISION_USER=$USER bash provision/provision.sh
                    -> verify S4
 S5  rootless       relax userns per ~/PROVISION-NEXT-STEPS.md, then
                    sudo env DOCKER_ROOTLESS=1 PROVISION_USER=$USER bash provision/provision.sh
                    -> verify S5
 S6  copy           sudo env DOTFILES_COPY=1 PROVISION_USER=$USER bash provision/provision.sh
                    -> verify S6
 S7  golden         sudo env GOLDEN_IMAGE=1 PROVISION_USER=$USER bash provision/provision.sh
                    (clone+log under /tmp!)  -> on a BOOTED CLONE: verify S7
 S8  golden-desktop S7 + INSTALL_DESKTOP=1   -> on a FRESHLY booted clone: verify S8
                    (first-boot audit: cred sweep + zero drift vs the image's
                    lock. Once the clone is ADOPTED — creds restored, upgraded —
                    audit it with `verify copy full desktop` instead.)
 S9  iterate-golden re-run S7/S8 ON a booted golden clone (MUST keep GOLDEN_IMAGE=1
                    or DOTFILES_COPY=1 — plain re-run would symlink over the copies)
                    [+ APT_UPGRADE=1 for a true bring-to-latest]   -> verify S9
 S10 install.sh     bash install.sh && exec zsh; re-run: must COMPLETE with NO
                    password prompt on the converged box (sudo + chsh both
                    skipped) and mint zero backups; --copy variant
                    -> verify S10   (installsh is its OWN contract and REPLACES
                    the core audit — not verify S2: install.sh ships no
                    tmux/rustup/claude/docker/step-80, and a 5-formula brew subset)
 S11 minimal        sudo env PROFILE=minimal PROVISION_USER=$USER bash provision/provision.sh
                    -> verify S11
 S12 bring-to-latest  sudo env APT_UPGRADE=1 PROVISION_USER=$USER bash provision/provision.sh
                    on a box already provisioned (S2/S3). Gates are PROSE, not a
                    verify token (upstream publishes updates constantly, so any
                    "0 upgradable" assertion would flap; `verify S12` audits the
                    box, not the upgrade): exit 0; `apt list
                    --upgradable` much shorter than before; note whether
                    /var/run/reboot-required appeared — provision.sh never acts
                    on it, and that is exactly what a user needs told.
                    EXPECT A NON-ZERO REMAINDER — it is not a failure. Step 10
                    runs `apt-get upgrade`, which (a) never installs a new or
                    removes an existing package, so kernel ABI bumps and library
                    transitions stay "kept back" BY DESIGN, and (b) does not
                    override Ubuntu's per-machine phased updates. Split the two
                    with:  apt-get -s upgrade   vs
                    apt-get -s -o APT::Get::Always-Include-Phased-Updates=true upgrade
 S13 cloud-init     REAL cloud-init user-data on a fresh box (not a manual sudo
                    run): root, no SUDO_USER, no tty, PROVISION_USER=<name>
                    genuinely load-bearing. -> verify S13   (run it as the
                    target user: sudo -iu <name> bash …/smoke-test.sh)
                    Also covers PROVISION_USER != the invoking user, which every
                    other scenario dodges by passing $USER.
                    user-data creates a SECOND user beside the image default:
                      users: [ default, {name: agent, uid: 1100,
                               primary_group: staff, groups: [sudo], …} ]
                    PIN uid EXPLICITLY. Listing `- default` first does NOT win
                    uid 1000 (live 2026-08-16: agent got 1000, ubuntu 1001) —
                    and if the target IS the uid-1000 user the whole point is
                    lost, because the explicit branch and the uid-1000 fallback
                    then pick the same account. primary_group != username is
                    deliberate: it is the only thing that exercises TARGET_GROUP.
                    Resolution is 3 rungs (lib.sh); prove them SEPARATELY with
                    --dry-run, which needs no root and changes nothing:
                      PROVISION_USER=probe …provision.sh --dry-run   -> probe
                      (interactive, no override)                    -> $USER
                      sudo systemd-run --pipe --quiet …--dry-run     -> uid-1000
                    NB `setsid` does NOT simulate cloud-init: logname resolves
                    from the audit loginuid, which survives it. Only a systemd
                    unit (or real cloud-init) has no loginuid.
 S14 minimal+rootless  relax userns, then
                    sudo env PROFILE=minimal DOCKER_ROOTLESS=1 PROVISION_USER=$USER \
                      bash provision/provision.sh   -> verify S14
                    (minimal KEEPS Docker on purpose — a headless agent box
                    running containers is a plausible daily configuration.)
 S15 headless       sudo env HEADLESS=1 PROVISION_USER=$USER bash provision/provision.sh
                    -> verify S15   (the shared human+agent box: FULL manifests —
                    btop/eza/bat/delta/atuin — with every GUI install skipped:
                    no cargo-built Alacritty, no kitty, no VSCodium/Cursor, no
                    flatpak, no font. Fast: nothing to compile.)

Covered live so far: S2/S3 (Phase A, C2), S5 (C2), S7 abort-gate (Phase B),
S8 (C Run 1), S9 (Phase D), S11 + S10 + S4 + S6 + S12 (2026-08-05),
S13 (2026-08-16, AWS t4g.large arm64, real Ec2 datasource),
S14 (2026-08-21, minimal+rootless), S15 (2026-09-12, HEADLESS=1: 38/38, zsh
silent with atuin+mise, all 5 new formulae run on arm64, mise the sole owner of
node 24 LTS + go 1.27), S10 RE-RUN (2026-09-12, install.sh with mise: 22/22;
first run's chsh failed on a mistyped password because sudo's cached timestamp
made it the only prompt -> dc1ff2d announces it; the converged re-run at
dc1ff2d completed with NO prompt — [0/7]/[1/7]/[7/7] all skipped — and 1
backup total, i.e. the idempotency half of S10 finally demonstrated).
Pending live (TODO K): S13×S11 — one cloud-init launch with PROFILE=minimal —
and an S10 re-run, both AFTER the J pins + step 85 landed (2026-09-13); the
desktop golden (Gen-4, b5a1856) proved the shared code, these prove the paths
it does not take. HEADLESS (S15) is pre-J too but differs only in skips.
Deliberately NOT a scenario: GOLDEN_IMAGE+DOCKER_ROOTLESS (bakes the userns
relaxation into the image — per-clone opt-in is the design).
EOF

  # Generated from scenario_tokens() — never hand-written, so the runbook above
  # and the audit vocabulary cannot drift apart (they did for 14 scenarios).
  echo
  echo "Verify vocabulary. \`verify S<n>\` expands to these tokens (echoed at run time);"
  echo "you can still pass tokens directly, and mix them: \`verify S11 rootless\`."
  echo
  local id toks
  for id in S2 S3 S4 S5 S6 S7 S8 S9 S10 S11 S12 S13 S14 S15; do
    toks="$(scenario_tokens "$id")" && printf '  %-4s = verify %s\n' "$id" "$toks"
  done
  cat <<'EOF'

The tokens are NOT peers — this is the part that was only ever in code comments:
  MODE (exactly one, and every scenario has one)
    plain          dotfiles are symlinks into the repo
    copy           dotfiles are real files (DOTFILES_COPY / GOLDEN_IMAGE)
    golden-clone   a FRESHLY booted clone: implies `copy`, adds the identity/credential
                   sweep. Don't pass `copy` as well — it's already in there.
  PROFILE (exactly one)
    full           asserts the full CLI set is PRESENT (bat/eza/zoxide/delta/atuin)
                   and — unless `headless` is also given — the GUI installs too
                   (codium/cursor/alacritty/kitty/font/flatpak)
    minimal        asserts the CLI extras AND every GUI install are ABSENT — the
                   lean box's whole claim is what it did NOT install
  ADD-ON (any number, order-free — they only add assertions)
    desktop        GNOME dconf settings, read back off the box
    rootless       docker context + user service + linger
    headless       (with `full`) the GUI installs are ABSENT — HEADLESS=1's box.
                   Redundant with `minimal` (dropped); contradicts `desktop`.
  STANDALONE (never combine)
    installsh      install.sh's own contract, and it REPLACES the core audit
                   rather than adding to it: no tmux/rustup/claude/docker/step-80

Everything except `installsh` runs the core audit first. With no arguments,
`verify` auto-detects mode+profile from the box and says what it picked.
EOF
}
