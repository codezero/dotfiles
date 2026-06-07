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

# Third-party index refresh, resilient by design. Refreshes ONLY the given
# vendor's source file (Dir::Etc::sourcelist + List-Cleanup=0), so base/security
# repos are untouched here BY CONSTRUCTION — their freshness and STRICT
# semantics stay step 10's, and we stop re-fetching the whole Ubuntu index once
# per vendor. Retries cover transient CDN flakiness; a PERSISTENT failure (e.g.
# Cursor's recurring InRelease/Packages publish race, hit 2026-05-29) is a WARN,
# not a soft_fail — even under STRICT/golden: apt keeps any previously-fetched
# index ("old ones used instead"), so on a re-run / iterate-on-golden the
# install still works from the old index. On a FIRST run there is no old index,
# so the apt_install right after fails → soft_fail → STRICT still aborts — i.e.
# a golden aborts on actual underdelivery (package missing), no longer on a
# mere index hiccup.
vendor_apt_update() {
  local src="$1" name="$2" try
  if dry; then
    would "apt-get update (ONLY $src; 3 tries w/ backoff; persistent failure warns, never aborts)"
    return 0
  fi
  for try in 1 2 3; do
    apt_get update \
      -o Dir::Etc::sourcelist="$src" \
      -o Dir::Etc::sourceparts=/dev/null \
      -o APT::Get::List-Cleanup=0 && return 0
    if [ "$try" -lt 3 ]; then
      warn "$name index refresh failed (try $try/3) — retrying in $((try * 10))s"
      sleep $((try * 10))
    fi
  done
  warn "$name index refresh still failing after 3 tries — continuing with any previously-fetched index ('old ones used instead'); the install below is the real gate"
  return 0
}

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
  vendor_apt_update /etc/apt/sources.list.d/docker.list "Docker"
  # uidmap + docker-ce-rootless-extras + dbus-user-session are the rootless
  # prerequisites (dbus-user-session is required for `systemctl --user`; step 25
  # wires it up when DOCKER_ROOTLESS=1).
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
              docker-compose-plugin docker-ce-rootless-extras uidmap dbus-user-session
fi

# ── VSCodium (official) ──────────────────────────────────────────────────────
log "VSCodium: repo + codium"
vscodium_ok=1
# GUI editor — skipped on a headless agent box (Docker above is kept).
minimal && { vscodium_ok=0; log "VSCodium: skipped (PROFILE=minimal)"; }
VSCODIUM_KR=/usr/share/keyrings/vscodium-archive-keyring.gpg
if [ "$vscodium_ok" = 0 ]; then
  :
elif dry; then
  would "download + verify VSCodium key -> $VSCODIUM_KR (pin: ${VSCODIUM_KEY_FP:-none})"
  would "add repo: deb [...] https://download.vscodium.com/debs vscodium main"
else
  if wget -qO - https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
       | gpg --dearmor 2>/dev/null | $SUDO dd of="$VSCODIUM_KR" status=none 2>/dev/null \
     && $SUDO chmod a+r "$VSCODIUM_KR" \
     && verify_keyring "$VSCODIUM_KR" "$VSCODIUM_KEY_FP"; then
    echo "deb [arch=${ARCH} signed-by=$VSCODIUM_KR] https://download.vscodium.com/debs vscodium main" \
      | $SUDO tee /etc/apt/sources.list.d/vscodium.list >/dev/null
  else
    vscodium_ok=0
    $SUDO rm -f "$VSCODIUM_KR" /etc/apt/sources.list.d/vscodium.list
    soft_fail "VSCodium key download/verify failed — skipping VSCodium"
  fi
fi
if [ "$vscodium_ok" = 1 ]; then
  vendor_apt_update /etc/apt/sources.list.d/vscodium.list "VSCodium"
  apt_install codium
fi

# ── Cursor (official SIGNED apt repo) ────────────────────────────────────────
# Cursor publishes a proper signed apt repo (amd64,arm64). We write the key +
# deb822 source OURSELVES, pinned to the LOCAL arch: InRelease pins the hash of
# every per-arch Packages.gz it lists, so an upstream CDN-sync drift on the OTHER
# arch's index (we hit one 2026-05-29: amd64 Packages.gz republished 7.5h after
# InRelease was signed) would otherwise fail `apt update` on this box too — and
# STRICT-abort a golden build.
#   NB: the `cursor` .deb postinst REWRITES cursor.sources back to `amd64,arm64`
#   on every install/upgrade — defeating the arch pin — UNLESS we opt out of its
#   repo management via debconf (cursor/add-cursor-repo=false, preseeded below).
#   With that set, postinst leaves our narrowed file alone. (This does NOT make
#   us immune to a SAME-arch InRelease/Packages drift during a future Cursor
#   release — only retry/tolerance would — but it removes the cross-arch failure
#   mode, which is the common one.)
log "Cursor: AI editor (signed apt repo)"
cursor_ok=1
# GUI editor — skipped on a headless agent box.
minimal && { cursor_ok=0; log "Cursor: skipped (PROFILE=minimal)"; }
CURSOR_KR=/usr/share/keyrings/anysphere.gpg
if [ "$cursor_ok" = 1 ]; then
  case "$ARCH" in
    amd64|arm64) : ;;
    *) cursor_ok=0; warn "Cursor: unsupported arch '$ARCH' — skipping" ;;
  esac
fi
if [ "$cursor_ok" = 1 ] && dry; then
  would "download + fingerprint-verify ($CURSOR_FP) Cursor key -> $CURSOR_KR"
  would "add repo: deb822 https://downloads.cursor.com/aptrepo stable main"
elif [ "$cursor_ok" = 1 ]; then
  if curl -fsSL https://downloads.cursor.com/keys/anysphere.asc \
       | gpg --dearmor 2>/dev/null | $SUDO tee "$CURSOR_KR" >/dev/null \
     && $SUDO chmod a+r "$CURSOR_KR" \
     && verify_keyring "$CURSOR_KR" "$CURSOR_FP"; then
    printf 'Types: deb\nURIs: https://downloads.cursor.com/aptrepo\nSuites: stable\nComponents: main\nArchitectures: %s\nSigned-By: %s\n' \
      "$ARCH" "$CURSOR_KR" | $SUDO tee /etc/apt/sources.list.d/cursor.sources >/dev/null
  else
    cursor_ok=0
    $SUDO rm -f "$CURSOR_KR" /etc/apt/sources.list.d/cursor.sources
    soft_fail "Cursor key download/verify failed — skipping Cursor"
  fi
fi
if [ "$cursor_ok" = 1 ]; then
  # Opt out of the package's self-managed repo (see NB above) BEFORE install, so
  # its postinst keeps its hands off our arch-pinned cursor.sources. Harmless if
  # the debconf template is absent on a future Cursor build.
  if dry; then
    would "debconf preseed cursor/add-cursor-repo=false (keep our arch-pinned cursor.sources from the postinst rewrite)"
  else
    echo "cursor cursor/add-cursor-repo boolean false" | $SUDO debconf-set-selections 2>/dev/null || true
  fi
  vendor_apt_update /etc/apt/sources.list.d/cursor.sources "Cursor"
  apt_install cursor
fi
