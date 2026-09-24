#!/usr/bin/env bash
# ============================================================================
# boot-pkgs.sh — the ONE definition of "a boot/firmware/kernel package": the
# apt packages this repo NAMES (apt.list keeps the shape of an `apt-mark
# showmanual` dump) but NEVER installs or upgrades by name, because Ubuntu's own updater
# owns them — installing one unattended reconfigures the bootloader / rebuilds
# the initramfs, and unattended-upgrades pulls new kernel ABIs on its own
# schedule (typically minutes after a fresh image's first boot).
#
# Sourced by lib.sh (step 10's is_denied skips these) AND versions-lock.sh
# (`check --ignore-boot` leaves them out of the first-boot zero-drift audit:
# a clone that boots a newer installed kernel than the build box ran is
# CORRECT, not drift — found on Gen-4, 2026-09-13). One owner so the two
# can't disagree about which packages "Ubuntu's updater owns".
# ============================================================================

# is_boot_pkg NAME — true for a kernel / bootloader / firmware package.
is_boot_pkg() {
  case "$1" in
    efibootmgr|grub-*|shim-signed) return 0 ;;
    linux-generic*|linux-image-*|linux-headers-*|linux-modules-*|linux-*-hwe-*|linux-hwe-*) return 0 ;;
  esac
  return 1
}
