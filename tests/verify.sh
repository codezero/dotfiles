#!/usr/bin/env bash
# tests/verify.sh — part of the smoke tier. Sourced by ../smoke-test.sh, which owns the
# CLI; this file only defines functions. Split out of the single 1,350-line
# smoke-test.sh (2026-09-22) so each tier is readable on its own — the
# external assessment's last open item. Shared helpers: tests/lib.sh.

# ── verify (on-box end-state audit) ─────────────────────────────────────────
# Terminfo for INBOUND ssh — shared by v_core and v_installsh, because BOTH
# entry points install kitty-terminfo + ncurses-term and both produce boxes
# whose whole purpose is to be ssh'd into. It lives here rather than being
# copied into each, so the two cannot drift.
#
# Probed with `env -i` deliberately: that is what a SECOND account, or root via
# `sudo -i`, actually sees. As the invoking user it would pass off a stale
# ~/.terminfo — precisely how the old step-36 per-user tic hid the fact that
# nobody else on the box had the entry. ncurses-base ships tmux-256color, so if
# THAT one fails the probe itself is broken rather than a package being absent.
v_terminfo() {
  local ti
  for ti in tmux-256color alacritty xterm-kitty; do
    check "terminfo $ti resolves for ANY account" \
      env -i /usr/bin/infocmp -1 "$ti"
  done
}

v_core() {
  hdr "verify: core (every provisioned box)"
  check "zsh installed"            command -v zsh
  # Step 60 runs chsh; nothing audited whether it took. v_installsh checked this
  # from the start — v_core didn't, which was simply an asymmetry.
  check "default shell = zsh (chsh took)" \
    bash -c '[ "$(getent passwd "$USER" | cut -d: -f7)" = "$(command -v zsh)" ]'
  v_terminfo
  check "oh-my-zsh present"        test -d "$HOME/.oh-my-zsh"
  check "p10k theme present"       test -d "$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
  # The pinned checkouts are AT their pins (pins.sh). A box whose omz/p10k/theme
  # moved — `omz update`, a stray `git pull` — is red here: that is what a pin
  # means. versions.lock records the actual SHA; a bump shows as drift once.
  local pd pv
  while IFS=$'\t' read -r pd pv; do
    [ -d "$HOME/$pd/.git" ] || { skip "pinned checkout $pd (not present)"; continue; }
    if [ "$(git -C "$HOME/$pd" rev-parse HEAD 2>/dev/null)" = "$pv" ] \
       && [ -z "$(git -C "$HOME/$pd" status --porcelain --untracked-files=no 2>/dev/null)" ]; then ok "pinned checkout at its pin and clean: $pd @ ${pv:0:12}"
    else bad "pinned checkout DRIFTED from pins.sh: $pd is at $(git -C "$HOME/$pd" rev-parse --short=12 HEAD 2>/dev/null) (pin ${pv:0:12}), tracked changes: $(git -C "$HOME/$pd" status --porcelain --untracked-files=no 2>/dev/null | wc -l)"; fi
  done <<EOF
.oh-my-zsh	$OMZ_SHA
.oh-my-zsh/custom/themes/powerlevel10k	$P10K_SHA
.config/alacritty/themes	$ALACRITTY_THEME_SHA
EOF
  check "zsh starts clean"         zsh -ic true
  # Every entry in dotfiles.list — step 60 installs the whole set on every
  # profile, and the list is the single owner of what that set is.
  local f
  while IFS= read -r f; do
    check "dotfile $f installed"   test -e "$HOME/$f"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$HERE/dotfiles.list")
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
  check "step 85 versions.lock"     test -s "$HOME/versions.lock"
  check "step 80 notes file"       test -f "$HOME/PROVISION-NEXT-STEPS.md"
  check "step 80 MOTD drop-in"     test -x /etc/update-motd.d/99-provision-next-steps
  # The pointer bakes in an absolute path under a 0750 home, so it must name the
  # owner and how another account reads it — otherwise every non-target user
  # (the cloud-init norm, seen live in S13) is aimed at a path it gets EACCES on.
  check "MOTD names the owner (readable cross-account)" \
    bash -c 'grep -q "sudo -iu" /etc/update-motd.d/99-provision-next-steps'
}

