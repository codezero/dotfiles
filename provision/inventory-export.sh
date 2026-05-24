#!/usr/bin/env bash
# ============================================================================
# Run this ON THE SOURCE MACHINE to capture EXACT package lists into packages/.
# This is the authoritative way to refresh the lists — the committed defaults
# were seeded by inspecting on-disk state and may not be 100% exhaustive.
#
#   bash inventory-export.sh
#
# Writes package NAMES only — no usernames, hostnames, tokens, or other PII.
# Review the diffs before committing.
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/packages"
mkdir -p "$OUT"

echo "==> apt: manually-installed packages (minus the base-image set)"
if command -v apt-mark >/dev/null 2>&1; then
  base="$(mktemp)"
  # Packages present in the original installer image = baseline to subtract.
  gzip -dc /var/log/installer/initial-status.gz 2>/dev/null \
    | sed -n 's/^Package: //p' | sort -u > "$base" || true
  if [ -s "$base" ]; then
    comm -23 <(apt-mark showmanual | sort -u) "$base" > "$OUT/apt.list"
  else
    apt-mark showmanual | sort -u > "$OUT/apt.list"
  fi
  rm -f "$base"
  echo "    -> $OUT/apt.list  ($(wc -l < "$OUT/apt.list") packages)"
else
  echo "    apt-mark not found; skipping"
fi

# NOTE: snaps are intentionally NOT exported. This machine is provisioned without
# snap (Alacritty — the only user snap — is built via cargo in step 36). If you
# ever reintroduce snaps, re-add a `snap list` export here and a snap step.

echo "==> flatpak: installed apps"
if command -v flatpak >/dev/null 2>&1; then
  flatpak list --app --columns=application 2>/dev/null > "$OUT/flatpak.list"
  echo "    -> $OUT/flatpak.list"
fi

echo "==> brew: Brewfile (formulae/casks/taps)"
BREW_BIN=""
command -v brew >/dev/null 2>&1 && BREW_BIN="brew"
[ -z "$BREW_BIN" ] && [ -x /home/linuxbrew/.linuxbrew/bin/brew ] && BREW_BIN=/home/linuxbrew/.linuxbrew/bin/brew
if [ -n "$BREW_BIN" ]; then
  "$BREW_BIN" bundle dump --force --file="$OUT/Brewfile"

  # `brew bundle dump` also emits flatpak/npm/mas/vscode entries. Keep the
  # Brewfile to Homebrew only: move flatpaks into flatpak.list, drop the rest.
  if grep -qE '^[[:space:]]*flatpak[[:space:]]' "$OUT/Brewfile"; then
    grep -oE '^[[:space:]]*flatpak[[:space:]]+"[^"]+"' "$OUT/Brewfile" \
      | grep -oE '"[^"]+"' | tr -d '"' >> "$OUT/flatpak.list"
    sort -u -o "$OUT/flatpak.list" "$OUT/flatpak.list"
    echo "    moved flatpak entries from Brewfile -> flatpak.list"
  fi
  sed -i -E '/^[[:space:]]*(flatpak|npm|mas|vscode)[[:space:]]/d' "$OUT/Brewfile"
  grep -qE '^[[:space:]]*cask[[:space:]]' "$OUT/Brewfile" && \
    echo "    note: Brewfile has cask entries — kept (Linux-capable casks like codex install on linuxbrew; macOS-only ones fail-soft)."
  echo "    -> $OUT/Brewfile (Homebrew-only)"
else
  echo "    brew not found; skipping"
fi

echo
echo "Done. Review packages/ then commit."
