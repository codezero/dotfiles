#!/usr/bin/env bash
# Step 55 — GNOME desktop settings via dconf (only when INSTALL_DESKTOP=1).
# Loads a curated, machine-agnostic settings fragment. Runs as the target user;
# uses dbus-run-session so it persists even when provisioning headlessly
# (cloud-init / packer), where no login session bus exists yet.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

[ "${INSTALL_DESKTOP:-0}" = "1" ] || { log "GNOME dconf: skipped (INSTALL_DESKTOP != 1)"; exit 0; }

FRAG="$PROVISION_DIR/gnome/dconf-settings.ini"
[ -f "$FRAG" ] || { warn "missing $FRAG — skipping"; exit 0; }

log "GNOME dconf settings for '$TARGET_USER'"
command -v dconf >/dev/null 2>&1 || apt_install dconf-cli

# Prefer a throwaway session bus so dconf can persist without a live login.
LOADER="dconf load /"
command -v dbus-run-session >/dev/null 2>&1 && LOADER="dbus-run-session -- dconf load /"

if dry; then
  would "(as $TARGET_USER) $LOADER < $FRAG"
elif [ "$(id -un)" = "$TARGET_USER" ]; then
  # shellcheck disable=SC2086  # LOADER is an intentional multi-word command
  $LOADER < "$FRAG" || warn "dconf load failed (need a desktop/session bus?)"
else
  # Root reads the fragment; the user's dconf db receives it via the session bus.
  # shellcheck disable=SC2086
  sudo -u "$TARGET_USER" -H $LOADER < "$FRAG" || warn "dconf load failed (need a desktop/session bus?)"
fi