# Every `brew "..."` line in the ACTIVE Brewfile, in ONE assertion — so a newly
# added formula is covered the day it lands, with no per-package check to
# remember. Compares NAMES against `brew list --formula`, not binaries: the
# formula is `git-delta` while the binary is `delta` (cf. bat/batcat). Casks and
# taps are excluded on purpose — macOS-only casks fail-soft here by design, so
# asserting them would go red for a documented non-problem.
v_brewfile() {
  local bf="$HERE/provision/packages/$1"
  [ -f "$bf" ] || { skip "Brewfile audit ($1 missing)"; return; }
  check "every formula in $1 is installed" bash -c '
    bf="$1"; brew=/home/linuxbrew/.linuxbrew/bin/brew
    [ -x "$brew" ] || exit 1
    want=$(sed -n "s/^brew \"\([^\"]*\)\".*/\1/p" "$bf" | sed "s|.*/||" | sort -u)
    have=$("$brew" list --formula 2>/dev/null | sort -u)
    missing=$(comm -23 <(printf "%s\n" "$want") <(printf "%s\n" "$have"))
    [ -z "$missing" ] || { echo "missing: $missing" >&2; exit 1; }
  ' _ "$bf"
}

# The full profile is audited on two axes, matching lib.sh: the CLI set comes
# from the manifests (PROFILE), the GUI installs from gui_wanted. `full` runs
# v_full_cli and then EITHER v_gui or, with the `headless` add-on, v_no_gui.
v_full_cli() {
  hdr "verify: full-profile CLI set (the things .zshrc/.gitconfig guard on)"
  check "bat (brew)"               test -x /home/linuxbrew/.linuxbrew/bin/bat
  check "eza (brew)"               test -x /home/linuxbrew/.linuxbrew/bin/eza
  check "zoxide (brew)"            test -x /home/linuxbrew/.linuxbrew/bin/zoxide
  check "delta (brew)"             test -x /home/linuxbrew/.linuxbrew/bin/delta
  check "atuin (brew)"             test -x /home/linuxbrew/.linuxbrew/bin/atuin
}

v_gui() {  # GUI installs — present only when gui_wanted (full, not headless)
  hdr "verify: GUI installs (editors, terminals, font, flatpak)"
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
  check "kitty installed (upstream bundle)" test -x "$HOME/.local/kitty.app/bin/kitty"
  check "kitten installed"         test -x "$HOME/.local/kitty.app/bin/kitten"
  check "kitty on PATH via ~/.local/bin" test -L "$HOME/.local/bin/kitty"
  # A .desktop still saying `Exec=kitty` means the sed rewrite silently no-op'd
  # and the menu entry would launch apt's kitty (or nothing) instead of ours.
  check "kitty.desktop points at the installed build" \
    bash -c 'grep -q "^Exec=$HOME/.local/kitty.app/bin/kitty" "$HOME/.local/share/applications/kitty.desktop"'
  check "MesloLGS NF system-wide"  bash -c 'ls /usr/local/share/fonts/MesloLGS-NF/*.ttf'
  check "_alacritty completion world-readable" \
    bash -c '[ -r /usr/share/zsh/vendor-completions/_alacritty ]'
  check "flatpak + flathub"        bash -c 'flatpak remotes 2>/dev/null | grep -q flathub'
  # The notes must say the font IS installed — v_no_gui asserts the opposite.
  check "notes say the font is installed system-wide" \
    bash -c 'grep -q "installed system-wide" "$HOME/PROVISION-NEXT-STEPS.md"'
}

v_minimal_cli() {  # the lean box's whole claim is what it did NOT install
  hdr "verify: minimal profile CLI set (lean assertions)"
  checkno "bat ABSENT"             test -e /home/linuxbrew/.linuxbrew/bin/bat
  checkno "eza ABSENT"             test -e /home/linuxbrew/.linuxbrew/bin/eza
  checkno "zoxide ABSENT"          test -e /home/linuxbrew/.linuxbrew/bin/zoxide
  checkno "delta ABSENT"           test -e /home/linuxbrew/.linuxbrew/bin/delta
  checkno "atuin ABSENT"           test -e /home/linuxbrew/.linuxbrew/bin/atuin
  check  "shellcheck (brew, kept)" test -x /home/linuxbrew/.linuxbrew/bin/shellcheck
}

