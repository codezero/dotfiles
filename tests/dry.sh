#!/usr/bin/env bash
# tests/dry.sh — part of the smoke tier. Sourced by ../smoke-test.sh, which owns the
# CLI; this file only defines functions. Split out of the single 1,350-line
# smoke-test.sh (2026-09-22) so each tier is readable on its own — the
# external assessment's last open item. Shared helpers: tests/lib.sh.

# ── dry matrix ──────────────────────────────────────────────────────────────
# dry_case <desc> <expected-exit> [VAR=val ...] -- [pattern ...]
# Patterns are fixed strings; prefix '!' = must NOT appear in the output.
dry_case() {
  local desc="$1" want="$2"; shift 2
  local envs=() pats=() in_pats=0 a out rc p
  for a in "$@"; do
    if [ "$a" = "--" ]; then in_pats=1
    elif [ "$in_pats" = 1 ]; then pats+=("$a")
    else envs+=("$a"); fi
  done
  out="$(env "${envs[@]}" bash "$HERE/provision/provision.sh" --dry-run 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then ok "$desc — exit $rc"; else bad "$desc — exit $rc (want $want)"; fi
  for p in "${pats[@]}"; do
    case "$p" in
      '!'*) if grep -qF -e "${p#!}" <<<"$out"; then bad "$desc — unexpectedly saw: ${p#!}"
            else ok "$desc — absent: ${p#!}"; fi ;;
      *)    if grep -qF -e "$p" <<<"$out"; then ok "$desc — saw: $p"
            else bad "$desc — MISSING: $p"; fi ;;
    esac
  done
}

# ── follow-up text (next_steps_text) ────────────────────────────────────────
# nst_case <desc> <fake-TARGET_HOME> [VAR=val ...] -- [pattern ...]
# Same pattern language as dry_case ('!' = must NOT appear).
#
# next_steps_text branches on machine STATE, which is exactly the class of bug
# a green run hides: a stale bullet still prints, it just tells the user to redo
# work the run already did (F items 8 + 10 were both found live, not here).
# lib.sh is sourced in a subshell and $TARGET_HOME repointed AFTER sourcing (it
# is derived from getent), so every branch is reachable from a temp dir.
nst_case() {
  local desc="$1" home="$2"; shift 2
  local envs=() pats=() in_pats=0 a out p
  for a in "$@"; do
    if [ "$a" = "--" ]; then in_pats=1
    elif [ "$in_pats" = 1 ]; then pats+=("$a")
    else envs+=("$a"); fi
  done
  out="$(env "${envs[@]}" DRY_RUN=1 PROVISION_USER="$(id -un)" bash -c \
    'source "$1"/provision/lib.sh; TARGET_HOME="$2"; next_steps_text' _ "$HERE" "$home" 2>&1)"
  for p in "${pats[@]}"; do
    case "$p" in
      '!'*) if grep -qF -e "${p#!}" <<<"$out"; then bad "$desc — unexpectedly saw: ${p#!}"
            else ok "$desc — absent: ${p#!}"; fi ;;
      *)    if grep -qF -e "$p" <<<"$out"; then ok "$desc — saw: $p"
            else bad "$desc — MISSING: $p"; fi ;;
    esac
  done
}

