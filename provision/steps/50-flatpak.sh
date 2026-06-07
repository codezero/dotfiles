#!/usr/bin/env bash
# Step 50 — Flatpak + Flathub remote, then any listed apps.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# Flatpaks here are GUI apps — nothing for a headless agent box.
minimal && { log "flatpak: skipped (PROFILE=minimal)"; exit 0; }

log "Ensuring Flatpak + Flathub remote"
apt_install flatpak
# gnome-software-plugin-flatpak is GUI-only (shows flatpaks in the Software app)
# and its configure can stall on a live desktop session (AppStream rebuild). We
# install flatpaks via the CLI below, so it's only needed for a desktop image.
[ "${INSTALL_DESKTOP:-0}" = "1" ] && apt_install gnome-software-plugin-flatpak
if dry; then
  would "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"
else
  $SUDO flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo || soft_fail "could not add flathub remote"
fi

# Install any apps listed (none by default).
while read -r app || [ -n "${app:-}" ]; do
  case "${app:-}" in ""|\#*) continue ;; esac
  if dry; then would "flatpak install flathub $app"; continue; fi
  $SUDO flatpak install -y --noninteractive flathub "$app" \
    || soft_fail "flatpak: failed to install '$app'"
done < "$PKG_DIR/flatpak.list"
