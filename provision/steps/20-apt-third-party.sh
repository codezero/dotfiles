#!/usr/bin/env bash
# Step 20 — third-party repos & apps: Docker, VSCodium, Cursor.
# All official sources, verified 2026-05-24. Each block is failure-tolerant.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
run $SUDO install -m 0755 -d /etc/apt/keyrings
apt_get update || true   # ensure apt lists exist if this step is run standalone
apt_install ca-certificates curl gnupg wget

# Expected repo signing-key fingerprints — the repo add is gated on a match.
# Docker, Cursor, and VSCodium are PINNED (each verified against its live key).
# A mismatch soft_fails + skips that vendor (never bricks); all are env-overridable.
DOCKER_FP="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
CURSOR_FP="380FF4BCDC34A4BD92A3565342A1772E62E492D6"
VSCODIUM_KEY_FP="${VSCODIUM_KEY_FP:-1302DE60231889FE1EBACADC54678CF75A278D9C}"

# ── Docker (official) ───────────────────────────────────────────────────────
log "Docker: repo + Engine"
# Remove distro/old Docker packages first — docker.io, the docker snap's deps,
# podman-docker, etc. conflict with Docker CE (per Docker's own install docs).
if dry; then
  would "remove conflicting Docker packages if present (docker.io, podman-docker, containerd, runc, …)"
else
  for p in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt_get remove -y "$p" >/dev/null 2>&1 || true
  done
fi
DOCK_CN="$CODENAME"
# Fall back to 'noble' ONLY when the repo is confirmed absent (HTTP 404). A
# network/TLS blip must not silently downgrade a supported release (26.04
# 'resolute' is published). Skip the probe entirely under --dry-run.
if dry; then
  would "probe Docker repo for '$CODENAME' (fall back to 'noble' only on HTTP 404)"
else
  dock_status="$(curl -sS -o /dev/null -w '%{http_code}' \
    "https://download.docker.com/linux/ubuntu/dists/${DOCK_CN}/Release" 2>/dev/null || true)"
  case "${dock_status:-000}" in
    200) : ;;
    404) warn "Docker has no '$CODENAME' repo; falling back to 'noble'"; DOCK_CN="noble" ;;
    *)   warn "Docker repo probe inconclusive (HTTP ${dock_status:-000}); keeping '$CODENAME'" ;;
  esac
fi
docker_ok=1
if dry; then
  would "download + fingerprint-verify ($DOCKER_FP) Docker key -> /etc/apt/keyrings/docker.asc"
  would "add repo: deb [arch=$ARCH] https://download.docker.com/linux/ubuntu $DOCK_CN stable"
else
  if $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
     && $SUDO chmod a+r /etc/apt/keyrings/docker.asc \
     && verify_keyring /etc/apt/keyrings/docker.asc "$DOCKER_FP"; then
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${DOCK_CN} stable" \
      | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  else
    docker_ok=0
    $SUDO rm -f /etc/apt/keyrings/docker.asc /etc/apt/sources.list.d/docker.list
    soft_fail "Docker key download/verify failed — skipping Docker repo + Engine"
  fi
fi
if [ "$docker_ok" = 1 ]; then
  apt_get update || soft_fail "apt-get update failed after adding a third-party repo"
  # uidmap + docker-ce-rootless-extras + dbus-user-session are the rootless
  # prerequisites (dbus-user-session is required for `systemctl --user`; step 25
  # wires it up when DOCKER_ROOTLESS=1).
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
              docker-compose-plugin docker-ce-rootless-extras uidmap dbus-user-session
fi

# ── VSCodium (official) ──────────────────────────────────────────────────────
log "VSCodium: repo + codium"
vscodium_ok=1
VSCODIUM_KR=/usr/share/keyrings/vscodium-archive-keyring.gpg
if dry; then
  would "download + verify VSCodium key -> $VSCODIUM_KR (pin: ${VSCODIUM_KEY_FP:-none})"
  would "add repo: deb [...] https://download.vscodium.com/debs vscodium main"
else
  if wget -qO - https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
       | gpg --dearmor 2>/dev/null | $SUDO dd of="$VSCODIUM_KR" status=none 2>/dev/null \
     && $SUDO chmod a+r "$VSCODIUM_KR" \
     && verify_keyring "$VSCODIUM_KR" "$VSCODIUM_KEY_FP"; then
    echo "deb [arch=amd64,arm64 signed-by=$VSCODIUM_KR] https://download.vscodium.com/debs vscodium main" \
      | $SUDO tee /etc/apt/sources.list.d/vscodium.list >/dev/null
  else
    vscodium_ok=0
    $SUDO rm -f "$VSCODIUM_KR" /etc/apt/sources.list.d/vscodium.list
    soft_fail "VSCodium key download/verify failed — skipping VSCodium"
  fi
fi
if [ "$vscodium_ok" = 1 ]; then
  apt_get update || soft_fail "apt-get update failed after adding a third-party repo"
  apt_install codium
fi

# ── Cursor (official SIGNED apt repo) ────────────────────────────────────────
# Cursor publishes a proper signed apt repo (amd64,arm64). Add it the same way
# its own .deb does (key at /usr/share/keyrings/anysphere.gpg + deb822 source) so
# 'cursor' installs + self-updates via apt with NO download-URL scraping. The
# suite is 'stable' (not Ubuntu-codename-specific), so this is version-agnostic.
log "Cursor: AI editor (signed apt repo)"
cursor_ok=1
CURSOR_KR=/usr/share/keyrings/anysphere.gpg
case "$ARCH" in
  amd64|arm64) : ;;
  *) cursor_ok=0; warn "Cursor: unsupported arch '$ARCH' — skipping" ;;
esac
if [ "$cursor_ok" = 1 ] && dry; then
  would "download + fingerprint-verify ($CURSOR_FP) Cursor key -> $CURSOR_KR"
  would "add repo: deb822 https://downloads.cursor.com/aptrepo stable main"
elif [ "$cursor_ok" = 1 ]; then
  if curl -fsSL https://downloads.cursor.com/keys/anysphere.asc \
       | gpg --dearmor 2>/dev/null | $SUDO tee "$CURSOR_KR" >/dev/null \
     && $SUDO chmod a+r "$CURSOR_KR" \
     && verify_keyring "$CURSOR_KR" "$CURSOR_FP"; then
    printf 'Types: deb\nURIs: https://downloads.cursor.com/aptrepo\nSuites: stable\nComponents: main\nArchitectures: amd64,arm64\nSigned-By: %s\n' \
      "$CURSOR_KR" | $SUDO tee /etc/apt/sources.list.d/cursor.sources >/dev/null
  else
    cursor_ok=0
    $SUDO rm -f "$CURSOR_KR" /etc/apt/sources.list.d/cursor.sources
    soft_fail "Cursor key download/verify failed — skipping Cursor"
  fi
fi
if [ "$cursor_ok" = 1 ]; then
  apt_get update || soft_fail "apt-get update failed after adding a third-party repo"
  apt_install cursor
fi
