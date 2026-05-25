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

# Bus selection: reuse a LIVE session bus when one exists (a running GNOME
# session then picks the change up immediately); otherwise spin up a throwaway
# bus so the load still persists to the user's dconf db when provisioning
# headlessly (cloud-init / packer). Root reads the fragment; the user's db
# receives it. (`< "$FRAG"` is evaluated by the current shell, so repo perms for
# the target user don't matter.)
uid="$(id -u "$TARGET_USER" 2>/dev/null || true)"
runtime_bus="/run/user/${uid}/bus"

if dry; then
  would "(as $TARGET_USER) dconf load / < $FRAG   (live bus if present, else dbus-run-session)"
elif [ "$(id -un)" = "$TARGET_USER" ]; then
  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    dconf load / < "$FRAG" || soft_fail "dconf load failed"
  elif command -v dbus-run-session >/dev/null 2>&1; then
    dbus-run-session -- dconf load / < "$FRAG" || soft_fail "dconf load failed"
  else
    dconf load / < "$FRAG" || soft_fail "dconf load failed (no session bus)"
  fi
elif [ -n "$uid" ] && [ -S "$runtime_bus" ]; then
  sudo -u "$TARGET_USER" -H env "DBUS_SESSION_BUS_ADDRESS=unix:path=$runtime_bus" \
    dconf load / < "$FRAG" || soft_fail "dconf load failed"
elif command -v dbus-run-session >/dev/null 2>&1; then
  sudo -u "$TARGET_USER" -H dbus-run-session -- dconf load / < "$FRAG" || soft_fail "dconf load failed"
else
  sudo -u "$TARGET_USER" -H dconf load / < "$FRAG" || soft_fail "dconf load failed (no session bus)"
fi