cmd_dry() {
  hdr "dry-run matrix (no sudo, no changes)"
  dry_case "plain" 0 -- \
    "verify the OpenPGP signature against pinned fingerprint 3CE1780F78DD88DF45194FD706BC317B515ACE7C" \
    "finalize: skipped" "rootless Docker: skipped" "GNOME dconf: skipped" \
    "step: 80-next-steps.sh" "symlink " "!PROFILE=minimal —" \
    "step: 85-versions-lock.sh" "versions-lock.sh emit -o" "[flags: PROFILE=full" \
    "installer pinned to Homebrew/install@" "rustup/archive/" "fetch_pinned 'https://downloads.claude.ai/claude-code-releases/bootstrap.sh'" \
    "clone_pinned 'https://github.com/ohmyzsh/ohmyzsh'" "clone_pinned 'https://github.com/romkatv/powerlevel10k'" \
    "clone_pinned 'https://github.com/alacritty/alacritty-theme'"
  dry_case "desktop" 0 INSTALL_DESKTOP=1 -- \
    "!GNOME dconf: skipped"
  dry_case "golden" 0 GOLDEN_IMAGE=1 -- \
    "truncate /etc/machine-id" "copy " "!symlink " "!power off as the last action" \
    "scrub EVERY account (uid >= 1000" "authorized_keys (always" "backup.<ts> files" \
    "no private key ANYWHERE" "!restart apt-daily.timer"
  dry_case "plain run restores the apt timers" 0 -- \
    "restart apt-daily.timer + apt-daily-upgrade.timer"
  dry_case "golden+poweroff" 0 GOLDEN_IMAGE=1 GOLDEN_POWEROFF=1 -- \
    "power off as the last action (GOLDEN_POWEROFF=1)"
  dry_case "lowercase golden_poweroff typo warns" 0 golden_poweroff=1 GOLDEN_IMAGE=1 -- \
    "did you mean 'GOLDEN_POWEROFF'" "!power off as the last action"
  dry_case "copy" 0 DOTFILES_COPY=1 -- \
    "(self-contained)" "finalize: skipped"
  dry_case "rootless" 0 DOCKER_ROOTLESS=1 -- \
    "preflight: require kernel.apparmor_restrict_unprivileged_userns"
  dry_case "minimal" 0 PROFILE=minimal -- \
    "using apt.minimal.list" "using Brewfile.minimal" \
    "VSCodium: skipped (PROFILE=minimal)" "Cursor: skipped (PROFILE=minimal)" \
    "alacritty: skipped (PROFILE=minimal)" "flatpak: skipped (PROFILE=minimal)" \
    "kitty: skipped (PROFILE=minimal)"
  # S14's combination. The load-bearing claim is that PROFILE=minimal drops the
  # GUI set while KEEPING Docker *and* its rootless prerequisites — a future
  # `minimal &&` gate on the Docker block would silently break rootless on the
  # very profile (headless agent box) most likely to want it.
  dry_case "minimal+rootless" 0 PROFILE=minimal DOCKER_ROOTLESS=1 -- \
    "docker-ce-rootless-extras uidmap dbus-user-session" \
    "preflight: require kernel.apparmor_restrict_unprivileged_userns" \
    "Cursor: skipped (PROFILE=minimal)" "!Docker: skipped"
  # HEADLESS=1: the FULL manifests with every GUI install skipped — the shared
  # human+agent box. The load-bearing pair: the 5 GUI markers say HEADLESS=1
  # (not PROFILE=minimal), and NO lean-manifest marker appears. Before this flag
  # "full without a desktop" cargo-built Alacritty and installed two Electron
  # editors on boxes that could never display them (S2/S3/S12/S13, live).
  dry_case "headless" 0 HEADLESS=1 -- \
    "VSCodium: skipped (HEADLESS=1)" "Cursor: skipped (HEADLESS=1)" \
    "alacritty: skipped (HEADLESS=1)" "kitty: skipped (HEADLESS=1)" \
    "flatpak: skipped (HEADLESS=1)" \
    "!using apt.minimal.list" "!using Brewfile.minimal" "Docker: repo + Engine"
  # Redundant, not contradictory: minimal already implies no GUI. The reason
  # string must stay PROFILE=minimal — minimal is the more specific fact.
  dry_case "headless+minimal accepted (redundant)" 0 HEADLESS=1 PROFILE=minimal -- \
    "using apt.minimal.list" "alacritty: skipped (PROFILE=minimal)"
  dry_case "bogus profile dies" 1 PROFILE=bogus --
  dry_case "minimal+desktop dies" 1 PROFILE=minimal INSTALL_DESKTOP=1 --
  dry_case "headless+desktop dies" 1 HEADLESS=1 INSTALL_DESKTOP=1 -- \
    "HEADLESS=1 and INSTALL_DESKTOP=1 conflict"
  dry_case "lowercase headless typo warns" 0 headless=1 -- \
    "did you mean 'HEADLESS'" "!skipped (HEADLESS=1)"
  dry_case "lowercase flag typo warns" 0 golden_image=1 -- \
    "did you mean 'GOLDEN_IMAGE'" "finalize: skipped"

  # --help is a user-facing surface, not just syntax: it answers "which one do I
  # want" with the recipes and points at the canonical flag table. Asserted here
  # so a later rewrite can't quietly drop either. Must work without root.
  local h hrc hp
  h="$(bash "$HERE/provision/provision.sh" --help 2>&1)"; hrc=$?
  if [ "$hrc" = 0 ]; then ok "--help — exit 0"; else bad "--help — exit $hrc (want 0)"; fi
  for hp in "PROFILE=minimal" "INSTALL_DESKTOP=1" "GOLDEN_IMAGE=1" "APT_UPGRADE=1" \
            "--dry-run" "provision/README.md#flags"; do
    if grep -qF -e "$hp" <<<"$h"; then ok "--help — saw: $hp"; else bad "--help — MISSING: $hp"; fi
  done

  # F item 4: the runbook and the audit vocabulary used to be two hand-translated
  # languages. Now `verify S4` is the only thing to type — so the map has to stay
  # complete. Every S-id the runbook prints must resolve (S1 is the lint+dry tier
  # and deliberately resolves to "nothing to audit"); add a scenario, forget the
  # map, and this goes red instead of failing months later on a live box.
  local sid smap
  smap="$(cmd_scenarios 2>/dev/null | grep -oE '^ S[0-9]+' | tr -d ' ' | sort -u)"
  for sid in $smap; do
    if [ "$sid" = S1 ]; then
      if scenario_tokens S1 >/dev/null 2>&1; then bad "scenario map — S1 should have no tokens"
      else ok "scenario map — S1 correctly has no audit"; fi
    elif scenario_tokens "$sid" >/dev/null 2>&1; then ok "scenario map — $sid"
    else bad "scenario map — $sid is in the runbook with no verify tokens"; fi
  done
  if [ "$(scenario_tokens s4)" = "plain full desktop" ]; then ok "scenario map — s4 lowercase"
  else bad "scenario map — s4 lowercase did not expand"; fi
  if scenario_tokens S99 >/dev/null 2>&1; then bad "scenario map — S99 should be unknown"
  else ok "scenario map — unknown id rejected"; fi
  # The composition rules (F item 5) live in `scenarios` output; assert the
  # section is actually there, since it is the only place they are written down.
  # Capture first, THEN grep: `cmd_scenarios | grep -q` under `set -o pipefail`
  # is a race — grep -q exits on the first match, the writer takes SIGPIPE on
  # whatever it still had to print, and the pipeline reports 141. It flaked
  # about 1 run in 8 once the vocabulary grew past the matched line.
  local scen; scen="$(cmd_scenarios)"
  if grep -q "MODE (exactly one" <<<"$scen"; then ok "scenarios — composition rules present"
  else bad "scenarios — composition rules MISSING"; fi
  # ...and that they are ENFORCED, not merely printed. These exit before any
  # audit runs, so they are safe in the no-changes tier.
  local combo crc
  for combo in "plain copy" "full minimal" "plain golden-clone" "installsh full"; do
    # shellcheck disable=SC2086
    bash "$HERE/smoke-test.sh" verify $combo >/dev/null 2>&1; crc=$?
    # Exit 2 is "rejected before auditing". Merely asserting non-zero would ALSO
    # pass if the guard broke and a real audit ran and failed — a false green of
    # exactly the kind this suite exists to catch.
    if [ "$crc" = 2 ]; then ok "combo guard — '$combo' rejected (exit 2)"
    else bad "combo guard — '$combo' gave exit $crc (want 2 = rejected unaudited)"; fi
  done

  # ── the follow-up text's state branches (F items 8 + 10) ───────────────────
  local nst_home; nst_home="$(mktemp -d)"
  # The mise bullet's PATH line must reach the user LITERALLY — the heredoc is
  # unquoted, so an unescaped $PATH expands to the builder's PATH and a backtick
  # runs a command (both happened on first writing it).
  nst_case "follow-ups: full, no desktop" "$nst_home" -- \
    "desktop was installed here" "!GNOME's monospace font" \
    "Docker access for" "mise use -g node@lts" "mise use -g go@latest" \
    'export PATH="$HOME/.local/share/mise/shims:$PATH"'
  nst_case "follow-ups: full + desktop" "$nst_home" INSTALL_DESKTOP=1 -- \
    "GNOME's monospace font is already set to it" \
    "!desktop was installed here"
  nst_case "follow-ups: minimal" "$nst_home" PROFILE=minimal -- \
    "No Nerd Font on this box (PROFILE=minimal skips it)" \
    "!MesloLGS NF (Nerd Font) is installed system-wide"
  # Same no-font branch, other reason — and the reason must be the flag that
  # actually skipped step 36, because `verify` auto-detect reads it back.
  nst_case "follow-ups: headless" "$nst_home" HEADLESS=1 -- \
    "No Nerd Font on this box (HEADLESS=1 skips it)" \
    "re-provision without HEADLESS=1" \
    "!MesloLGS NF (Nerd Font) is installed system-wide"
  # The load-bearing half of item 10: the flag says what was ASKED FOR. On a
  # userns-restricted host step 25 soft-fails and leaves the box rootful, so
  # the setup recipe must still print.
  nst_case "follow-ups: rootless asked for, not up" "$nst_home" DOCKER_ROOTLESS=1 -- \
    "Docker access for" "!ALREADY set up"
  mkdir -p "$nst_home/.config/systemd/user" \
    && : > "$nst_home/.config/systemd/user/docker.service"
  nst_case "follow-ups: rootless actually up" "$nst_home" DOCKER_ROOTLESS=1 -- \
    "rootless is ALREADY set up" "docker info --format" \
    "!choose ONE" "!usermod -aG docker"
  nst_case "follow-ups: apt not upgraded (default)" "$nst_home" -- \
    "re-run with APT_UPGRADE=1" "!will not reach zero"
  nst_case "follow-ups: apt upgraded" "$nst_home" APT_UPGRADE=1 -- \
    "the count will not reach zero" "Always-Include-Phased-Updates" \
    "!re-run with APT_UPGRADE=1"
  rm -rf "$nst_home"

  # ── every step file is REGISTERED in provision.sh ─────────────────────────
  # provision.sh's STEPS array is hand-maintained, not a glob, so a new
  # steps/NN-*.sh is inert until it is added there — it shellchecks clean, it
  # dry-runs clean, and it simply never runs. (Caught exactly this while adding
  # 38-kitty.sh.) Assert both directions: no orphan file, no phantom entry.
  local sf sname
  for sf in "$HERE"/provision/steps/*.sh; do
    sname="$(basename "$sf")"
    if grep -qE "^[[:space:]]+$sname\$" "$HERE/provision/provision.sh"; then
      ok "step registered — $sname"
    else bad "step NOT in provision.sh's STEPS array (dead code) — $sname"; fi
  done
  while read -r sname; do
    [ -f "$HERE/provision/steps/$sname" ] \
      || bad "STEPS lists a step that does not exist — $sname"
  done < <(sed -n '/^STEPS=(/,/^)/p' "$HERE/provision/provision.sh" \
           | sed -n 's/^[[:space:]]*\([0-9][0-9]*-[a-z-]*\.sh\)[[:space:]]*$/\1/p')

  # ── CI actually runs both tiers, on BOTH hosts ─────────────────────────────
  # The tiers need no sudo, root or network precisely so they can gate a PR;
  # the two CI files are what cash that in. Deleting or renaming either breaks
  # nothing locally — this is the only thing that would notice. Comments are
  # stripped first (a prose mention of the command must not satisfy it).
  local wf tier wfcode
  for wf in .github/workflows/smoke.yml .gitlab-ci.yml; do
    if [ -f "$HERE/$wf" ]; then
      wfcode="$(grep -vE '^[[:space:]]*#' "$HERE/$wf")"
      for tier in lint dry; do
        if grep -qE "bash smoke-test\.sh ${tier}([^a-z]|\$)" <<<"$wfcode"; then
          ok "CI runs the $tier tier ($wf)"
        else bad "CI does NOT run the $tier tier — $wf has no 'bash smoke-test.sh $tier'"; fi
      done
    else bad "CI config missing — $wf"; fi
  done

  # Tracked docs must carry no commit SHAs. The repo was re-published from its
  # last state without history (2026-09-22), so a "fixed in abc1234" points at
  # nothing a reader can open; the record that survived the export is
  # docs/DESIGN-NOTES.md. Tracked *.md only — CLAUDE.local.md is the owner's
  # gitignored log and keeps its SHAs, which resolve in the private archive.
  # Uppercase key fingerprints and 64-char sha256s are not matched.
  local mdf mdhit=0 mdbad
  while IFS= read -r mdf; do
    mdbad="$(grep -oE '\b[0-9a-f]{7,40}\b' "$HERE/$mdf" 2>/dev/null | grep -vE '^[0-9]+$' | sort -u | head -3)"
    [ -n "$mdbad" ] && { bad "docs — $mdf cites commit SHAs that do not resolve here: $(tr '\n' ' ' <<<"$mdbad")"; mdhit=1; }
  done < <(cd "$HERE" && git ls-files '*.md' 2>/dev/null)
  [ "$mdhit" = 0 ] && ok "docs — no tracked *.md cites a commit SHA (history lives in docs/DESIGN-NOTES.md)"
  # The two community files, and the one thing SECURITY.md must not lose: a
  # private report channel. An issue is the wrong place for a vulnerability in
  # a repo that installs software as root.
  if [ -s "$HERE/SECURITY.md" ] && [ -s "$HERE/CONTRIBUTING.md" ] \
     && grep -qi 'private vulnerability reporting' "$HERE/SECURITY.md" \
     && grep -q 'security/advisories/new' "$HERE/SECURITY.md"; then
    ok "docs — SECURITY.md (private reporting channel) and CONTRIBUTING.md are present"
  else bad "docs — SECURITY.md/CONTRIBUTING.md missing, or SECURITY.md lost its private channel"; fi
  # The design note is the one place the pre-export history survives.
  if [ -s "$HERE/docs/DESIGN-NOTES.md" ] && grep -q 'DESIGN-NOTES' "$HERE/CLAUDE.md" && grep -q 'DESIGN-NOTES' "$HERE/README.md"; then
    ok "docs — DESIGN-NOTES.md exists and both CLAUDE.md and README.md point at it"
  else bad "docs — DESIGN-NOTES.md missing, or the entry points no longer link it"; fi

  # ── versions.lock: emit + check, self-contained ────────────────────────────
  # No shims, no brew needed: every source is optional, so the emitter is valid
  # on this box AND on a bare CI runner (system + apt kinds at least). The
  # checker must report exactly what changed, in both directions, and stay
  # silent when nothing did — a drift report that lies is worse than none.
  local vl="$HERE/provision/versions-lock.sh" vlt vrc vout
  vlt="$(mktemp -d)"
  if bash "$vl" emit -o "$vlt/a.lock" >/dev/null 2>&1 \
     && grep -q '^system	kernel	' "$vlt/a.lock" && grep -q '^# generated: ' "$vlt/a.lock"; then
    ok "versions.lock — emit writes a parseable lock with the system kind"
  else bad "versions.lock — emit failed or produced no system kind"; fi
  # The header's provenance field: always present, honest when unresolvable.
  # The emitter runs as the TARGET USER, and git refuses a repo owned by
  # someone else — under cloud-init that is root-owned /opt/dotfiles, so the
  # field silently vanished from every cloud-provisioned box's lock (found live
  # on AWS, TODO K 2026-09-24). Step 85 now resolves it as root and hands it
  # down; "unknown" is recorded when nothing can.
  local vhdr
  vhdr="$(PROVISION_REPO_SHA=abc1234 bash "$vl" emit | sed -n 2p)"
  if grep -q 'repo: abc1234' <<<"$vhdr"; then ok "versions.lock — the header takes PROVISION_REPO_SHA (handed down by step 85 as root)"
  else bad "versions.lock — PROVISION_REPO_SHA ignored: $vhdr"; fi
  mkdir -p "$vlt/nogit" && cp "$vl" "$HERE/provision/boot-pkgs.sh" "$vlt/nogit/"
  vhdr="$(bash "$vlt/nogit/versions-lock.sh" emit 2>/dev/null | sed -n 2p)"
  if grep -q 'repo: unknown' <<<"$vhdr"; then ok "versions.lock — records 'repo: unknown' rather than dropping the field"
  else bad "versions.lock — no repo field when git cannot resolve one: $vhdr"; fi
  if grep -q 'PROVISION_REPO_SHA=' "$HERE/provision/steps/85-versions-lock.sh"; then
    ok "versions.lock — step 85 hands the repo SHA down to the user-context emit"
  else bad "versions.lock — step 85 no longer passes PROVISION_REPO_SHA; cloud-init locks lose provenance"; fi
  vout="$(bash "$vl" check "$vlt/a.lock" 2>&1)"; vrc=$?
  if [ "$vrc" = 0 ] && grep -q '^no drift' <<<"$vout"; then ok "versions.lock — check against its own emit: no drift, exit 0"
  else bad "versions.lock — self-check gave exit $vrc: $vout"; fi
  # Mutate: change the kernel's version, drop the arch line, add a phantom.
  sed -e 's/^\(system	kernel	\).*/\1x.y.z-mutated/' -e '/^system	arch	/d' "$vlt/a.lock" > "$vlt/b.lock"
  printf 'brew\tphantom\t0.0\n' >> "$vlt/b.lock"
  vout="$(bash "$vl" check "$vlt/b.lock" 2>&1)"; vrc=$?
  if [ "$vrc" = 1 ] && grep -q '1 changed, 1 added, 1 removed' <<<"$vout" \
     && grep -q 'changed  system/kernel' <<<"$vout" && grep -q 'added    system/arch' <<<"$vout" \
     && grep -q 'removed  brew/phantom' <<<"$vout"; then
    ok "versions.lock — check reports changed/added/removed exactly, exit 1"
  else bad "versions.lock — mutated check gave exit $vrc: $vout"; fi
  bash "$vl" check "$vlt/does-not-exist" >/dev/null 2>&1; vrc=$?
  if [ "$vrc" = 2 ]; then ok "versions.lock — missing lock is exit 2 (error, not drift)"
  else bad "versions.lock — missing lock gave exit $vrc"; fi
  # --ignore-boot: the running kernel and the kernel/bootloader apt rows are
  # Ubuntu's, not provisioning's. A lock with a different kernel and a kernel
  # meta this box lacks must be drift plainly and NO drift with the flag —
  # and the flag must not blanket-ignore: a brew phantom stays drift.
  sed -e 's/^\(system	kernel	\).*/\1x.y.z-mutated/' "$vlt/a.lock" > "$vlt/c.lock"
  printf 'apt\tlinux-generic-hwe-24.04\t0.0-mutated\napt\tshim-signed\t0.0-mutated\n' >> "$vlt/c.lock"
  bash "$vl" check "$vlt/c.lock" --brief >/dev/null 2>&1; vrc=$?
  vout="$(bash "$vl" check "$vlt/c.lock" --brief --ignore-boot 2>&1)"; local vrc2=$?
  if [ "$vrc" = 1 ] && [ "$vrc2" = 0 ] && grep -q 'boot rows ignored' <<<"$vout"; then
    ok "versions.lock — check --ignore-boot: kernel + boot-package rows are not drift (plain: exit 1, flag: exit 0)"
  else bad "versions.lock — --ignore-boot gave plain=$vrc flag=$vrc2: $vout"; fi
  printf 'brew\tphantom\t0.0\n' >> "$vlt/c.lock"
  bash "$vl" check "$vlt/c.lock" --brief --ignore-boot >/dev/null 2>&1; vrc=$?
  if [ "$vrc" = 1 ]; then ok "versions.lock — --ignore-boot ignores ONLY boot rows (a brew phantom is still drift)"
  else bad "versions.lock — --ignore-boot swallowed a non-boot drift (exit $vrc)"; fi
  bash "$vl" check "$vlt/a.lock" --bogus >/dev/null 2>&1; vrc=$?
  if [ "$vrc" = 2 ]; then ok "versions.lock — unknown check option is exit 2"
  else bad "versions.lock — unknown check option gave exit $vrc"; fi
  # Option order is free: `check --brief LOCK` must not read --brief as the path.
  if bash "$vl" check --brief --ignore-boot "$vlt/a.lock" >/dev/null 2>&1 \
     && bash "$vl" check "$vlt/a.lock" --ignore-boot --brief >/dev/null 2>&1; then
    ok "versions.lock — check accepts options before or after the lock path"
  else bad "versions.lock — check is position-sensitive about its options"; fi
  bash "$vl" check >/dev/null 2>&1; vrc=$?
  bash "$vl" check "$vlt/a.lock" "$vlt/a.lock" >/dev/null 2>&1; local vrc3=$?
  if [ "$vrc" = 2 ] && [ "$vrc3" = 2 ]; then ok "versions.lock — check with no lock, or two, is exit 2"
  else bad "versions.lock — check arg-count errors gave $vrc / $vrc3"; fi
  # One owner for "boot package": step 10's deny list and the lock's --ignore-boot
  # both source provision/boot-pkgs.sh, and the predicate says what it must.
  if grep -q 'source "\$PROVISION_DIR/boot-pkgs.sh"' "$HERE/provision/lib.sh" \
     && grep -q 'source "\$HERE/boot-pkgs.sh"' "$vl" \
     && grep -q 'is_boot_pkg "\$1" && return 0' "$HERE/provision/steps/10-apt.sh"; then
    ok "boot-pkgs.sh — sourced by lib.sh (step 10) and versions-lock.sh; is_denied delegates to it"
  else bad "boot-pkgs.sh — step 10 and versions-lock.sh no longer share one boot-package definition"; fi
  if ( source "$HERE/provision/boot-pkgs.sh"; is_boot_pkg linux-generic-hwe-24.04 && is_boot_pkg linux-image-7.0.0-31-generic \
       && is_boot_pkg grub-efi-arm64-signed && is_boot_pkg shim-signed && is_boot_pkg efibootmgr \
       && ! is_boot_pkg curl && ! is_boot_pkg util-linux && ! is_boot_pkg flatpak ); then
    ok "boot-pkgs.sh — is_boot_pkg: kernel/grub/shim/efibootmgr yes; curl/util-linux/flatpak no"
  else bad "boot-pkgs.sh — is_boot_pkg misclassifies"; fi
  # A BROKEN dpkg must stop emit, not produce an empty lock. dpkg-query answers
  # 1 both for "not installed" and for "broken", so it used to write a
  # valid-looking lock with zero apt/deb rows and exit 0 (round-2 review).
  local dshim; dshim="$(mktemp -d)"
  printf '#!/bin/sh\nexit 9\n' > "$dshim/dpkg-query"; chmod +x "$dshim/dpkg-query"
  PATH="$dshim:$PATH" bash "$vl" emit -o "$vlt/broken.lock" >/dev/null 2>&1; vrc=$?
  if [ "$vrc" = 2 ] && [ ! -e "$vlt/broken.lock" ]; then
    ok "versions.lock — a broken dpkg-query stops emit (exit 2, no lock written)"
  else bad "versions.lock — broken dpkg-query gave exit $vrc$([ -e "$vlt/broken.lock" ] && echo ', and a lock was written')"; fi
  rm -rf "$dshim"

  # ── provenance is fail-closed for a golden (external review, 2026-09-25) ───
  # `repo: unknown` and `repo: <sha> (dirty)` used to be annotations nobody
  # consumed: check strips the header, v_core only tests the lock is non-empty.
  # So a golden could be captured with no traceable commit while the repo claims
  # "this commit produced this image". Three gates now, all three guarded.
  #
  # (a) provision.sh refuses EARLY under GOLDEN_IMAGE. Early matters: step 85 is
  # second to last, so failing there costs a whole build. Runnable without root
  # because the gate sits ahead of the is_root check, and it changes nothing.
  local gt gout grc
  # Every tracked path, at its WORKING-TREE content. Two traps here, both hit
  # while writing this: a partial copy makes step 36 soft_fail on the missing
  # vendored font dir, which under STRICT aborts and looks exactly like the gate
  # firing; and `git archive HEAD` copies the COMMITTED scripts, so the test
  # silently exercises HEAD instead of the change under test — green as soon as
  # you commit, having never tested anything.
  gt="$(mktemp -d)"
  ( cd "$HERE" && git ls-files -z | tar --null -T - -cf - ) 2>/dev/null | tar -x -C "$gt" 2>/dev/null
  ( cd "$gt" && git init -q && git add -A >/dev/null 2>&1 && git -c user.email=t@t -c user.name=t commit -qm x ) >/dev/null 2>&1
  printf '\n# dirty\n' >> "$gt/provision/lib.sh"
  gout="$(cd "$gt" && GOLDEN_IMAGE=1 PROVISION_USER="$(id -un)" bash provision/provision.sh 2>&1)"; grc=$?
  if [ "$grc" != 0 ] && grep -q 'uncommitted changes' <<<"$gout"; then
    ok "golden provenance — a dirty checkout is REFUSED before any step runs"
  else bad "golden provenance — dirty tree gave exit $grc: $(printf %.200s "$gout")"; fi
  # An UNTRACKED file must count too: step 36 copies every fonts/MesloLGS-NF/*.ttf,
  # so an extra untracked font changes the image while HEAD looks clean.
  # `git diff --quiet HEAD` missed that (round-2 review).
  git -C "$gt" checkout -q -- provision/lib.sh
  : > "$gt/fonts/MesloLGS-NF/untracked-extra.ttf"
  gout="$(cd "$gt" && GOLDEN_IMAGE=1 PROVISION_USER="$(id -un)" bash provision/provision.sh 2>&1)"; grc=$?
  if [ "$grc" != 0 ] && grep -q 'uncommitted changes' <<<"$gout"; then
    ok "golden provenance — an UNTRACKED file is refused too (not only tracked edits)"
  else bad "golden provenance — untracked file gave exit $grc: $(printf %.200s "$gout")"; fi
  gout="$(cd "$gt" && GOLDEN_IMAGE=1 PROVISION_USER="$(id -un)" bash provision/provision.sh --dry-run 2>&1)"; grc=$?
  if [ "$grc" = 0 ] && grep -q 'a real run would refuse' <<<"$gout"; then
    ok "golden provenance — --dry-run only WARNS (previewing from a dirty tree is normal)"
  else bad "golden provenance — dry run gave exit $grc / no warning"; fi
  rm -rf "$gt"
  # (b) step 85 is the backstop for the non-golden and got-dirty-mid-run cases.
  if grep -q 'soft_fail "cannot resolve the repo commit' "$HERE/provision/steps/85-versions-lock.sh" \
     && grep -q 'soft_fail "the repo at .* uncommitted changes' "$HERE/provision/steps/85-versions-lock.sh"; then
    ok "golden provenance — step 85 soft_fails on an unresolvable OR dirty repo"
  else bad "golden provenance — step 85 no longer soft_fails on bad provenance"; fi
  # (c) the SHA is recorded in full. A shallow cloud-init clone cannot know an
  # abbreviation is unique in a history it does not have.
  if grep -q 'rev-parse HEAD' "$HERE/provision/steps/85-versions-lock.sh" \
     && ! grep -q 'rev-parse --short' "$HERE/provision/steps/85-versions-lock.sh"; then
    ok "golden provenance — step 85 records the full 40-hex commit, not an abbreviation"
  else bad "golden provenance — step 85 records an abbreviated SHA"; fi
  # (d) and the clone audit ASSERTS the shape rather than mere presence.
  if sed -n "/^v_golden_clone() {/,/^}/p" "$HERE/tests/verify.sh" | grep -q 'traceable commit'; then
    ok "golden provenance — v_golden_clone asserts the repo: field's shape"
  else bad "golden provenance — v_golden_clone does not assert provenance"; fi

  # No PII: the lock must carry no username, hostname or home path.
  if grep -qE "$(id -un)|$(hostname)|$HOME" "$vlt/a.lock"; then bad "versions.lock — emit leaked a username/hostname/path"
  else ok "versions.lock — no username, hostname or home path in the lock"; fi
  rm -rf "$vlt"

  # ── supply chain (TODO J): nothing executes from a moving branch ──────────
  # The assertion that keeps J true: no `curl … | sh|bash` pipeline and no raw
  # `git clone` anywhere code runs during provisioning. Comment-stripped, so a
  # prose mention (like the ones in pins.sh's header) cannot satisfy or trip it.
  local jf jcode jhit=0
  for jf in provision/steps/*.sh provision/lib.sh provision/pins.sh install.sh; do
    jcode="$(grep -vE '^[[:space:]]*#' "$HERE/$jf")"
    if grep -qE 'curl[^|#]*\|[[:space:]]*(sh|bash)\b' <<<"$jcode"; then bad "supply chain — curl|sh pipeline in $jf"; jhit=1; fi
    if grep -qE '\bgit clone\b' <<<"$jcode"; then bad "supply chain — raw git clone in $jf (use clone_pinned)"; jhit=1; fi
  done
  [ "$jhit" = 0 ] && ok "supply chain — no curl|sh pipeline and no raw git clone in any install path"
  # The helper contract, enforced: apt only through apt_get/apt_install. A bare
  # apt-get is not just dry-run-blind — it is INTERACTIVE. finalize's bare
  # `apt-get autoremove` hung the Gen-4 build on needrestart's dialog (stdin
  # was /dev/null) once APT_UPGRADE=1 had left a newer kernel installed than
  # the one running (2026-09-13).
  local af ahit=0
  for af in provision/steps/*.sh; do
    # Command position only: line start or after && || ; | { ( — optionally
    # prefixed by $SUDO/sudo. Not the word inside a soft_fail/would message.
    if grep -vE '^[[:space:]]*#' "$HERE/$af" | grep -qE '(^|&&|\|\||;|\||\{|\()[[:space:]]*(\$SUDO |sudo )?apt-get[[:space:]]'; then
      bad "helper contract — bare apt-get in $af (use apt_get / apt_install)"; ahit=1; fi
  done
  [ "$ahit" = 0 ] && ok "helper contract — no bare apt-get in any step"
  # rustup's binary dispatches on its own filename (rustup-init = installer; any
  # other name = toolchain proxy that does nothing). A mktemp name verified fine
  # and silently did nothing in the J rehearsal — so the target must literally
  # end in /rustup-init.
  if grep -vE '^[[:space:]]*#' "$HERE/provision/steps/35-rust.sh" | grep -q 'fetch_pinned .*/rustup-init\\"'; then
    ok "step 35 — rustup-init is downloaded under its own name (argv[0] dispatch)"
  else bad "step 35 — rustup-init download target is not named rustup-init"; fi
  # Every pin has the shape it claims: 40-hex commits, 64-hex sha256.
  local pk pv
  while IFS='=' read -r pk pv; do
    pv="${pv%%[[:space:]]*}"; pv="${pv%%#*}"
    case "$pk" in
      *_SHA|*_COMMIT) [[ "$pv" =~ ^[0-9a-f]{40}$ ]] && ok "pin $pk is a 40-hex commit" || bad "pin $pk is not a 40-hex commit: '$pv'" ;;
      *_SHA256*)      [[ "$pv" =~ ^[0-9a-f]{64}$ ]] && ok "pin $pk is a sha256" || bad "pin $pk is not a sha256: '$pv'" ;;
    esac
  done < <(grep -E '^[A-Za-z0-9_]+=' "$HERE/provision/pins.sh")
  # The helpers, functionally and without network: a local bare repo with two
  # commits for clone_pinned, a file:// URL for fetch_pinned. Both the happy
  # path and the refusal are asserted — a verifier that cannot fail is décor.
  local jt jsha1 jsha2 jout
  jt="$(mktemp -d)"
  git -C "$jt" init -q -b master src && ( cd "$jt/src" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m one && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m two )
  git -C "$jt/src" config uploadpack.allowReachableSHA1InWant true   # GitHub allows this; a local repo must opt in
  jsha1="$(git -C "$jt/src" rev-parse HEAD~1)"; jsha2="$(git -C "$jt/src" rev-parse HEAD)"
  if bash "$HERE/provision/pins.sh" clone_pinned "$jt/src" "$jsha1" "$jt/dst" >/dev/null 2>&1 \
     && [ "$(git -C "$jt/dst" rev-parse HEAD)" = "$jsha1" ] && [ "$(git -C "$jt/dst" rev-list --count HEAD)" = 1 ]; then
    ok "clone_pinned — checks out exactly the pinned commit, shallow, detached (not $jsha2)"
  else bad "clone_pinned — did not land on the pinned commit"; fi
  if bash "$HERE/provision/pins.sh" clone_pinned "$jt/src" "0000000000000000000000000000000000000000" "$jt/dst2" >/dev/null 2>&1; then
    bad "clone_pinned — accepted an unreachable commit"
  else ok "clone_pinned — refuses an unreachable commit"; fi
  if bash "$HERE/provision/pins.sh" clone_pinned "$jt/src" "not-a-sha" "$jt/dst3" >/dev/null 2>&1; then
    bad "clone_pinned — accepted a malformed pin"
  else ok "clone_pinned — refuses a malformed pin"; fi
  # Convergence (2026-09-21): a pin bump must reach EXISTING checkouts on the
  # next run, and `omz update` drift must be undone by it — while untracked
  # content (~/.oh-my-zsh/custom/) survives and a non-checkout dir is never
  # wiped. Three states on the same dst: at the pin (no-op, no fetch — proven
  # by pointing origin at a dead path), at another commit (moved), not a repo
  # (refused, content intact).
  mkdir -p "$jt/dst/custom" && printf 'mine\n' > "$jt/dst/custom/keep"
  git -C "$jt/dst" remote set-url origin "$jt/nowhere"
  if bash "$HERE/provision/pins.sh" clone_pinned "$jt/nowhere" "$jsha1" "$jt/dst" >/dev/null 2>&1 \
     && [ "$(git -C "$jt/dst" rev-parse HEAD)" = "$jsha1" ]; then
    ok "clone_pinned — a checkout already at the pin is a no-op (no fetch: origin was dead)"
  else bad "clone_pinned — re-run at the pin was not a silent no-op"; fi
  git -C "$jt/dst" remote set-url origin "$jt/src"
  if bash "$HERE/provision/pins.sh" clone_pinned "$jt/src" "$jsha2" "$jt/dst" >/dev/null 2>&1 \
     && [ "$(git -C "$jt/dst" rev-parse HEAD)" = "$jsha2" ] && [ "$(cat "$jt/dst/custom/keep")" = mine ]; then
    ok "clone_pinned — moves an existing checkout to a bumped pin, untracked custom/ kept"
  else bad "clone_pinned — did not converge an existing checkout to the new pin (or lost untracked files)"; fi
  mkdir -p "$jt/plain" && printf 'x\n' > "$jt/plain/file"
  if bash "$HERE/provision/pins.sh" clone_pinned "$jt/src" "$jsha1" "$jt/plain" >/dev/null 2>&1; then
    bad "clone_pinned — replaced a non-checkout directory"
  elif [ -f "$jt/plain/file" ]; then ok "clone_pinned — refuses a non-empty non-checkout dir and leaves it intact"
  else bad "clone_pinned — refused but WIPED the non-checkout dir"; fi
  # `pins.sh bump` — the cadence as a command (2026-09-21). Offline parts:
  # argument validation, and the line rewrite must touch ONLY the named pin
  # (the rest of the file byte-identical, shapes intact). The upstream fetches
  # need the network and are exercised by hand on each cadence run.
  # _pins_file must be ABSOLUTE even when pins.sh is invoked by a relative
  # path: `bump` stages with `git -C "$(dirname …)" add "$(…)"`, which with a
  # relative path becomes provision/provision/pins.sh and fails. It did, for
  # two days, silently (2026-09-24).
  local pabs; pabs="$(cd "$HERE" && bash -c 'source provision/pins.sh; _pins_file' 2>/dev/null)"
  case "$pabs" in
    /*) [ -f "$pabs" ] && ok "pins.sh — _pins_file is absolute even when invoked by a relative path" \
          || bad "pins.sh — _pins_file returned '$pabs', which is not a readable file" ;;
    *)  bad "pins.sh — _pins_file returned a RELATIVE path ('$pabs'); bump's git add will fail" ;;
  esac
  bash "$HERE/provision/pins.sh" bump >/dev/null 2>&1; local brc=$?
  bash "$HERE/provision/pins.sh" bump nosuchpin >/dev/null 2>&1; local brc2=$?
  if [ "$brc" = 2 ] && [ "$brc2" = 2 ]; then ok "pins.sh bump — no name / unknown name is exit 2"
  else bad "pins.sh bump — argument errors gave $brc / $brc2 (want 2 / 2)"; fi
  # bump's OUTCOME must be read off the file, not inferred from a worker's exit
  # code (external review, 2026-09-25, F2). A worker returns 1 both for "cannot
  # reach GitHub" (nothing written) and for "pin rewritten, checkout would not
  # converge" (written), so the old `1 -> changed=1` mapping printed "rewritten
  # and staged" for a bump that never touched the file. And when the rewrite
  # happened but `git add` failed, it warned honestly and still returned 0, so
  # automation saw success. Both are exercised offline with a stub worker.
  local bt bout
  bt="$(mktemp -d)"; cp "$HERE/provision/pins.sh" "$bt/pins.sh"
  # (1) worker fails BEFORE any rewrite: no rewrite claim, exit 1.
  bout="$( cd "$bt" && bash -c 'source ./pins.sh; _bump_brew() { echo "stub: cannot reach GitHub" >&2; return 1; }; bump brew-installer' 2>&1 )"; brc=$?
  if [ "$brc" = 1 ] && ! grep -q 'rewritten' <<<"$bout"; then
    ok "pins.sh bump — a worker that fails before rewriting claims NO rewrite (exit 1)"
  else bad "pins.sh bump — failed-before-rewrite gave exit $brc and said: $(printf %.120s "$bout")"; fi
  # (2) rewrite really happens but staging cannot ($bt is not a git checkout):
  #     the message is honest AND the exit code is a failure.
  bout="$( cd "$bt" && bash -c 'source ./pins.sh; _bump_brew() { _pin_set HOMEBREW_INSTALL_COMMIT deadbeefdeadbeefdeadbeefdeadbeefdeadbeef "stub"; return 3; }; bump brew-installer' 2>&1 )"; brc=$?
  if [ "$brc" = 1 ] && grep -q 'NOT staged' <<<"$bout"; then
    ok "pins.sh bump — a rewrite that cannot be staged is exit 1, not 0"
  else bad "pins.sh bump — unstageable rewrite gave exit $brc and said: $(printf %.120s "$bout")"; fi
  # (3) and a worker reporting "already at upstream" must claim nothing at all.
  bout="$( cd "$bt" && bash -c 'source ./pins.sh; _bump_brew() { echo "stub: at upstream HEAD"; return 0; }; bump brew-installer' 2>&1 )"; brc=$?
  if [ "$brc" = 0 ] && ! grep -q 'rewritten' <<<"$bout"; then
    ok "pins.sh bump — nothing to do claims no rewrite and exits 0"
  else bad "pins.sh bump — no-op gave exit $brc and said: $(printf %.120s "$bout")"; fi
  rm -rf "$bt"
  cp "$HERE/provision/pins.sh" "$jt/pins-copy.sh"
  if ( source "$jt/pins-copy.sh"; _pin_set OMZ_SHA "$(printf 'a%.0s' {1..40})" "test note" ) \
     && grep -q "^OMZ_SHA=$(printf 'a%.0s' {1..40})     # test note$" "$jt/pins-copy.sh" \
     && diff -q <(grep -v '^OMZ_SHA=' "$jt/pins-copy.sh") <(grep -v '^OMZ_SHA=' "$HERE/provision/pins.sh") >/dev/null; then
    ok "pins.sh bump — _pin_set rewrites exactly the named pin line, rest byte-identical"
  else bad "pins.sh bump — _pin_set changed more than the named line (or not that line)"; fi
  if ( source "$jt/pins-copy.sh"; _pin_set NO_SUCH_PIN x y ) >/dev/null 2>&1; then bad "pins.sh bump — _pin_set accepted an unknown pin name"
  else ok "pins.sh bump — _pin_set refuses an unknown pin name"; fi
  # `omz update` on a pinned box must point at the bump, not run omz's updater
  # (which fails with a pathspec error here — no local master). Needs zsh AND
  # an oh-my-zsh checkout to load .zshrc for real; the CI runners have neither.
  # ZDOTDIR is a SCRATCH dir holding a copy of the repo's .zshrc, not the repo
  # itself: zsh writes .zcompdump* wherever ZDOTDIR points, and the repo root is
  # not a scratch space (they were landing there, gitignored but real).
  if command -v zsh >/dev/null 2>&1 && [ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]; then
    local ozd; ozd="$(mktemp -d)"; cp "$HERE/.zshrc" "$ozd/.zshrc"
    local oz; oz="$(ZDOTDIR="$ozd" zsh -ic 'omz update' 2>&1)"; local ozrc=$?
    rm -rf "$ozd"
    if [ "$ozrc" = 1 ] && grep -q 'pins.sh bump omz' <<<"$oz" && ! grep -q 'invalid reference' <<<"$oz"; then
      ok ".zshrc — \`omz update\` is routed to \`pins.sh bump omz\` (exit 1, no git error)"
    else bad ".zshrc — \`omz update\` not routed to the bump (rc=$ozrc): $oz"; fi
  else skip ".zshrc — omz update routing (needs zsh + ~/.oh-my-zsh here)"; fi
  # A checkout at the pin with a MODIFIED tracked file is not "pinned" — the
  # code differs from what the SHA says (2026-09-22, assessment). Untracked
  # content stays exempt (omz's custom/ lives there).
  printf 'edited\n' >> "$jt/dst/README.md" 2>/dev/null || printf 'edited\n' > "$jt/dst/tracked-probe"
  if git -C "$jt/dst" ls-files --error-unmatch README.md >/dev/null 2>&1; then
    if bash "$HERE/provision/pins.sh" clone_pinned "$jt/src" "$jsha2" "$jt/dst" >/dev/null 2>&1; then
      bad "clone_pinned — accepted a checkout with locally modified tracked files"
    else ok "clone_pinned — refuses a checkout whose tracked files are modified (untracked custom/ still fine)"; fi
    git -C "$jt/dst" checkout -q -- README.md
  else
    # the test repo has no tracked file to edit: make one in src, re-clone, edit it
    ( cd "$jt/src" && printf 'x\n' > tracked && git add tracked && git -c user.name=t -c user.email=t@t commit -q -m three )
    local jsha3; jsha3="$(git -C "$jt/src" rev-parse HEAD)"
    bash "$HERE/provision/pins.sh" clone_pinned "$jt/src" "$jsha3" "$jt/dst4" >/dev/null 2>&1
    printf 'edited\n' >> "$jt/dst4/tracked"
    if bash "$HERE/provision/pins.sh" clone_pinned "$jt/src" "$jsha3" "$jt/dst4" >/dev/null 2>&1; then
      bad "clone_pinned — accepted a checkout with locally modified tracked files"
    else ok "clone_pinned — refuses a checkout whose tracked files are modified (untracked custom/ still fine)"; fi
  fi
  # The sites must call it unconditionally — a sentinel gate in front of it
  # would bring back "bumped pins reach fresh boxes only".
  if ! grep -E 'test -f[^|]*\|\| *\\?$' "$HERE/provision/steps/60-shell.sh" | grep -q clone_pinned \
     && ! grep -qE 'if \[ ! -f .*(oh-my-zsh\.sh|powerlevel10k\.zsh-theme)' "$HERE/install.sh" \
     && ! grep -qE 'if \[ -d "\$themes_dir/\.git" \]' "$HERE/install.sh"; then
    ok "clone sites — clone_pinned runs on every run (no sentinel gate in front of it)"
  else bad "clone sites — a sentinel gate in front of clone_pinned would stop pin bumps reaching existing boxes"; fi
  printf 'echo hi\n' > "$jt/script.sh"
  local jgood; jgood="$(sha256sum "$jt/script.sh" | cut -d' ' -f1)"
  if PINS_TEST_ALLOW_FILE=1 bash "$HERE/provision/pins.sh" fetch_pinned "file://$jt/script.sh" "$jgood" "$jt/out1" >/dev/null 2>&1 \
     && cmp -s "$jt/script.sh" "$jt/out1"; then ok "fetch_pinned — delivers a file whose sha256 matches the pin"
  else bad "fetch_pinned — failed on a correct pin"; fi
  jout="$(PINS_TEST_ALLOW_FILE=1 bash "$HERE/provision/pins.sh" fetch_pinned "file://$jt/script.sh" "$(printf '0%.0s' {1..64})" "$jt/out2" 2>&1)"; local jrc=$?
  if [ "$jrc" != 0 ] && [ ! -e "$jt/out2" ] && grep -q 'REFUSING' <<<"$jout" && grep -q 're-pin' <<<"$jout"; then
    ok "fetch_pinned — refuses a hash mismatch, removes the file, says how to re-pin"
  else bad "fetch_pinned — mismatch handling wrong (rc=$jrc): $jout"; fi
  if bash "$HERE/provision/pins.sh" fetch_pinned "file://$jt/script.sh" "$jgood" "$jt/out3" >/dev/null 2>&1; then
    bad "fetch_pinned — accepted a non-https URL outside the test hook"
  else ok "fetch_pinned — https only (file:// refused without the test hook)"; fi
  rm -rf "$jt"

  # ── kitty on an arch upstream does not build for ───────────────────────────
  # Must WARN and exit 0, never soft_fail: under STRICT a soft_fail would abort
  # a whole golden build over something the operator cannot fix. Untestable
  # without a shim, and an untested branch is how the wrong severity survives.
  local kshim krc kout
  kshim="$(mktemp -d)"
  printf '#!/bin/sh\n[ "$1" = --print-architecture ] && { echo s390x; exit 0; }\nexec /usr/bin/dpkg "$@"\n' > "$kshim/dpkg"
  chmod +x "$kshim/dpkg"
  kout="$(PATH="$kshim:$PATH" DRY_RUN=1 STRICT=1 PROVISION_USER="$(id -un)" \
          bash "$HERE/provision/steps/38-kitty.sh" 2>&1)"; krc=$?
  if [ "$krc" = 0 ] && grep -q "upstream ships no binary for architecture" <<<"$kout"; then
    ok "kitty — unsupported arch warns and skips (exit 0, even under STRICT)"
  else bad "kitty — unsupported arch gave exit $krc: $kout"; fi
  rm -rf "$kshim"

  # ── kitty's signature check is BOUND to the pinned fingerprint ─────────────
  # verify_keyring compares only the FIRST key in kovid.gpg, so a file carrying
  # the real key first plus an APPENDED attacker key still passes the pin — and
  # a bare `gpg --verify` then accepts a tarball signed by EITHER key. That
  # reduces "forge Kovid Goyal's signature" to "compromise a second web host",
  # defeating the one property the pin exists to provide. --assert-signer is
  # what ties the two together. Neither tier can exercise the real verify (it
  # needs the network and a genuine signature), so assert the FLAG instead —
  # this is the only guard standing between the two.
  # Grep CODE, never comments: the paragraph above the call quotes both flags,
  # so scanning the raw file makes the second assertion pass on prose alone.
  local kcode kunbound
  kcode="$(grep -vE '^[[:space:]]*#' "$HERE/provision/steps/38-kitty.sh")"
  kunbound="$(grep -- '--verify' <<<"$kcode" | grep -v -- '--assert-signer' || true)"
  if [ -z "$kunbound" ]; then
    ok "kitty — every gpg --verify is bound with --assert-signer"
  else bad "kitty — gpg --verify WITHOUT --assert-signer:$(printf '\n    %s' "$kunbound")"; fi
  if grep -q -- '--assert-signer "\$KITTY_FP"' <<<"$kcode"; then
    ok "kitty — --assert-signer asserts the pinned \$KITTY_FP"
  else bad "kitty — --assert-signer does not reference \$KITTY_FP"; fi

  # ── terminfo for INBOUND ssh — every surface, every profile ───────────────
  # ssh forwards TERM and not the terminfo, so what a box needs is decided by
  # the CLIENT, never by which terminal (if any) is installed here. That makes
  # it profile-independent and GUI-independent, which is why it lives in the
  # apt lists rather than in step 36/38. ncurses-base (Essential) already has
  # xterm-256color/screen-*/tmux-256color; ncurses-term adds alacritty, wezterm,
  # foot and ~2,900 more; kitty-terminfo adds xterm-kitty, which ncurses-term
  # does NOT carry. Neither buys anything visible on the box that installs it,
  # so both are exactly the kind of line a tidy-up deletes as noise — and
  # install.sh is the surface a fix forgets, which is how it went the first time.
  local tmiss=0 al pkg
  for pkg in kitty-terminfo ncurses-term; do
    for al in provision/packages/apt.list provision/packages/apt.minimal.list; do
      grep -qx "$pkg" "$HERE/$al" \
        || { bad "$al — $pkg missing (inbound ssh from that terminal breaks here)"; tmiss=1; }
    done
    grep -qE "^APT_PKGS=\(.*$pkg" "$HERE/install.sh" \
      || { bad "install.sh — $pkg missing from APT_PKGS"; tmiss=1; }
  done
  # ...and step 36 must NOT have grown its per-user tic back: $HOME/.terminfo
  # covers one account, shadows the system entry for that account only, and is
  # the user's own space. Match the WRITE (a tic aimed there), not any mention of
  # the path — the step now has to name it in order to REPORT a stale entry left
  # by an earlier revision, and the first version of this guard reddened on that.
  if grep -vE '^[[:space:]]*#' "$HERE/provision/steps/36-alacritty.sh" \
     | grep -qE '(^|[^[:alnum:]_])tic[^#]*HOME/\.terminfo'; then
    bad "36-alacritty.sh — a tic writes \$HOME/.terminfo again (one account only; ncurses-term owns this)"; tmiss=1
  fi
  # BOTH whole-box audits must run the terminfo probe. `verify installsh`
  # deliberately replaces v_core rather than extending it, so a check added to
  # v_core silently does not apply to an install.sh box — which is the shape
  # most likely to be reached ONLY over ssh. That is not hypothetical: S10
  # scored 28/28 on a box that answered "unknown terminal type xterm-kitty" at
  # every prompt for the operator who ssh'd in (2026-09-24).
  # sed, not awk: the first version of this guard passed on Ubuntu 26.04's mawk
  # (1.3.4 20260129) and failed on BOTH CI runners (24.04, older mawk), because
  # `\(` / `\{` escaping in a dynamic -v regex is not stable across mawk
  # versions. In a POSIX sed BRE `(`, `)` and `{` are literal and need no
  # escaping at all, so there is nothing left to differ.
  local vf
  for vf in v_core v_installsh; do
    sed -n "/^$vf() {/,/^}/p" "$HERE/tests/verify.sh" \
      | grep -q '^[[:space:]]*v_terminfo' \
      || { bad "verify.sh — $vf does not call v_terminfo (that audit cannot see a missing entry)"; tmiss=1; }
  done
  [ "$tmiss" = 0 ] && ok "terminfo — kitty-terminfo + ncurses-term on all 3 surfaces, no per-user tic"

  # ── .gitconfig's delta hooks degrade on a box without delta ────────────────
  # Every dotfiles.list entry must EXIST in the repo. Step 60 and install.sh
  # only `warn "missing … — skipping"` for a path that isn't there, so a typo'd
  # manifest line would bake a golden without that file and nothing would go
  # red until someone looked (found while adding the vendored kitty theme,
  # 2026-09-13). The manifest is the single owner of the set — keep it honest.
  local mf mmiss=0
  while IFS= read -r mf; do
    [ -e "$HERE/$mf" ] || { bad "dotfiles.list names a path missing from the repo: $mf"; mmiss=1; }
  done < <(grep -vE '^[[:space:]]*(#|$)' "$HERE/dotfiles.list")
  [ "$mmiss" = 0 ] && ok "dotfiles.list — every entry exists in the repo ($(grep -cvE '^[[:space:]]*(#|$)' "$HERE/dotfiles.list") entries)"
  # ── dotfiles-install.sh: the ONE dotfile installer (install.sh + step 60) ──
  # Runs as the user into a scratch HOME (2026-09-22, assessment #1: step 60
  # used to do this as root through user-controlled paths). Symlink mode, copy
  # mode, backup exactly once, identical content untouched, a symlinked parent
  # REFUSED (never followed), root refused.
  local dh; dh="$(mktemp -d)"
  if HOME="$dh" bash "$HERE/dotfiles-install.sh" --src "$HERE" >/dev/null 2>&1 && [ -L "$dh/.zshrc" ] \
     && [ "$(readlink "$dh/.zshrc")" = "$HERE/.zshrc" ] && [ -L "$dh/.config/kitty/themes/catppuccin-mocha.conf" ]; then
    ok "dotfiles-install — symlink mode links every manifest entry into \$HOME (nested parents created)"
  else bad "dotfiles-install — symlink mode failed"; fi
  if HOME="$dh" bash "$HERE/dotfiles-install.sh" --copy --src "$HERE" >/dev/null 2>&1 && [ -f "$dh/.zshrc" ] && [ ! -L "$dh/.zshrc" ] \
     && cmp -s "$dh/.zshrc" "$HERE/.zshrc" && ! ls "$dh"/.zshrc.backup.* >/dev/null 2>&1; then
    ok "dotfiles-install — --copy replaces symlinks with byte-identical copies, no backup of a symlink"
  else bad "dotfiles-install — --copy failed or backed up a symlink"; fi
  local dout; dout="$(HOME="$dh" bash "$HERE/dotfiles-install.sh" --copy --src "$HERE" 2>&1)"
  if [ -z "$dout" ] && ! ls "$dh"/.zshrc.backup.* >/dev/null 2>&1; then ok "dotfiles-install — identical re-run is silent, no backup churn"
  else bad "dotfiles-install — identical re-run did work: $dout"; fi
  printf 'local edit\n' >> "$dh/.tmux.conf"
  HOME="$dh" bash "$HERE/dotfiles-install.sh" --copy --src "$HERE" >/dev/null 2>&1
  if [ "$(ls "$dh"/.tmux.conf.backup.* 2>/dev/null | wc -l)" = 1 ] && cmp -s "$dh/.tmux.conf" "$HERE/.tmux.conf"; then
    ok "dotfiles-install — a changed file is backed up exactly once, then replaced"
  else bad "dotfiles-install — backup-once broken"; fi
  rm -rf "$dh/.config" && mkdir -p "$dh/elsewhere" && ln -s "$dh/elsewhere" "$dh/.config"
  dout="$(HOME="$dh" bash "$HERE/dotfiles-install.sh" --copy --src "$HERE" 2>&1)"; local drc=$?
  if [ "$drc" != 0 ] && grep -q 'REFUSED' <<<"$dout" && [ -z "$(ls -A "$dh/elsewhere")" ]; then
    ok "dotfiles-install — a symlinked parent (~/.config -> elsewhere) is REFUSED, nothing written through it, exit non-zero"
  else bad "dotfiles-install — followed a symlinked parent (rc=$drc): $(ls -A "$dh/elsewhere" 2>/dev/null | head -2)"; fi
  rm -rf "$dh"
  if grep -q 'id -u)" = 0' "$HERE/dotfiles-install.sh" && grep -q 'refusing to run as root' "$HERE/dotfiles-install.sh"; then
    ok "dotfiles-install — refuses uid 0 (provision runs it via as_user)"
  else bad "dotfiles-install — the uid-0 refusal is gone"; fi
  # No root WRITE into a home, in any step. Steps run as root — lib.sh sets
  # SUDO="" then — so a write is a root write whether or not it says $SUDO, and
  # the old `$SUDO`-only pattern missed bare `rm "$TARGET_HOME/x"` as well as the
  # braced `${TARGET_HOME}` form (round-2 review). This is a TEXT SCAN, not a
  # proof: it catches the common shapes — a mutating command, bare or after
  # $SUDO, then/do/else, ; & | ( — aimed at $VAR or ${VAR} of a home path, plus
  # redirects into one. Lines through as_user/as_owner are skipped: they run as
  # the owner. Root may still READ a home (finalize's verify pass does).
  # Home aliases are derived per file from assignments off TARGET_HOME.
  # Capture, never `{ … } | grep -q .` — under pipefail that could not fail.
  local rh rhit=0 rcode ralias rpat ra rwrites
  local rmut='rm|rmdir|mv|cp|install|tee|mkdir|chown|chgrp|chmod|ln|tar|truncate|dd|touch|sed|shred|rsync'
  for rh in "$HERE"/provision/steps/*.sh; do
    rcode="$(grep -vE '^[[:space:]]*#' "$rh" | grep -vE 'as_user|as_owner' || true)"
    ralias="$(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=["]?\$\{?TARGET_HOME' <<<"$rcode" \
              | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/' | LC_ALL=C sort -u)"
    rpat='\$\{?TARGET_HOME|"\$\{?home|"\$\{?dst'
    for ra in $ralias; do rpat="$rpat|\\\$\{?$ra"; done
    rwrites="$( { grep -E "(^|[;&|(]|\\\$SUDO|then|do|else)[[:space:]]*(env[[:space:]]+[^[:space:]]+=[^[:space:]]*[[:space:]]+)*($rmut)\\b[^#]*($rpat)" <<<"$rcode"
                 grep -E "(^|[^-])>[[:space:]]*\"?($rpat)" <<<"$rcode"; } || true )"   # not the "->" arrows in log text
    if [ -n "$rwrites" ]; then
      bad "root-in-home — $(basename "$rh") looks like it writes a home as root:$(printf '\n      %s' "$rwrites")"; rhit=1; fi
  done
  if grep -qE '^\s*\$SUDO rm -rf "\$home/' "$HERE/provision/steps/90-finalize.sh"; then
    bad "root-in-home — finalize scrubs a home as root instead of as its owner"; rhit=1; fi
  grep -q 'as_owner "\$owner"' "$HERE/provision/steps/90-finalize.sh" || { bad "root-in-home — finalize lost its as_owner scrub"; rhit=1; }
  [ "$rhit" = 0 ] && ok "root-in-home — text scan of all $(ls "$HERE"/provision/steps/*.sh | wc -l) steps found no root write into a home; finalize scrubs each home as its owner"
  # finalize: keys always removed (no keep branch, no flag), every account
  if ! grep -q 'cloud_init_reinjects\|KEEP_AUTHORIZED' "$HERE/provision/steps/90-finalize.sh" \
     && grep -q 'authorized_keys' "$HERE/provision/steps/90-finalize.sh" \
     && grep -q '\$3>=1000' "$HERE/provision/steps/90-finalize.sh"; then
    ok "finalize — authorized_keys removed unconditionally, every uid>=1000 account + root scrubbed, no keep flag"
  else bad "finalize — a keep-keys branch/flag is back, or the account set shrank to the target user"; fi
  # The tracked dotfiles must PARSE with their own tools — a syntax slip in a
  # file that ships to every box is the cheapest bug to catch here. git is
  # always present; zsh and tmux are checked where installed — the stock
  # GitHub runners have neither (the first push went red on zsh). Added with
  # the 2026-09-13 housekeeping pass (T1/T3/T5/T7/T11).
  if command -v zsh >/dev/null 2>&1; then check "dotfiles — .zshrc parses (zsh -n)" zsh -n "$HERE/.zshrc"
  else skip "dotfiles — .zshrc parse (zsh not installed here — the GitHub runners lack it; found in CI 2026-09-13)"; fi
  check "dotfiles — .gitconfig parses (git config --list)" git config --file "$HERE/.gitconfig" --list
  # tmux never fails on a bad config — `start-server -f bad.conf` exits 0 and
  # hides the error behind a "config error" prompt at attach time, and
  # `source-file` prints "invalid option: …" but still exits 0. The only honest
  # signal is source-file's stderr, so assert it is EMPTY (mutation-checked
  # with a bogus option).
  if command -v tmux >/dev/null 2>&1; then
    local tmo
    tmo="$(command tmux -L smoke-dry -f /dev/null start-server \; source-file "$HERE/.tmux.conf" \; kill-server 2>&1)"
    if [ -z "$tmo" ]; then ok "dotfiles — .tmux.conf sources with no errors (headless server)"
    else bad "dotfiles — .tmux.conf errors: $tmo"; fi
  else skip "dotfiles — .tmux.conf parse (tmux not installed here)"; fi
  # The modern-defaults keys and the global ignore hook (2026-09-13). One
  # representative from each concern: a behaviour key, the ignore file the
  # manifest ships, and the delta feature lazygit's config selects by name.
  local gd
  for gd in pull.rebase=true core.excludesfile=~/.config/git/ignore delta.lazygit.side-by-side=false init.defaultbranch=main; do
    if [ "$(git config --file "$HERE/.gitconfig" --get "${gd%%=*}" 2>/dev/null)" = "${gd#*=}" ]; then ok ".gitconfig ${gd%%=*} = ${gd#*=}"
    else bad ".gitconfig ${gd%%=*} — expected ${gd#*=}, got '$(git config --file "$HERE/.gitconfig" --get "${gd%%=*}" 2>/dev/null)'"; fi
  done
  # The two zsh integrations must keep their order: fzf binds Ctrl-R too, and
  # only because atuin's init runs LATER does atuin keep it (last binding wins).
  if [ "$(grep -n 'fzf --zsh' "$HERE/.zshrc" | cut -d: -f1 | head -1)" -lt "$(grep -n 'atuin init zsh' "$HERE/.zshrc" | cut -d: -f1 | head -1)" ] 2>/dev/null; then
    ok ".zshrc — fzf integration is sourced BEFORE atuin (atuin keeps Ctrl-R)"
  else bad ".zshrc — fzf must be sourced before atuin, or fzf steals Ctrl-R"; fi
  # .gitconfig ships to EVERY box via dotfiles.list, but git-delta is in the
  # FULL Brewfile only (minimal drops the niceties; install.sh installs fewer
  # still). Two real failure modes, one of which bit during development:
  #   1. git-config treats an UNQUOTED `;` as a comment, so the value is
  #      silently truncated at the first one and every paged git command dies
  #      with "Syntax error: end of file unexpected".
  #   2. An unguarded pager breaks `git diff` outright where delta is absent.
  local gk gv
  for gk in core.pager interactive.diffFilter; do
    gv="$(git config --file "$HERE/.gitconfig" --get "$gk" 2>/dev/null)"
    if [ "${gv%fi}" != "$gv" ]; then ok ".gitconfig $gk — value intact (not cut at ';')"
    else bad ".gitconfig $gk — truncated or missing: '$gv'"; fi
    # PATH without the brew prefix = a box that never installed delta.
    if printf 'x\n' | PATH=/usr/bin:/bin LESS=FRX sh -c "$gv" >/dev/null 2>&1; then
      ok ".gitconfig $gk — falls back cleanly with delta absent"
    else bad ".gitconfig $gk — fails when delta is absent"; fi
  done
  # Same two failure modes for the gh credential helper (added 2026-09-13 after
  # the Gen-3 clone had gh logged in and still could not push): the value must
  # survive git-config's `;`-comment rule, and with gh ABSENT it must stay
  # silent so git falls through to its own prompt instead of erroring.
  local ch
  ch="$(git config --file "$HERE/.gitconfig" --get 'credential.https://github.com.helper' 2>/dev/null)"
  if [ "${ch%\}; f}" != "$ch" ] && grep -q 'command -v gh' <<<"$ch"; then
    ok ".gitconfig credential helper — intact and guarded on gh"
  else bad ".gitconfig credential helper — truncated, unguarded or missing: '$ch'"; fi
  if out="$(printf 'protocol=https\nhost=github.com\n' | PATH=/usr/bin:/bin GIT_TERMINAL_PROMPT=0 \
             git -c "credential.https://github.com.helper=$ch" credential fill 2>&1)"; then
    bad ".gitconfig credential helper — produced credentials with gh absent?!"
  elif grep -q 'Syntax error\|not found' <<<"$out"; then
    bad ".gitconfig credential helper — errors when gh is absent: $out"
  else ok ".gitconfig credential helper — silent with gh absent (git falls through to its prompt)"; fi

  # ── the "no non-root user" edge ────────────────────────────────────────────
  # The auto-detect chain's last rung is a GUESS ("ubuntu") and was never
  # checked, so a box with no non-root account got an EMPTY $TARGET_HOME
  # instead of a refusal. Sourcing lib.sh mutates nothing, so exercising the
  # real (non-dry) die path is safe in this tier.
  #
  # BOTH `getent` and `id` are shimmed. Shimming only getent would make the
  # test vacuous on any host that happens to have a real `ubuntu` account —
  # it would pass without ever reaching the guard.
  local shim; shim="$(mktemp -d)"
  printf '#!/bin/sh\nexit 2\n' > "$shim/getent"
  printf '#!/bin/sh\nfor a in "$@"; do case "$a" in ubuntu|__nosuch__) exit 1;; esac; done\nexec /usr/bin/id "$@"\n' > "$shim/id"
  chmod +x "$shim/getent" "$shim/id"
  local nro nrc
  nro="$(PATH="$shim:$PATH" PROVISION_USER='' SUDO_USER=__nosuch__ DRY_RUN=0 \
         bash -c 'source "$1"/provision/lib.sh' _ "$HERE" 2>&1)"; nrc=$?
  if [ "$nrc" = 1 ] && grep -q "No non-root user on this box" <<<"$nro"; then
    ok "no-non-root-user — refused (exit 1)"
  else bad "no-non-root-user — exit $nrc, said: $nro"; fi
  nro="$(PATH="$shim:$PATH" PROVISION_USER='' SUDO_USER=__nosuch__ DRY_RUN=1 \
         bash -c 'source "$1"/provision/lib.sh' _ "$HERE" 2>&1)"; nrc=$?
  if [ "$nrc" = 0 ] && grep -q "no non-root user found" <<<"$nro"; then
    ok "no-non-root-user — dry-run warns, never blocks a preview"
  else bad "no-non-root-user (dry) — exit $nrc, said: $nro"; fi
  rm -rf "$shim"
}
