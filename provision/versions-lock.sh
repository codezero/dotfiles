#!/usr/bin/env bash
# ============================================================================
# versions-lock.sh — RECORD installed versions (apt: only the packages this
# repo names; brew, cask, flatpak, mise: everything those tools installed,
# dependencies included), and REPORT
# drift against a previous record. Never installs, never downgrades.
#
#   bash versions-lock.sh emit [-o FILE]      write the lock (stdout by default)
#   bash versions-lock.sh check LOCK [--brief] [--ignore-boot]
#                                     compare this box to LOCK: exit 0 = no
#                                     drift, 1 = drift, 2 = error. --ignore-boot
#                                     leaves out the running kernel and the
#                                     kernel/bootloader packages (boot-pkgs.sh)
#
# Why a record and not a pin: every install source here floats by design
# (brew, rustup, mise, Claude, kitty, flatpak, three git clones at HEAD), and
# Homebrew — the largest group — cannot be version-pinned at all. So the honest
# reproducibility claim for a golden is "SHA X built on DATE produced THESE
# versions": deterministic inputs (manifests, steps, key pins) plus a recorded
# manifest of outputs. This file is that manifest. Step 85 writes it to
# ~/versions.lock on every run (and prints what moved since the last one);
# provision/versions.lock in the repo is the latest golden's copy.
#
# Distinct from packages/: those manifests are the repo's INPUTS (which package
# names to install, curated by hand). This records a box's OUTPUTS -- what those
# inputs actually produced -- and runs on any provisioned box or clone. Same
# rule either way: names and versions only, no hostnames, usernames, paths or
# tokens.
#
# Format: sorted TSV, one line per item — `kind<TAB>name<TAB>version` — under
# a `#` header. Line-oriented so `diff`/`comm` work and no parser is needed.
# A kind whose tool is absent is simply omitted (valid on a minimal box, a
# headless box, a bare CI runner).
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$HERE/packages"

usage() { sed -n '5,11p' "$0" >&2; exit 2; }
# shellcheck source=boot-pkgs.sh
source "$HERE/boot-pkgs.sh"   # is_boot_pkg — the same list step 10 refuses to install

# ── emit ────────────────────────────────────────────────────────────────────
# Each source is a function that prints `kind<TAB>name<TAB>version` lines, or
# nothing when its tool is absent. Versions are trimmed to the bare version
# token where a tool prints prose (rustc, cargo, kitty, claude).

src_system() {
  local id ver
  # shellcheck disable=SC1091
  [ -r /etc/os-release ] && { . /etc/os-release; id="${ID:-}"; ver="${VERSION_ID:-}"; }
  [ -n "${id:-}" ] && printf 'system\t%s\t%s\n' "$id" "$ver"
  printf 'system\tkernel\t%s\n' "$(uname -r)"
  printf 'system\tarch\t%s\n' "$(uname -m)"
}

# The step-20 third-party debs — from their own repos, so they float
# independently of the Ubuntu release. dpkg only: NEVER Electron --version
# (codium/cursor hang headless). Owned by the `deb` kind; excluded from `apt`
# even though apt.list (an apt-mark export) names them too — one line each.
DEB_PKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin
docker-compose-plugin docker-ce-rootless-extras codium cursor"

# apt + deb rows from ONE `dpkg-query -W` — one read of the dpkg database, so
# the two kinds always describe the same moment (round-4 review: two reads could
# straddle a package change and produce a lock that never existed). One call
# also means one exit status: if dpkg cannot be read, that is an error (exit 2),
# never "not installed". ${db:Status-Status} is only the installed state, so held
# and reinstreq packages that ARE installed count.
#   apt rows: the packages the apt manifests NAME (minus the vendor debs).
#   deb rows: the step-20 vendor packages in DEB_PKGS.
src_dpkg() {
  command -v dpkg-query >/dev/null 2>&1 || return 0
  local all names
  all="$(dpkg-query -W -f='${Package}\t${db:Status-Status}\t${Version}\n' 2>/dev/null)" \
    || { echo "dpkg-query failed — refusing to record a lock with packages missing from it" >&2; return 2; }
  names="$(cat "$PKG_DIR/apt.list" "$PKG_DIR/apt.minimal.list" 2>/dev/null \
           | sed 's/#.*//; s/[[:space:]]//g' | grep -v '^$' | tr '\n' ' ')"
  awk -F'\t' -v apt="$names" -v deb="$DEB_PKGS" '
    BEGIN { n = split(deb, d, /[ \n]+/); for (i = 1; i <= n; i++) if (d[i] != "") D[d[i]] = 1
            n = split(apt, a, /[ \n]+/); for (i = 1; i <= n; i++) if (a[i] != "" && !(a[i] in D)) A[a[i]] = 1 }
    $2 == "installed" && ($1 in D) { print "deb\t" $1 "\t" $3; next }
    $2 == "installed" && ($1 in A) { print "apt\t" $1 "\t" $3 }' <<<"$all"
}

