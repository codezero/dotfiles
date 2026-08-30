#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# smoke-test.sh — re-runnable smoke checks for this repo. Three tiers:
#
#   bash smoke-test.sh lint        shellcheck every script (anywhere; no sudo)
#   bash smoke-test.sh dry        provision.sh --dry-run matrix + assertions
#                                  (anywhere; no sudo, no changes, no network)
#   bash smoke-test.sh verify [S<n> | token...]
#                                  read-only end-state audit ON a provisioned
#                                  box/clone. Takes a runbook id (`verify S4`)
#                                  and expands it, or raw tokens, or nothing at
#                                  all (auto-detects mode+profile from the box).
#                                  The tokens are not peers — one MODE, one
#                                  PROFILE, any number of ADD-ONs, and
#                                  `installsh` stands alone because it REPLACES
#                                  the core audit. `scenarios` prints the map.
#   bash smoke-test.sh scenarios   the live runbook (S1–S14) + the verify
#                                  vocabulary and how the tokens compose
#
# lint+dry are the pre-commit/dev-box tier; verify codifies the hand audits
# from phases A–D. NEVER calls Electron `--version` (hangs headless) — package
# presence is checked with dpkg-query / command -v.
# ──────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[2m- %s (skipped)\033[0m\n' "$*"; SKIP=$((SKIP+1)); }
hdr()  { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

# check <description> <command...>  — pass/fail on the command's exit status.
check()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
# checkno <description> <command...> — inverted: pass when the command FAILS.
checkno() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

summary() {
  printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
  # A skipped check is NOT a passing one — it means the property was never
  # verified. Without this line "36 passed, 1 skipped" reads as green, which is
  # how an unverified assertion quietly becomes a believed one.
  [ "$SKIP" -gt 0 ] && printf '\033[1;33m⚠ %d check(s) SKIPPED — those properties are NOT verified\033[0m\n' "$SKIP"
  [ "$FAIL" -eq 0 ]
}

# ── lint ────────────────────────────────────────────────────────────────────
# --severity=warning: the tree is clean at the warning level; the remaining
# info-level notes (SC2016 as_user '…$HOME…', SC2024 dconf redirects, SC2015)
# are intentional — see CLAUDE.md.
cmd_lint() {
  command -v shellcheck >/dev/null 2>&1 \
    || { echo "shellcheck not found — brew install shellcheck"; exit 2; }
  hdr "lint (shellcheck, severity=warning; info notes are intentional)"
  local s
  for s in "$HERE"/provision/steps/*.sh; do
    check "steps/$(basename "$s")" \
      shellcheck -x --severity=warning --source-path="$HERE/provision" "$s"
  done
  for s in provision/provision.sh provision/lib.sh provision/inventory-export.sh \
           install.sh smoke-test.sh; do
    [ -f "$HERE/$s" ] || { skip "$s (missing)"; continue; }
    check "$s" shellcheck -x --severity=warning --source-path="$HERE/provision" "$HERE/$s"
  done
}

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
    "finalize: skipped" "rootless Docker: skipped" "GNOME dconf: skipped" \
    "step: 80-next-steps.sh" "symlink " "!PROFILE=minimal —"
  dry_case "desktop" 0 INSTALL_DESKTOP=1 -- \
    "!GNOME dconf: skipped"
  dry_case "golden" 0 GOLDEN_IMAGE=1 -- \
    "truncate /etc/machine-id" "copy " "!symlink "
  dry_case "copy" 0 DOTFILES_COPY=1 -- \
    "(self-contained)" "finalize: skipped"
  dry_case "rootless" 0 DOCKER_ROOTLESS=1 -- \
    "preflight: require kernel.apparmor_restrict_unprivileged_userns"
  dry_case "minimal" 0 PROFILE=minimal -- \
    "using apt.minimal.list" "using Brewfile.minimal" \
    "VSCodium: skipped (PROFILE=minimal)" "Cursor: skipped (PROFILE=minimal)" \
    "alacritty: skipped (PROFILE=minimal)" "flatpak: skipped (PROFILE=minimal)"
  # S14's combination. The load-bearing claim is that PROFILE=minimal drops the
  # GUI set while KEEPING Docker *and* its rootless prerequisites — a future
  # `minimal &&` gate on the Docker block would silently break rootless on the
  # very profile (headless agent box) most likely to want it.
  dry_case "minimal+rootless" 0 PROFILE=minimal DOCKER_ROOTLESS=1 -- \
    "docker-ce-rootless-extras uidmap dbus-user-session" \
    "preflight: require kernel.apparmor_restrict_unprivileged_userns" \
    "Cursor: skipped (PROFILE=minimal)" "!Docker: skipped"
  dry_case "bogus profile dies" 1 PROFILE=bogus --
  dry_case "minimal+desktop dies" 1 PROFILE=minimal INSTALL_DESKTOP=1 --
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
  if cmd_scenarios | grep -q "MODE (exactly one"; then ok "scenarios — composition rules present"
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
  nst_case "follow-ups: full, no desktop" "$nst_home" -- \
    "desktop was installed here" "!GNOME's monospace font" \
    "Docker access for"
  nst_case "follow-ups: full + desktop" "$nst_home" INSTALL_DESKTOP=1 -- \
    "GNOME's monospace font is already set to it" \
    "!desktop was installed here"
  nst_case "follow-ups: minimal" "$nst_home" PROFILE=minimal -- \
    "No Nerd Font on this profile" \
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

# ── scenario id -> verify tokens ────────────────────────────────────────────
# THE single owner of this mapping. The runbook prints "-> verify S4" and this
# turns it into tokens, so the two vocabularies that used to be translated by
# hand (F item 4) can no longer drift: there is one thing to type, and the
# expansion is echoed at run time so it is never a black box.
# Exit 1 = a known id with nothing to audit; exit 2 = not an id at all.
scenario_tokens() {
  case "${1,,}" in
    s2|s3|s12|s13) echo "plain full" ;;
    s4)            echo "plain full desktop" ;;
    s5)            echo "plain full rootless" ;;
    s6)            echo "copy full" ;;
    s7|s9)         echo "golden-clone full" ;;
    s8)            echo "golden-clone full desktop" ;;
    s10)           echo "installsh" ;;
    s11)           echo "minimal plain" ;;
    s14)           echo "minimal plain rootless" ;;
    s1)            return 1 ;;   # lint+dry tier — there is no box end-state to audit
    *)             return 2 ;;
  esac
}

# Enforce the composition rules `scenarios` documents (F item 5). A rule that is
# only written down is a rule that silently does not hold — and the failure mode
# here is nasty: `verify full minimal` would print a wall of red for the wrong
# reason (each token correctly asserting the negation of the other) and read as a
# regression rather than as operator error.
_tok_has() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

verify_validate() {
  local list="$*" conflict=""
  _tok_has plain "$list"     && _tok_has copy "$list" \
    && conflict="plain + copy — a box's dotfiles are symlinks or real files, not both"
  _tok_has plain "$list"     && _tok_has golden-clone "$list" \
    && conflict="plain + golden-clone — golden-clone implies copy mode"
  _tok_has full "$list"      && _tok_has minimal "$list" \
    && conflict="full + minimal — one asserts the GUI toolchain is present, the other that it is absent"
  _tok_has installsh "$list" && { _tok_has full "$list" || _tok_has minimal "$list" \
                                  || _tok_has golden-clone "$list"; } \
    && conflict="installsh + a provision profile — installsh REPLACES the core audit because install.sh has a different contract"
  [ -z "$conflict" ] && return 0
  echo "contradictory verify tokens: $conflict" >&2
  echo "see the vocabulary at the end of: bash smoke-test.sh scenarios" >&2
  exit 2
}

# ── verify (on-box end-state audit) ─────────────────────────────────────────
v_core() {
  hdr "verify: core (every provisioned box)"
  check "zsh installed"            command -v zsh
  # Step 60 runs chsh; nothing audited whether it took. v_installsh checked this
  # from the start — v_core didn't, which was simply an asymmetry.
  check "default shell = zsh (chsh took)" \
    bash -c '[ "$(getent passwd "$USER" | cut -d: -f7)" = "$(command -v zsh)" ]'
  check "oh-my-zsh present"        test -d "$HOME/.oh-my-zsh"
  check "p10k theme present"       test -d "$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
  check "zsh starts clean"         zsh -ic true
  local f
  for f in .zshrc .p10k.zsh .gitconfig .tmux.conf; do
    check "dotfile $f installed"   test -e "$HOME/$f"
  done
  check "git"                      command -v git
  check "tmux"                     command -v tmux
  check "brew"                     test -x /home/linuxbrew/.linuxbrew/bin/brew
  check "jq (brew)"                test -x /home/linuxbrew/.linuxbrew/bin/jq
  check "gh (brew)"                test -x /home/linuxbrew/.linuxbrew/bin/gh
  check "ripgrep (brew)"           test -x /home/linuxbrew/.linuxbrew/bin/rg
  check "gitleaks (brew)"          test -x /home/linuxbrew/.linuxbrew/bin/gitleaks
  check "rustup toolchain"         test -x "$HOME/.cargo/bin/cargo"
  check "claude installed"         test -x "$HOME/.local/bin/claude"
  check "docker CLI"               command -v docker
  check "step 80 notes file"       test -f "$HOME/PROVISION-NEXT-STEPS.md"
  check "step 80 MOTD drop-in"     test -x /etc/update-motd.d/99-provision-next-steps
  # The pointer bakes in an absolute path under a 0750 home, so it must name the
  # owner and how another account reads it — otherwise every non-target user
  # (the cloud-init norm, seen live in S13) is aimed at a path it gets EACCES on.
  check "MOTD names the owner (readable cross-account)" \
    bash -c 'grep -q "sudo -iu" /etc/update-motd.d/99-provision-next-steps'
}

v_full_extras() {  # full-profile installs (skipped for minimal)
  hdr "verify: full-profile extras"
  check "codium installed (dpkg)"  dpkg-query -W codium
  check "cursor installed (dpkg)"  dpkg-query -W cursor
  check "cursor.sources arch-pinned (single arch)" \
    bash -c '[ "$(grep -c "," /etc/apt/sources.list.d/cursor.sources)" = 0 ] && grep -q "^Architectures: $(dpkg --print-architecture)$" /etc/apt/sources.list.d/cursor.sources'
  if sudo -n true 2>/dev/null; then
    check "cursor debconf opt-out preseeded" \
      bash -c 'sudo -n debconf-show cursor 2>/dev/null | grep -q "add-cursor-repo: false"'
  else skip "cursor debconf preseed (needs sudo)"; fi
  check "alacritty built"          test -x "$HOME/.cargo/bin/alacritty"
  # Design invariant (CLAUDE.md): Alacritty was the only user snap, and it is
  # built via cargo so the machine needs no snapd. NB this asserts WE installed
  # no snap — not that snapd is absent, which would be wrong on a stock Ubuntu
  # desktop image where snapd ships by default.
  checkno "alacritty NOT from snap (cargo build is the design)" snap list alacritty
  check "alacritty themes clone"   test -f "$HOME/.config/alacritty/themes/themes/catppuccin_mocha.toml"
  check "MesloLGS NF system-wide"  bash -c 'ls /usr/local/share/fonts/MesloLGS-NF/*.ttf'
  check "_alacritty completion world-readable" \
    bash -c '[ -r /usr/share/zsh/vendor-completions/_alacritty ]'
  check "bat (brew)"               test -x /home/linuxbrew/.linuxbrew/bin/bat
  check "eza (brew)"               test -x /home/linuxbrew/.linuxbrew/bin/eza
  check "flatpak + flathub"        bash -c 'flatpak remotes 2>/dev/null | grep -q flathub'
}

v_minimal() {
  hdr "verify: minimal profile (lean assertions)"
  checkno "codium ABSENT"          dpkg-query -W codium
  checkno "cursor ABSENT"          dpkg-query -W cursor
  checkno "alacritty ABSENT"       test -e "$HOME/.cargo/bin/alacritty"
  checkno "flatpak ABSENT"         command -v flatpak
  checkno "bat ABSENT"             test -e /home/linuxbrew/.linuxbrew/bin/bat
  checkno "eza ABSENT"             test -e /home/linuxbrew/.linuxbrew/bin/eza
  checkno "zoxide ABSENT"          test -e /home/linuxbrew/.linuxbrew/bin/zoxide
  check  "shellcheck (brew, kept)" test -x /home/linuxbrew/.linuxbrew/bin/shellcheck
  # The notes must not CLAIM the font is installed (step 36 was skipped), but
  # must explain the tofu you'd see in a terminal opened ON this box.
  check   "notes carry the no-Nerd-Font note" \
    bash -c 'grep -q "No Nerd Font on this profile" "$HOME/PROVISION-NEXT-STEPS.md"'
  checkno "notes do NOT claim the font is installed" \
    bash -c 'grep -q "installed system-wide" "$HOME/PROVISION-NEXT-STEPS.md"'
  checkno "MesloLGS ABSENT system-wide" \
    bash -c 'ls /usr/local/share/fonts/MesloLGS-NF/*.ttf'
}

v_installsh() {
  # install.sh's OWN contract — deliberately NOT v_core. install.sh is the
  # lightweight "shell + dotfiles" entry point: no tmux, no rustup/claude/docker,
  # no step-80 files, and only its own 5-package brew subset. Auditing it with
  # v_core would red-flag ~9 things it never claims to install.
  hdr "verify: install.sh bootstrap (shell + dotfiles only)"
  check "zsh installed"          command -v zsh
  # tmux: install.sh ships .tmux.conf and .zshrc loads omz's tmux plugin, which
  # nags on every shell start when the binary is missing (found live, S10).
  check "tmux installed"         command -v tmux
  check "oh-my-zsh present"      test -f "$HOME/.oh-my-zsh/oh-my-zsh.sh"
  check "p10k theme present"     test -f "$HOME/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme"
  check "zsh starts clean"       zsh -ic true
  check "default shell = zsh"    bash -c '[ "$(getent passwd "$USER" | cut -d: -f7)" = "$(command -v zsh)" ]'
  # Dotfile set from the shared manifest — same source of truth install.sh reads,
  # so the audit can't drift from what was deployed.
  local f
  while IFS= read -r f; do
    check "dotfile $f installed" test -e "$HOME/$f"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$HERE/dotfiles.list")
  check "brew"                   test -x /home/linuxbrew/.linuxbrew/bin/brew
  local b
  for b in nvm eza bat zoxide jq; do
    check "$b (brew subset)"     bash -c "test -e /home/linuxbrew/.linuxbrew/bin/$b || /home/linuxbrew/.linuxbrew/bin/brew list --formula $b"
  done
  check "\$HOME/.nvm dir (brew nvm needs it)" test -d "$HOME/.nvm"
  check "alacritty themes clone" test -f "$HOME/.config/alacritty/themes/themes/catppuccin_mocha.toml"
  check "MesloLGS NF (user font dir)" \
    bash -c 'ls "$HOME"/.local/share/fonts/MesloLGS*.ttf'
}

v_mode() {  # $1 = symlink|copy
  hdr "verify: dotfile mode = $1"
  if [ "$1" = copy ]; then
    checkno ".zshrc is NOT a symlink (copy mode)" test -L "$HOME/.zshrc"
  else
    check ".zshrc is a symlink (repo is source of truth)" test -L "$HOME/.zshrc"
  fi
  # Presence is not correctness: `test -e` passes for ANY file, so a stale copy
  # from an older commit — exactly what copy mode invites, since edits stop
  # flowing back — would sail through every other check. Compare CONTENT.
  # Files only: directory entries (.config/nvim) legitimately drift once used,
  # because lazy-lock.json is deliberately untracked, so a tree diff would
  # false-positive. In symlink mode cmp follows the link and is trivially true —
  # that is fine, the assertion that matters there is the -L check above.
  #
  # SCOPE: this is meaningful on a FRESHLY PROVISIONED box, which is what verify
  # is for. On a box that has been used for a while, some of these files are
  # app-managed and drift by design — Claude Code rewrites .claude/settings.json,
  # `p10k configure` rewrites .p10k.zsh. In symlink mode those writes land in the
  # repo (no drift); in COPY mode they diverge legitimately. Read a red here as
  # "home and repo differ", then judge the direction — it is not automatically
  # a provisioning failure.
  local f bad_n=0
  while IFS= read -r f; do
    [ -f "$HERE/$f" ] || continue          # skip dirs + entries missing from the repo
    cmp -s "$HERE/$f" "$HOME/$f" || { bad "content differs from repo: $f"; bad_n=$((bad_n+1)); }
  done < <(grep -vE '^[[:space:]]*(#|$)' "$HERE/dotfiles.list")
  [ "$bad_n" -eq 0 ] && ok "file dotfiles match the repo byte-for-byte"
}

v_desktop() {
  hdr "verify: desktop"
  check "ubuntu-desktop installed (dpkg)" dpkg-query -W ubuntu-desktop
  check "dconf settings shipped"          test -f "$HERE/provision/gnome/dconf-settings.ini"
  # Read the settings BACK off the box — "the fragment exists in the repo" says
  # nothing about whether step 55's `dconf load` actually landed. Two distinctive
  # keys whose distro defaults differ from ours ('default' / no accent).
  # Reads hit the user's dconf db directly, so no session bus is needed.
  check "dconf applied: color-scheme=prefer-dark" \
    bash -c 'dconf read /org/gnome/desktop/interface/color-scheme 2>/dev/null | grep -q prefer-dark'
  check "dconf applied: accent-color=orange" \
    bash -c 'dconf read /org/gnome/desktop/interface/accent-color 2>/dev/null | grep -q orange'
  # Without this the stock terminal renders p10k glyphs as tofu even though the
  # font is installed system-wide (found live, S4).
  check "dconf applied: monospace font = MesloLGS NF" \
    bash -c 'dconf read /org/gnome/desktop/interface/monospace-font-name 2>/dev/null | grep -q "MesloLGS NF"'
}

v_rootless() {
  hdr "verify: rootless docker (run as the login user)"
  check "docker context = rootless" bash -c '[ "$(docker context show 2>/dev/null)" = rootless ]'
  # ...but the context is only a LABEL: one NAMED rootless can point straight at
  # the rootful daemon, which is exactly the d613f1b failure mode. Read the
  # daemon. This pair is what actually proved S14 — and it was run by hand,
  # never by the harness, so the audit could still have passed a rootful box.
  check "daemon is really rootless (not just the context name)" \
    bash -c 'docker info --format "{{.SecurityOptions}}" 2>/dev/null | grep -q "name=rootless"'
  check "image store is the user's, not /var/lib/docker" \
    bash -c '[ "$(docker info --format "{{.DockerRootDir}}" 2>/dev/null)" = "$HOME/.local/share/docker" ]'
  check "user docker service active" systemctl --user is-active --quiet docker
  check "linger enabled" bash -c 'loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q yes'
  # F item 10: on a box where rootless actually came up, the follow-ups must not
  # still recite the how-to-set-it-up recipe.
  check "notes file has no stale rootless recipe" \
    bash -c '! grep -q "choose ONE" "$HOME/PROVISION-NEXT-STEPS.md"'
}

v_golden_clone() {
  hdr "verify: golden clone (booted from a captured image)"
  check  "machine-id regenerated (non-empty)" test -s /etc/machine-id
  check  "SSH host keys regenerated" bash -c 'ls /etc/ssh/ssh_host_* >/dev/null 2>&1'
  local p
  for p in .aws .gnupg .config/gh .config/gcloud .kube .npmrc .claude/.credentials.json; do
    checkno "cred path ABSENT: ~/$p" test -e "$HOME/$p"
  done
  checkno "no private keys in ~/.ssh" \
    bash -c 'grep -rlI "PRIVATE KEY" "$HOME/.ssh" 2>/dev/null | grep -q .'
  checkno "no repo clone in /tmp" test -d /tmp/dotfiles
}

cmd_verify() {
  local args=("$@")
  if [ "${#args[@]}" -eq 0 ] || [ "${args[0]}" = auto ]; then
    args=()
    # auto-detect: install.sh box first — provision.sh ALWAYS writes step 80's
    # notes file AND its MOTD drop-in (both survive the golden wipe), so with
    # neither present this box was never provisioned, only bootstrapped. Check
    # both for the same reason as the guard below: deleting the notes file is the
    # documented cleanup, so it alone would misread a tidied box as install.sh.
    if [ ! -f "$HOME/PROVISION-NEXT-STEPS.md" ] && \
       [ ! -e /etc/update-motd.d/99-provision-next-steps ]; then
      args+=(installsh)
    elif dpkg-query -W codium >/dev/null 2>&1 || [ -x "$HOME/.cargo/bin/alacritty" ]; then
      args+=(full); else args+=(minimal); fi
    if [ -L "$HOME/.zshrc" ]; then args+=(plain); else args+=(copy); fi
    echo "auto-detected: ${args[*]}"
  fi
  # Accept scenario ids (verify S4) as well as tokens (verify plain full desktop).
  if [ "${#args[@]}" -gt 0 ]; then
    local expanded=() x toks trc tk
    for x in "${args[@]}"; do
      case "$x" in
        [Ss][0-9]|[Ss][0-9][0-9])
          toks="$(scenario_tokens "$x")"; trc=$?
          if [ "$trc" = 1 ]; then
            echo "${x^^} is the lint+dry tier — run: bash smoke-test.sh lint && bash smoke-test.sh dry" >&2
            exit 2
          elif [ "$trc" != 0 ]; then
            echo "unknown scenario id: $x (see: bash smoke-test.sh scenarios)" >&2
            exit 2
          fi
          echo "${x^^} = verify $toks"
          read -ra tk <<<"$toks"; expanded+=("${tk[@]}") ;;
        *) expanded+=("$x") ;;
      esac
    done
    args=("${expanded[@]}")
    verify_validate "${args[@]}"
    # golden-clone already runs the copy-mode audit; passing both would run the
    # same assertions twice and inflate the count.
    if _tok_has golden-clone "${args[*]}" && _tok_has copy "${args[*]}"; then
      echo "note: dropping redundant 'copy' — golden-clone already includes it"
      local kept=(); for x in "${args[@]}"; do [ "$x" = copy ] || kept+=("$x"); done
      args=("${kept[@]}")
    fi
  fi

  # Guard: verify audits a PROVISIONED box or clone. Without this, auditing a box
  # that was never provisioned turns every provision-only assertion red for that
  # one reason — which reads like a regression instead of a category error.
  #
  # Marker = step 80's artifacts, either one. The notes file alone is not enough:
  # deleting it IS the documented "follow-ups done" cleanup, so a tidied box
  # would trip this falsely. The MOTD drop-in is root-owned, not part of that
  # cleanup, and only provision.sh ever writes it — so it survives as evidence.
  # Both survive the golden wipe by construction. installsh is exempt:
  # install.sh writes neither.
  case " ${args[*]} " in
    *" installsh "*) ;;
    *) if [ ! -f "$HOME/PROVISION-NEXT-STEPS.md" ] && \
          [ ! -e /etc/update-motd.d/99-provision-next-steps ]; then
         printf '\033[1;33m⚠ no sign of provision.sh on this box (neither %s nor the step-80 MOTD drop-in) — never provisioned, so the results below are NOT meaningful. Audit a provisioned box/clone, or use: verify installsh\033[0m\n\n' \
           "$HOME/PROVISION-NEXT-STEPS.md"
       fi ;;
  esac
  # installsh replaces the core audit rather than adding to it (different contract).
  case " ${args[*]} " in *" installsh "*) ;; *) v_core ;; esac
  local a
  for a in "${args[@]}"; do
    case "$a" in
      full)         v_full_extras ;;
      plain)        v_mode symlink ;;
      copy)         v_mode copy ;;
      minimal)      v_minimal ;;
      installsh)    v_installsh ;;
      desktop)      v_desktop ;;
      rootless)     v_rootless ;;
      golden-clone) v_mode copy; v_golden_clone ;;
      *) echo "unknown verify scenario: $a"; exit 2 ;;
    esac
  done
}

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
 S8  golden-desktop S7 + INSTALL_DESKTOP=1   -> on a booted clone: verify S8
 S9  iterate-golden re-run S7/S8 ON a booted golden clone (MUST keep GOLDEN_IMAGE=1
                    or DOTFILES_COPY=1 — plain re-run would symlink over the copies)
                    [+ APT_UPGRADE=1 for a true bring-to-latest]   -> verify S9
 S10 install.sh     bash install.sh && exec zsh; re-run for idempotency; --copy variant
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

Covered live so far: S2/S3 (Phase A, C2), S5 (C2), S7 abort-gate (Phase B),
S8 (C Run 1), S9 (Phase D), S11 + S10 + S4 + S6 + S12 (2026-08-05),
S13 (2026-08-16, AWS t4g.large arm64, real Ec2 datasource),
S14 (2026-08-21, minimal+rootless).
Pending live: none — every sunny-day scenario above has now run on real hardware.
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
  for id in S2 S3 S4 S5 S6 S7 S8 S9 S10 S11 S12 S13 S14; do
    toks="$(scenario_tokens "$id")" && printf '  %-4s = verify %s\n' "$id" "$toks"
  done
  cat <<'EOF'

The tokens are NOT peers — this is the part that was only ever in code comments:
  MODE (exactly one, and every scenario has one)
    plain          dotfiles are symlinks into the repo
    copy           dotfiles are real files (DOTFILES_COPY / GOLDEN_IMAGE)
    golden-clone   a booted clone: implies `copy`, adds the identity/credential
                   sweep. Don't pass `copy` as well — it's already in there.
  PROFILE (exactly one)
    full           asserts the GUI toolchain is PRESENT (codium/cursor/alacritty…)
    minimal        asserts those same things are ABSENT — the lean box's whole
                   claim is what it did NOT install
  ADD-ON (any number, order-free — they only add assertions)
    desktop        GNOME dconf settings, read back off the box
    rootless       docker context + user service + linger
  STANDALONE (never combine)
    installsh      install.sh's own contract, and it REPLACES the core audit
                   rather than adding to it: no tmux/rustup/claude/docker/step-80

Everything except `installsh` runs the core audit first. With no arguments,
`verify` auto-detects mode+profile from the box and says what it picked.
EOF
}

# ── main ────────────────────────────────────────────────────────────────────
case "${1:-}" in
  lint)      cmd_lint; summary ;;
  dry)       cmd_dry; summary ;;
  verify)    shift; cmd_verify "$@"; summary ;;
  scenarios) cmd_scenarios ;;
  all)       cmd_lint; cmd_dry; summary ;;
  *) echo "usage: bash smoke-test.sh {lint|dry|all|scenarios|verify [S<n> | token...]}"
     echo "       verify takes a runbook id (verify S4), raw tokens"
     echo "       (auto|plain|copy|full|minimal|desktop|rootless|golden-clone|installsh),"
     echo "       or nothing (auto-detect). Map + composition rules: smoke-test.sh scenarios"
     exit 2 ;;
esac