v_no_gui() {  # shared by `minimal` and `full headless`: every GUI install absent
  hdr "verify: no GUI installs (PROFILE=minimal or HEADLESS=1)"
  checkno "codium ABSENT"          dpkg-query -W codium
  checkno "cursor ABSENT"          dpkg-query -W cursor
  checkno "alacritty ABSENT"       test -e "$HOME/.cargo/bin/alacritty"
  checkno "kitty ABSENT"           test -e "$HOME/.local/kitty.app/bin/kitty"
  checkno "flatpak ABSENT"         command -v flatpak
  # The notes must not CLAIM the font is installed (step 36 was skipped), but
  # must explain the tofu you'd see in a terminal opened ON this box — and name
  # the flag that skipped it, which is the box's own record of how it was built.
  check   "notes carry the no-Nerd-Font note" \
    bash -c 'grep -q "No Nerd Font on this box" "$HOME/PROVISION-NEXT-STEPS.md"'
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
  # Found the hard way 2026-09-24: this audit skips v_core, so the terminfo
  # checks did not run on the ONE box shape most likely to be reached only over
  # ssh — and S10 passed 28/28 while the operator's session was answering
  # "unknown terminal type xterm-kitty" at every prompt.
  v_terminfo
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
  for b in mise eza bat zoxide jq; do
    check "$b (brew subset)"     bash -c "test -e /home/linuxbrew/.linuxbrew/bin/$b || /home/linuxbrew/.linuxbrew/bin/brew list --formula $b"
  done
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
  # .claude/settings.json is installed from the repo but OWNED by Claude Code
  # afterwards: it rewrites the file with runtime preferences (model,
  # notification flags, autocompact, an expanded $HOME), so it drifts by
  # design like .config/nvim — presence is asserted (v_core), content is not.
  # Found on the adopted Gen-3 clone, 2026-09-13.
  local f bad_n=0
  while IFS= read -r f; do
    [ -f "$HERE/$f" ] || continue          # skip dirs + entries missing from the repo
    [ "$f" = ".claude/settings.json" ] && { ok "dotfile $f — content owned by Claude Code after install, not compared"; continue; }
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
  # favorite-apps: GNOME silently drops any entry whose .desktop file is not
  # installed, so "the value landed" is not enough — each id must RESOLVE on
  # this box. The Gen-3 clone had the list applied and still no Alacritty in
  # the dock: the id was the old snap's (found live, 2026-09-12).
  check "dconf applied: favorite-apps set" \
    bash -c 'dconf read /org/gnome/shell/favorite-apps 2>/dev/null | grep -q "\.desktop"'
  local fav dir found
  for fav in $(dconf read /org/gnome/shell/favorite-apps 2>/dev/null | grep -oE "'[^']+'" | tr -d "'"); do
    found=0
    for dir in "$HOME/.local/share/applications" /usr/share/applications \
               /usr/local/share/applications /var/lib/snapd/desktop/applications \
               /var/lib/flatpak/exports/share/applications \
               "$HOME/.local/share/flatpak/exports/share/applications"; do
      [ -f "$dir/$fav" ] && { found=1; break; }
    done
    if [ "$found" = 1 ]; then ok "favorite resolves: $fav"
    else bad "favorite does NOT resolve (GNOME will silently drop it from the dock): $fav"; fi
  done
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
  hdr "verify: golden clone (a freshly booted clone — once adopted, audit with: verify copy full desktop)"
  check  "machine-id regenerated (non-empty)" test -s /etc/machine-id
  # Host keys only matter where sshd exists. finalize removes them
  # unconditionally; a desktop golden has no openssh-server (not in apt.list),
  # so "absent" is correct there — the Gen-3 clone showed exactly that.
  if dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep -q 'install ok installed'; then
    check "SSH host keys regenerated (sshd installed)" bash -c 'ls /etc/ssh/ssh_host_* >/dev/null 2>&1'
  else ok "SSH host keys — not applicable (openssh-server not installed)"; fi
  # The list is read from 90-finalize.sh's CRED_PATHS — the scrub's own source
  # of truth — so this audit can't drift from what finalize actually removes
  # (it used to be a hand-copied subset that had already fallen behind).
  local -a cred_paths=()
  eval "$(sed -n '/^CRED_PATHS=(/,/)/p' "$HERE/provision/steps/90-finalize.sh" \
          | sed 's/^CRED_PATHS=/cred_paths=/')"
  # A cred path that EXISTS on the clone is a leak only if it came from the
  # image. Some are legitimately created afterwards — gpg-agent's user units
  # make ~/.gnupg and atuin's init makes ~/.local/share/atuin at first login,
  # and the owner restores real creds by hand once the clone is adopted. The
  # birth time (statx, ext4) separates the cases, measured against the
  # clone's FIRST boot: finalize empties /etc/machine-id and systemd writes
  # the new id on first boot, so that file's mtime is the clone's birth and
  # survives later reboots. (The first draft compared against the CURRENT
  # boot — right on a fresh clone, wrong after the first reboot: every carried
  # cred read as "inherited". Found on the adopted Gen-3 clone, 2026-09-13.)
  # Unknown birth time is treated as a leak (conservative).
  if [ "${#cred_paths[@]}" -gt 0 ]; then
    local p born birth
    if [ -s /etc/machine-id ]; then birth="$(stat -c %Y /etc/machine-id)"
    else birth="$(awk '/^btime/{print $2}' /proc/stat)"; fi
    for p in "${cred_paths[@]}"; do
      if [ ! -e "$HOME/$p" ]; then ok "cred path ABSENT: ~/$p"; continue; fi
      born="$(stat -c %W "$HOME/$p" 2>/dev/null || echo 0)"
      if [ "${born:-0}" -gt "${birth:-0}" ] 2>/dev/null; then
        ok "cred path created on this clone (+$((born-birth))s after first boot, not inherited): ~/$p"
      else bad "cred path INHERITED from the image (born before this clone's first boot): ~/$p"; fi
    done
    # ~/.gnupg may be recreated, but it must never carry a private key.
    checkno "no private keys in ~/.gnupg" \
      bash -c 'find "$HOME/.gnupg" \( -path "*private-keys-v1.d/*.key" -o -name secring.gpg \) 2>/dev/null | grep -q .'
  else bad "could not read CRED_PATHS from 90-finalize.sh"; fi
  checkno "no private keys in ~/.ssh" \
    bash -c 'grep -rlI "PRIVATE KEY" "$HOME/.ssh" 2>/dev/null | grep -q .'
  checkno "no repo clone in /tmp" test -d /tmp/dotfiles
  # The image's own record vs the booted clone: zero drift proves the clone IS
  # what the build recorded, and that nothing upgraded brew/rustup behind our
  # backs between capture and audit. A FIRST-BOOT property: once the box is
  # adopted and upgraded, drift here is the owner's doing and expected — which
  # is why the header says to audit an adopted box with `copy full desktop`.
  # (A clone provisioned before step 85 existed has no lock — a skip, not a pass.)
  # --ignore-boot: the lock's `system/kernel` is the BUILD box's `uname -r`
  # (step 85 runs before any reboot), so a clone that boots a newer installed
  # kernel is correct, not drifted — without the flag this check passed on Gen-4
  # only BECAUSE the clone booted the stale kernel (2026-09-13). The kernel/
  # bootloader apt rows go with it: step 10 never installs them and
  # unattended-upgrades bumps them minutes after first boot. Everything
  # provisioning owns still counts.
  if [ -s "$HOME/versions.lock" ]; then
    check "no drift vs the image's own versions.lock (first-boot property; boot rows ignored)" \
      bash "$HERE/provision/versions-lock.sh" check "$HOME/versions.lock" --brief --ignore-boot
    local lk; lk="$(awk -F'\t' '$1=="system" && $2=="kernel"{print $3}' "$HOME/versions.lock")"
    printf '    running kernel %s; the lock recorded %s (the build box'"'"'s — informational)\n' "$(uname -r)" "${lk:-?}"
  else skip "drift vs ~/versions.lock (no lock on this clone — provisioned before step 85)"; fi
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
    else
      # Profile = which MANIFESTS landed (bat is in the full Brewfile only);
      # GUI = the box's own record in the step-80 notes, which name the flag
      # that skipped the font — falling back to the binaries if the notes were
      # tidied away (deleting them is the documented cleanup).
      local notes="$HOME/PROVISION-NEXT-STEPS.md"
      if grep -qs "(PROFILE=minimal skips it)" "$notes"; then args+=(minimal)
      elif grep -qs "(HEADLESS=1 skips it)" "$notes"; then args+=(full headless)
      elif dpkg-query -W codium >/dev/null 2>&1 || [ -x "$HOME/.cargo/bin/alacritty" ]; then args+=(full)
      elif [ -x /home/linuxbrew/.linuxbrew/bin/bat ]; then args+=(full headless)
      else args+=(minimal); fi
    fi
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
    # headless only means something against the FULL profile (minimal has no
    # GUI by definition): with minimal it is redundant, with no profile it
    # implies full.
    if _tok_has headless "${args[*]}"; then
      if _tok_has minimal "${args[*]}"; then
        echo "note: dropping redundant 'headless' — minimal already asserts no GUI"
        local kept2=(); for x in "${args[@]}"; do [ "$x" = headless ] || kept2+=("$x"); done
        args=("${kept2[@]}")
      elif ! _tok_has full "${args[*]}"; then
        echo "note: 'headless' implies the full profile — adding 'full'"
        args+=(full)
      fi
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
      full)         v_full_cli
                    if _tok_has headless "${args[*]}"; then v_no_gui; else v_gui; fi
                    v_brewfile Brewfile ;;
      headless)     ;;   # consumed by `full` above
      plain)        v_mode symlink ;;
      copy)         v_mode copy ;;
      minimal)      v_minimal_cli; v_no_gui; v_brewfile Brewfile.minimal ;;
      installsh)    v_installsh ;;
      desktop)      v_desktop ;;
      rootless)     v_rootless ;;
      golden-clone) v_mode copy; v_golden_clone ;;
      *) echo "unknown verify scenario: $a"; exit 2 ;;
    esac
  done
}
