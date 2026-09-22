#!/usr/bin/env bash
# ============================================================================
# dotfiles-install.sh — install the dotfile set (dotfiles.list) into $HOME,
# AS THE USER WHO OWNS $HOME. The one implementation both entry points run:
#
#   install.sh            →  bash dotfiles-install.sh [--copy]
#   provision step 60     →  as_user "bash dotfiles-install.sh [--copy] --src REPO"
#
# WHY IT EXISTS (2026-09-22, external assessment, finding #1): step 60 used to
# do this as ROOT — mkdir/chown/mv/rm -rf/cp -a/ln straight into $TARGET_HOME.
# Root walking a path the user controls is a classic escalation: a user-made
# `~/.config -> /etc` symlink turns `chown user ~/.config` into `chown user
# /etc`, and cp/rm/mv follow the same link. Nothing here needs root — the repo
# is world-readable and $HOME is the user's — so it runs as the owner, and an
# owner cannot escalate against themselves. install.sh always did it this way;
# the two copies of the policy have been merged into this file.
#
# Policy (unchanged from the two originals):
#   - manifest entries may be files or whole dirs; unsafe entries are skipped
#   - identical content already in place → left alone (no backup churn)
#   - a DIFFERENT real file/dir → moved to <dest>.backup.<epoch>, once
#   - --copy: cp -a (self-contained; sticky — a later symlink run leaves copies)
#     default: ln -sfn (repo stays the source of truth)
# Extra guards: refuses uid 0, and refuses a destination whose parent path
# contains a symlink (that is the attack shape; also protects the user's own
# home from a stray link doing the wrong thing).
# ============================================================================
set -uo pipefail

usage() { echo "usage: bash dotfiles-install.sh [--copy] [--src REPO_DIR] [--dry-run]" >&2; exit 2; }
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COPY=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --copy) COPY=1 ;;
    --src) SRC="${2:-}"; shift ;;
    --dry-run|-n) DRY=1 ;;
    -h|--help) usage ;;
    *) echo "dotfiles-install: unknown argument '$1'" >&2; usage ;;
  esac; shift
done

if [ "$(id -u)" = 0 ]; then
  echo "dotfiles-install: refusing to run as root — run it as the user whose \$HOME this is (provision uses as_user)" >&2
  exit 2
fi
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || { echo "dotfiles-install: \$HOME is unset or missing" >&2; exit 2; }
[ -r "$SRC/dotfiles.list" ] || { echo "dotfiles-install: cannot read $SRC/dotfiles.list (is the repo readable by $(id -un)?)" >&2; exit 2; }

# True if src and dst already hold identical content (file OR whole dir tree).
unchanged() {
  if [ -d "$1" ]; then diff -rq "$1" "$2" >/dev/null 2>&1; else cmp -s "$1" "$2"; fi
}

# Every path component between $HOME and the entry must be a real directory —
# a symlink anywhere in the chain is refused, never followed.
parents_are_real() {  # <relative entry>
  local rel="$1" d
  rel="${rel%/*}"; [ "$rel" = "$1" ] && return 0     # top-level entry: no parents
  d="$HOME"
  local IFS='/'; local part
  for part in $rel; do
    d="$d/$part"
    [ -L "$d" ] && return 1
  done
  return 0
}

rc=0
while IFS= read -r f; do
  case "$f" in ""|/*|*..*) echo "    skip (unsafe dotfiles.list entry): $f"; continue ;; esac
  src="$SRC/$f"; dest="$HOME/$f"
  [ -e "$src" ] || { echo "    skip (missing in repo): $f"; continue; }
  if ! parents_are_real "$f"; then
    echo "    REFUSED $dest — a parent directory is a symlink (would not follow it)" >&2; rc=1; continue
  fi
  if [ "$DRY" = 1 ]; then
    if [ "$COPY" = 1 ]; then echo "    [would] copy $src -> $dest (self-contained)"
    else echo "    [would] symlink $dest -> $src"; fi
    continue
  fi
  mkdir -p "$(dirname "$dest")" || { echo "    FAILED mkdir for $dest" >&2; rc=1; continue; }
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    if unchanged "$src" "$dest"; then continue; fi
    mv "$dest" "$dest.backup.$(date +%s)" || { echo "    FAILED to back up $dest" >&2; rc=1; continue; }
    echo "    backed up existing $dest"
  fi
  if [ "$COPY" = 1 ]; then
    rm -rf "$dest"
    if cp -a "$src" "$dest"; then echo "    copied  $dest <- $src"
    else echo "    FAILED copy $src -> $dest" >&2; rc=1; fi
  else
    if ln -sfn "$src" "$dest"; then echo "    linked  $dest -> $src"
    else echo "    FAILED symlink $dest -> $src" >&2; rc=1; fi
  fi
done < <(grep -vE '^[[:space:]]*(#|$)' "$SRC/dotfiles.list")
exit $rc