_brew() { /home/linuxbrew/.linuxbrew/bin/brew "$@"; }
src_brew() {
  [ -x /home/linuxbrew/.linuxbrew/bin/brew ] || return 0
  # `brew list --versions` prints "name v1 v2" when several versions are kept;
  # the LAST is the active one.
  HOMEBREW_NO_AUTO_UPDATE=1 _brew list --formula --versions 2>/dev/null \
    | awk '{print "brew\t"$1"\t"$NF}'
  HOMEBREW_NO_AUTO_UPDATE=1 _brew list --cask --versions 2>/dev/null \
    | awk '{print "cask\t"$1"\t"$NF}'
}

src_flatpak() {
  command -v flatpak >/dev/null 2>&1 || return 0
  flatpak list --app --columns=application,version 2>/dev/null \
    | awk -F'\t' 'NF>=1 {v=($2==""?"-":$2); print "flatpak\t"$1"\t"v}'
}

src_rustup() {
  [ -x "$HOME/.cargo/bin/rustup" ] || return 0
  local tc
  tc="$("$HOME/.cargo/bin/rustup" show active-toolchain 2>/dev/null | awk 'NR==1{print $1}')"
  [ -n "$tc" ] && printf 'rustup\ttoolchain\t%s\n' "$tc"
  printf 'rustup\trustc\t%s\n' "$("$HOME/.cargo/bin/rustc" --version 2>/dev/null | awk '{print $2}')"
  printf 'rustup\tcargo\t%s\n' "$("$HOME/.cargo/bin/cargo" --version 2>/dev/null | awk '{print $2}')"
}

src_cargo() {  # step 36's build
  [ -x "$HOME/.cargo/bin/alacritty" ] || return 0
  printf 'cargo\talacritty\t%s\n' "$("$HOME/.cargo/bin/alacritty" --version 2>/dev/null | awk '{print $2}')"
}

src_claude() {
  local bin; bin="$(command -v claude 2>/dev/null || true)"
  [ -n "$bin" ] || bin="$HOME/.local/bin/claude"
  [ -x "$bin" ] || return 0
  printf 'claude\tclaude\t%s\n' "$(timeout 15 "$bin" --version 2>/dev/null | awk '{print $1}')"
}

src_kitty() {  # step 38's bundle
  [ -x "$HOME/.local/kitty.app/bin/kitty" ] || return 0
  printf 'kitty\tkitty\t%s\n' "$("$HOME/.local/kitty.app/bin/kitty" --version 2>/dev/null | awk '{print $2}')"
}

src_mise() {
  local bin; bin="$(command -v mise 2>/dev/null || true)"
  [ -n "$bin" ] || bin="/home/linuxbrew/.linuxbrew/bin/mise"
  [ -x "$bin" ] || return 0
  # Columns: Tool Version [Source Requested]. Header line filtered by name.
  "$bin" ls --installed 2>/dev/null | awk '$1!="Tool" && NF>=2 {print "mise\t"$1"\t"$2}'
}

