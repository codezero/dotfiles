#!/usr/bin/env bash
# Step 50 — Flatpak + Flathub remote, then any listed apps.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

log "Ensuring Flatpak + Flathub remote"
apt_install flatpak gnome-software-plugin-flatpak
if dry; then
  would "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"
else
  $SUDO flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo || warn "could not add flathub remote"
fi

# Install any apps listed (none by default).
while read -r app || [ -n "${app:-}" ]; do
  case "${app:-}" in ""|\#*) continue ;; esac
  if dry; then would "flatpak install flathub $app"; continue; fi
  $SUDO flatpak install -y --noninteractive flathub "$app" \
    || warn "flatpak: failed to install '$app'"
done < "$PKG_DIR/flatpak.list"
