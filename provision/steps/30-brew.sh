#!/usr/bin/env bash
# Step 30 — Homebrew (linuxbrew) + formulae. Runs as the target user (brew
# refuses to run as root).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

log "Homebrew + formulae as user '$TARGET_USER'"
apt_install build-essential procps curl file git

if dry; then
  n="$(grep -cE '^[[:space:]]*(brew|cask)[[:space:]]' "$PKG_DIR/Brewfile" 2>/dev/null || true)"
  n="${n:-0}"
  would "install Homebrew (if missing) as $TARGET_USER"
  would "brew bundle: $n formulae/casks from Brewfile (flatpak/npm/mas/vscode lines ignored)"
  as_user 'mkdir -p "$HOME/.nvm"'
else
  # Install Homebrew non-interactively if missing.
  as_user 'test -x /home/linuxbrew/.linuxbrew/bin/brew || \
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' \
    || soft_fail "Homebrew install step failed"

  # `brew bundle dump` also records flatpak/npm/mas/vscode entries. Keep only the
  # Homebrew-native ones (tap/brew/cask) so bundling can't (a) install flatpaks
  # before the Flathub remote exists (step 50) or (b) need Node for npm packages.
  # Casks ARE kept: Linux-capable casks (e.g. `codex`) install fine on linuxbrew;
  # any macOS-only cask just fails-soft. Flatpaks are handled by flatpak.list.
  FILTERED="$(mktemp /tmp/Brewfile.filtered.XXXXXX)"
  grep -E '^[[:space:]]*(tap|brew|cask)[[:space:]]' "$PKG_DIR/Brewfile" > "$FILTERED" 2>/dev/null || true
  chmod 0644 "$FILTERED" 2>/dev/null || true   # so the target user can read it

  as_user "eval \"\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)\"; \
           brew update --quiet || true; \
           brew bundle --file='$FILTERED'" \
    || soft_fail "brew bundle reported issues"

  rm -f "$FILTERED" 2>/dev/null || true

  # nvm needs its data dir (referenced by .zshrc).
  as_user 'mkdir -p "$HOME/.nvm"' || true
fi
