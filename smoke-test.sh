#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# smoke-test.sh — re-runnable smoke checks for this repo. Three tiers:
#
#   bash smoke-test.sh lint        shellcheck every script (anywhere; no sudo)
#   bash smoke-test.sh dry        provision.sh --dry-run matrix + assertions
#                                  (anywhere; no sudo, no changes, no network)
#   bash smoke-test.sh verify [scenario]
#                                  read-only end-state audit ON a provisioned
#                                  box/clone. Scenarios: auto (default) | plain
#                                  | copy | minimal | desktop | rootless |
#                                  golden-clone | installsh. Add-ons compose:
#                                  `verify plain desktop rootless` runs all 3.
#   bash smoke-test.sh scenarios   print the live test runbook (S1–S11)
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
      '!'*) if grep -qF "${p#!}" <<<"$out"; then bad "$desc — unexpectedly saw: ${p#!}"
            else ok "$desc — absent: ${p#!}"; fi ;;
      *)    if grep -qF "$p" <<<"$out"; then ok "$desc — saw: $p"
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
  dry_case "bogus profile dies" 1 PROFILE=bogus --
  dry_case "minimal+desktop dies" 1 PROFILE=minimal INSTALL_DESKTOP=1 --
  dry_case "lowercase flag typo warns" 0 golden_image=1 -- \
    "did you mean 'GOLDEN_IMAGE'" "finalize: skipped"
}

# ── verify (on-box end-state audit) ─────────────────────────────────────────
v_core() {
  hdr "verify: core (every provisioned box)"
  check "zsh installed"            command -v zsh
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
}

v_rootless() {
  hdr "verify: rootless docker (run as the login user)"
  check "docker context = rootless" bash -c '[ "$(docker context show 2>/dev/null)" = rootless ]'
  check "user docker service active" systemctl --user is-active --quiet docker
  check "linger enabled" bash -c 'loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q yes'
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
    # auto-detect: install.sh box first — provision.sh ALWAYS writes the step-80
    # notes file (and it survives the golden wipe), so its absence means this box
    # was never provisioned, only bootstrapped.
    if [ ! -f "$HOME/PROVISION-NEXT-STEPS.md" ]; then
      args+=(installsh)
    elif dpkg-query -W codium >/dev/null 2>&1 || [ -x "$HOME/.cargo/bin/alacritty" ]; then
      args+=(full); else args+=(minimal); fi
    if [ -L "$HOME/.zshrc" ]; then args+=(plain); else args+=(copy); fi
    echo "auto-detected: ${args[*]}"
  fi
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
After each live run:  bash smoke-test.sh verify <scenario...>

 S1  dry            bash smoke-test.sh lint && bash smoke-test.sh dry     (any box)
 S2  plain          sudo env PROVISION_USER=$USER bash provision/provision.sh
                    -> verify plain full
 S3  re-run         repeat S2; expect exit 0, idempotent     -> verify plain full
 S4  desktop        sudo env INSTALL_DESKTOP=1 PROVISION_USER=$USER bash provision/provision.sh
                    -> verify plain full desktop
 S5  rootless       relax userns per ~/PROVISION-NEXT-STEPS.md, then
                    sudo env DOCKER_ROOTLESS=1 PROVISION_USER=$USER bash provision/provision.sh
                    -> verify plain full rootless
 S6  copy           sudo env DOTFILES_COPY=1 PROVISION_USER=$USER bash provision/provision.sh
                    -> verify copy full
 S7  golden         sudo env GOLDEN_IMAGE=1 PROVISION_USER=$USER bash provision/provision.sh
                    (clone+log under /tmp!)  -> on a BOOTED CLONE: verify golden-clone full
 S8  golden-desktop S7 + INSTALL_DESKTOP=1   -> clone: verify golden-clone full desktop
 S9  iterate-golden re-run S7/S8 ON a booted golden clone (MUST keep GOLDEN_IMAGE=1
                    or DOTFILES_COPY=1 — plain re-run would symlink over the copies)
                    [+ APT_UPGRADE=1 for a true bring-to-latest]
 S10 install.sh     bash install.sh && exec zsh; re-run for idempotency; --copy variant
                    -> verify installsh   (its OWN contract — NOT verify plain:
                    no tmux/rustup/claude/docker/step-80, 5-formula brew subset)
 S11 minimal        sudo env PROFILE=minimal PROVISION_USER=$USER bash provision/provision.sh
                    -> verify minimal plain

Covered live so far: S2/S3 (Phase A, C2), S5 (C2), S7 abort-gate (Phase B),
S8 (C Run 1), S9 (Phase D), S11 + S10 (2026-08-05). Pending live: S4, S6.
Deliberately NOT a scenario: GOLDEN_IMAGE+DOCKER_ROOTLESS (bakes the userns
relaxation into the image — per-clone opt-in is the design).
EOF
}

# ── main ────────────────────────────────────────────────────────────────────
case "${1:-}" in
  lint)      cmd_lint; summary ;;
  dry)       cmd_dry; summary ;;
  verify)    shift; cmd_verify "$@"; summary ;;
  scenarios) cmd_scenarios ;;
  all)       cmd_lint; cmd_dry; summary ;;
  *) echo "usage: bash smoke-test.sh {lint|dry|all|verify [auto|plain|copy|full|minimal|desktop|rootless|golden-clone ...]|scenarios}"; exit 2 ;;
esac