# The three pinned clones (pins.sh, TODO J). Recording the SHA that actually
# sits on the box makes a bump — or an `omz update` by hand — show as drift.
src_git() {
  local name dir
  while IFS=$'\t' read -r name dir; do
    [ -d "$dir/.git" ] || continue
    printf 'git\t%s\t%s\n' "$name" "$(git -C "$dir" rev-parse --short=12 HEAD 2>/dev/null)"
  done <<EOF
oh-my-zsh	$HOME/.oh-my-zsh
powerlevel10k	${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k
alacritty-theme	$HOME/.config/alacritty/themes
EOF
}

emit_header() {
  # PROVISION_REPO_SHA is resolved by step 85 as ROOT and handed down, because
  # this runs as the TARGET USER and git refuses to parse a repo owned by
  # someone else (safe.directory). On the cloud-init path the repo is cloned by
  # root into /opt/dotfiles, so the user's own probe below returns nothing and
  # the lock silently lost its provenance — found live on an AWS cloud-init box
  # (TODO K, 2026-09-24). Never omit the field: "unknown" distinguishes "not
  # resolvable here" from "nobody even tried".
  local sha="${PROVISION_REPO_SHA:-}" dirty=""
  if [ -z "$sha" ] && git -C "$HERE" rev-parse --short=7 HEAD >/dev/null 2>&1; then
    sha="$(git -C "$HERE" rev-parse --short=7 HEAD)"
    git -C "$HERE" diff --quiet HEAD -- 2>/dev/null || dirty=" (dirty)"
  fi
  [ -n "$sha" ] || sha="unknown"
  printf '# versions.lock — installed versions (apt: the packages this repo names; brew/cask/flatpak/mise: all they installed). Generated by provision/versions-lock.sh; read by `check`.\n'
  printf '# generated: %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '   repo: %s%s' "$sha" "$dirty"
  # Flags only when running INSIDE a provision run (env set by provision.sh);
  # post-hoc on a clone they are omitted rather than guessed.
  if [ -n "${PROVISION_FLAGS:-}" ]; then printf '   flags: %s' "$PROVISION_FLAGS"; fi
  printf '\n'
}

emit_body() {
  # `|| exit 2` on the dpkg source: a command group's status is its LAST
  # command's, so without it a dpkg failure was lost the moment src_brew ran —
  # and emit wrote a lock with no apt rows (round-3 review).
  # Other sources return 0 when their tool is absent; only dpkg is authoritative.
  { src_system; src_dpkg || exit 2; src_brew; src_flatpak; src_rustup
    src_cargo; src_claude; src_kitty; src_mise; src_git; } \
    | awk -F'\t' 'NF==3 && $3!="" {print}' | LC_ALL=C sort -u
}

cmd_emit() {
  local out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) out="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [ -n "$out" ]; then
    # Write beside the target and rename only on success: a failed emit leaves
    # the previous lock untouched instead of an empty or half-written one, and
    # a rename replaces a planted symlink rather than following it.
    local tmp="$out.tmp.$$"
    if ! { emit_header; emit_body; } > "$tmp"; then
      rm -f -- "$tmp"; echo "emit failed — $out left unchanged" >&2; exit 2
    fi
    # -T: rename onto exactly $out. Without it GNU mv treats a symlink-to-dir
    # (or a real directory) at $out as a DIRECTORY and drops the file inside it,
    # while emit still reported success (round-4 review). With -T a planted
    # symlink is replaced, and a real directory makes mv fail.
    mv -fT -- "$tmp" "$out" 2>/dev/null || { rm -f -- "$tmp"; echo "could not write $out" >&2; exit 2; }
    [ -f "$out" ] && [ ! -L "$out" ] || { echo "could not write $out as a regular file" >&2; exit 2; }
    echo "wrote $out ($(grep -vc '^#' "$out") entries)"
  else
    emit_header; emit_body || exit 2
  fi
}

