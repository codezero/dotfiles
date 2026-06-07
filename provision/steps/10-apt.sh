#!/usr/bin/env bash
# Step 10 — base apt packages. apt.list is the full `apt-mark showmanual` export,
# so we filter out classes we must NOT auto-(re)install unattended:
#   - boot/firmware + kernel : would reconfigure the bootloader / rebuild initramfs
#   - third-party pkgs       : step 20 installs them after adding their repos
#                              (here they'd be unlocatable and abort the whole batch)
#   - desktop/locale/IME     : only with INSTALL_DESKTOP=1 (keeps servers desktop-free)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

INSTALL_DESKTOP="${INSTALL_DESKTOP:-0}"

# Always skip (boot/firmware, kernels, and third-party-repo packages).
is_denied() {
  case "$1" in
    efibootmgr|grub-*|shim-signed) return 0 ;;
    linux-generic*|linux-image-*|linux-headers-*|linux-modules-*|linux-*-hwe-*|linux-hwe-*) return 0 ;;
    docker-ce|docker-ce-cli|docker-ce-rootless-extras|docker-buildx-plugin|docker-compose-plugin|containerd.io|uidmap) return 0 ;;
    codium|cursor) return 0 ;;
    bruno) return 0 ;;   # removed from the project; still skip if a re-export re-adds it
    flatpak|gnome-software-plugin-flatpak) return 0 ;;   # owned by step 50 (CLI flatpak)
  esac
  return 1
}

# Desktop / localization / input-method packages (only with INSTALL_DESKTOP=1).
is_desktop() {
  case "$1" in
    ubuntu-desktop|ubuntu-desktop-minimal|ubuntu-standard|ubuntu-minimal|ubuntu-restricted-addons) return 0 ;;
    language-pack-*|libreoffice-*|hyphen-*|mythes-*|ibus-*|libchewing*|libpinyin*) return 0 ;;
    libm17n*|m17n-db|libmarisa*|libopencc*|libotf1|thunderbird-locale-*|ubuntu-wallpapers) return 0 ;;
  esac
  return 1
}

log "apt update"
# soft_fail (not bare warn): a stale index would install wrong/old packages, so
# under STRICT/golden this aborts; a normal run records it and continues.
apt_get update || soft_fail "apt-get update failed"

# Optional whole-system package refresh (APT_UPGRADE=1, OFF by default). A blanket
# upgrade also bumps the installed kernel/grub/shim point-releases this step
# otherwise avoids touching (initramfs rebuild + a reboot-required flag that
# provision.sh never acts on), so it is opt-in. `upgrade` (never `full-upgrade`)
# so NO brand-new kernel packages are pulled; the noninteractive/needrestart
# wrapper keeps it prompt-free. Convergent → idempotent (a no-op once current).
# A reboot may be wanted afterward on a live box; a golden clone reboots anyway.
if [ "${APT_UPGRADE:-0}" = "1" ]; then
  log "apt upgrade (APT_UPGRADE=1)"
  apt_get upgrade -y || soft_fail "apt-get upgrade failed"
fi

# Pre-accept the msttcorefonts EULA (harmless if the package isn't pulled in).
if ! dry; then
  echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" \
    | $SUDO debconf-set-selections 2>/dev/null || true
fi

# Build the filtered install list. PROFILE=minimal swaps in the hand-curated
# lean list (the deny/desktop filters below still apply, harmlessly).
APT_LIST="$PKG_DIR/apt.list"
minimal && { APT_LIST="$PKG_DIR/apt.minimal.list"; log "PROFILE=minimal — using $(basename "$APT_LIST")"; }
mapfile -t raw < <(grep -vE '^[[:space:]]*(#|$)' "$APT_LIST")
pkgs=(); skipped=()
for p in "${raw[@]}"; do
  p="${p//[[:space:]]/}"            # package names carry no spaces; drop stray whitespace
  [ -z "$p" ] && continue
  if is_denied "$p"; then skipped+=("$p"); continue; fi
  if is_desktop "$p" && [ "$INSTALL_DESKTOP" != "1" ]; then skipped+=("${p}[desktop]"); continue; fi
  pkgs+=("$p")
done
[ "${#skipped[@]}" -gt 0 ] && log "skipped (boot/kernel/third-party/desktop): ${skipped[*]}"

# Install the batch; if it fails, fall back to one-by-one so a single bad
# package can't take the rest down.
if [ "${#pkgs[@]}" -gt 0 ]; then
  if ! apt_get install -y "${pkgs[@]}"; then
    warn "batch install failed — retrying packages individually"
    for p in "${pkgs[@]}"; do apt_get install -y "$p" || soft_fail "apt: could not install $p"; done
  fi
fi

# libfuse2 became libfuse2t64 on 26.04; ensure at least one is present.
dpkg -s libfuse2t64 >/dev/null 2>&1 || apt_install libfuse2 || true
