#!/usr/bin/env bash
# Step 20 — third-party repos & apps: Docker, VSCodium, Bruno, Cursor.
# All official sources, verified 2026-05-24. Each block is failure-tolerant.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
run $SUDO install -m 0755 -d /etc/apt/keyrings
apt_get update || true   # ensure apt lists exist if this step is run standalone
apt_install ca-certificates curl gnupg wget

# Expected repo signing-key fingerprints (the repo add is gated on a match).
# Docker's is stable + officially documented, so it's pinned. VSCodium/Bruno are
# NOT pinned by default: their fingerprints couldn't be authoritatively verified
# here and Bruno is known to rotate/expire its key (usebruno#3569), so a
# hardcoded pin would break installs. Set VSCODIUM_KEY_FP / BRUNO_KEY_FP to pin
# them once you've verified the value; unset = require a valid key but don't pin.
DOCKER_FP="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
VSCODIUM_KEY_FP="${VSCODIUM_KEY_FP:-}"
BRUNO_KEY_FP="${BRUNO_KEY_FP:-}"

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
  apt_get update || true
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
              docker-compose-plugin docker-ce-rootless-extras uidmap
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
  apt_get update || true
  apt_install codium
fi

# ── Bruno (official) — apt repo is amd64-only; arm64 uses GitHub .deb ─────────
log "Bruno: API client"
if [ "$ARCH" = "amd64" ]; then
  bruno_ok=1
  if dry; then
    would "add + verify Bruno key (pin: ${BRUNO_KEY_FP:-none}) + amd64 repo, then install bruno"
  else
    if curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x9FA6017ECABE0266" \
         | gpg --dearmor 2>/dev/null | $SUDO tee /etc/apt/keyrings/bruno.gpg >/dev/null \
       && verify_keyring /etc/apt/keyrings/bruno.gpg "$BRUNO_KEY_FP"; then
      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/bruno.gpg] http://debian.usebruno.com/ bruno stable" \
        | $SUDO tee /etc/apt/sources.list.d/bruno.list >/dev/null
      apt_get update || true
    else
      bruno_ok=0
      $SUDO rm -f /etc/apt/keyrings/bruno.gpg /etc/apt/sources.list.d/bruno.list
      soft_fail "Bruno key download/verify failed — skipping Bruno"
    fi
  fi
  if [ "$bruno_ok" = 1 ]; then apt_install bruno; fi
else
  if dry; then
    would "fetch latest Bruno arm64 .deb from GitHub releases and install"
  else
    warn "Bruno apt repo is amd64-only; fetching latest arm64 .deb from GitHub releases"
    url="$(curl -fsSL https://api.github.com/repos/usebruno/bruno/releases/latest \
          | grep -oE 'https://[^"]+[Aa]rm64[^"]*\.deb' | head -n1)"
    if [ -n "${url:-}" ]; then
      # mktemp (unpredictable, 0600) avoids a /tmp symlink/TOCTOU swap of the
      # .deb that apt then installs as root.
      deb="$(mktemp /tmp/bruno.XXXXXX.deb)"
      curl -fsSL "$url" -o "$deb" && apt_install "$deb"
      rm -f "$deb"
    else
      warn "Could not resolve a Bruno arm64 .deb — skipping."
    fi
  fi
fi

# ── Cursor (official download API → .deb; self-updates in-app) ───────────────
log "Cursor: AI editor"
case "$ARCH" in
  arm64) CPLAT="linux-arm64-deb" ;;
  amd64) CPLAT="linux-x64-deb" ;;
  *)     CPLAT="" ; warn "unsupported arch for Cursor: $ARCH" ;;
esac
if [ -n "$CPLAT" ]; then
  if dry; then
    would "fetch latest Cursor .deb ($CPLAT) from cursor.com API and install"
  else
    api_json="$(curl -fsSL "https://www.cursor.com/api/download?platform=${CPLAT}&releaseTrack=stable")"
    # Cursor's download URL has no reliable .deb suffix, so take the JSON
    # downloadUrl/url field (fallback: first https URL in the response).
    curl_url="$(printf '%s' "$api_json" | grep -oE '"(downloadUrl|url)"[[:space:]]*:[[:space:]]*"https://[^"]+"' | grep -oE 'https://[^"]+' | head -n1)"
    [ -n "$curl_url" ] || curl_url="$(printf '%s' "$api_json" | grep -oE 'https://[^"]+' | head -n1)"
    if [ -n "${curl_url:-}" ]; then
      # mktemp (unpredictable, 0600) avoids a /tmp symlink/TOCTOU swap of the
      # .deb that apt then installs as root.
      deb="$(mktemp /tmp/cursor.XXXXXX.deb)"
      curl -fsSL "$curl_url" -o "$deb" && apt_install "$deb"
      rm -f "$deb"
    else
      warn "Could not resolve Cursor .deb URL — skipping."
    fi
  fi
fi