# ── check ───────────────────────────────────────────────────────────────────
# Row filters for --ignore-boot (TSV on stdin): a boot row is `system/kernel`
# or an `apt` row whose name is_boot_pkg.
_is_boot_row() { { [ "$1" = system ] && [ "$2" = kernel ]; } || { [ "$1" = apt ] && is_boot_pkg "$2"; }; }
_boot_rows()      { local k n v; while IFS=$'\t' read -r k n v; do _is_boot_row "$k" "$n" && printf '%s\t%s\t%s\n' "$k" "$n" "$v"; done; true; }
_drop_boot_rows() { local k n v; while IFS=$'\t' read -r k n v; do _is_boot_row "$k" "$n" || printf '%s\t%s\t%s\n' "$k" "$n" "$v"; done; true; }
# --ignore-boot: `system/kernel` is `uname -r` at emit time — for a lock
# written INSIDE a golden build that is the build box's kernel, and a clone
# that boots a newer installed one is correct, not drifted. Likewise the
# kernel/bootloader packages apt.list names: step 10 never installs them, and
# unattended-upgrades bumps them minutes after a fresh boot. A first-boot audit
# wants provisioning's drift, not Ubuntu's — everything else still counts.
cmd_check() {
  local lock="" brief=0 ignore_boot=0
  # Options and the lock path in any order — `check --brief LOCK` and
  # `check LOCK --brief` both work (the first draft took $1 as the path
  # unconditionally, so the former reported "no such lock: '--brief'").
  while [ $# -gt 0 ]; do
    case "$1" in
      --brief) brief=1 ;;
      --ignore-boot) ignore_boot=1 ;;
      -*) usage ;;
      *) [ -z "$lock" ] || usage; lock="$1" ;;
    esac; shift
  done
  [ -n "$lock" ] || usage
  [ -f "$lock" ] || { echo "no such lock: '$lock'" >&2; exit 2; }
  # Global, not local: the EXIT trap fires after the function's locals are gone
  # (and `set -u` would then abort the cleanup itself).
  CHECK_NOW="$(mktemp)"; trap 'rm -f "$CHECK_NOW"' EXIT
  local now="$CHECK_NOW"
  emit_body > "$now" || { echo "cannot read this box's versions — check aborted" >&2; exit 2; }
  # Compare by (kind, name). Both files are sorted TSV without headers here.
  local old; old="$(grep -v '^#' "$lock" | awk -F'\t' 'NF==3' | LC_ALL=C sort -u)"
  local nb=0
  if [ "$ignore_boot" = 1 ]; then
    local cur
    cur="$(_drop_boot_rows < "$now")"; printf '%s\n' "$cur" > "$now"
    old="$(_drop_boot_rows <<<"$old")"
    nb="$(grep -v '^#' "$lock" | awk -F'\t' 'NF==3' | LC_ALL=C sort -u | _boot_rows | grep -c .)"
  fi
  local added removed changed
  added="$(join -t $'\t' -v 2 -j1 <(printf '%s\n' "$old" | awk -F'\t' '{print $1"/"$2"\t"$3}' | LC_ALL=C sort) \
                              <(awk -F'\t' '{print $1"/"$2"\t"$3}' "$now" | LC_ALL=C sort))"
  removed="$(join -t $'\t' -v 1 -j1 <(printf '%s\n' "$old" | awk -F'\t' '{print $1"/"$2"\t"$3}' | LC_ALL=C sort) \
                                <(awk -F'\t' '{print $1"/"$2"\t"$3}' "$now" | LC_ALL=C sort))"
  changed="$(join -t $'\t' -j1 <(printf '%s\n' "$old" | awk -F'\t' '{print $1"/"$2"\t"$3}' | LC_ALL=C sort) \
                            <(awk -F'\t' '{print $1"/"$2"\t"$3}' "$now" | LC_ALL=C sort) \
             | awk -F'\t' '$2!=$3')"
  local na nr nc
  na="$(printf '%s' "$added"   | grep -c .)"; nr="$(printf '%s' "$removed" | grep -c .)"
  nc="$(printf '%s' "$changed" | grep -c .)"
  local ign=""; [ "$ignore_boot" = 1 ] && ign=" ($nb boot rows ignored)"
  if [ "$na" = 0 ] && [ "$nr" = 0 ] && [ "$nc" = 0 ]; then
    echo "no drift vs $lock ($(grep -vc '^#' "$lock") entries)$ign"; return 0
  fi
  echo "drift vs $lock: $nc changed, $na added, $nr removed$ign"
  if [ "$brief" = 0 ]; then
    [ -n "$changed" ] && printf '%s\n' "$changed" | awk -F'\t' '{printf "  changed  %-32s %s -> %s\n", $1, $2, $3}'
    [ -n "$added"   ] && printf '%s\n' "$added"   | awk -F'\t' '{printf "  added    %-32s %s\n", $1, $2}'
    [ -n "$removed" ] && printf '%s\n' "$removed" | awk -F'\t' '{printf "  removed  %-32s (was %s)\n", $1, $2}'
  fi
  return 1
}

case "${1:-}" in
  emit)  shift; cmd_emit "$@" ;;
  check) shift; cmd_check "$@" ;;
  *)     usage ;;
esac
