#!/usr/bin/env bash
#
# build-appliance-iso.sh — remaster the Ubuntu 24.04 Live Server ISO into an
# unattended RNFleet bare-metal appliance installer.
#
# Designed to run on Linux (or inside the Ubuntu container started by
# build-appliance-iso.ps1). It:
#   1. fetches the stock Ubuntu Server ISO (cached),
#   2. injects the autoinstall seed (autoinstall/user-data + meta-data),
#   3. bundles the RNFleet payload (runtime + packaging) at /rnfleet on the ISO,
#   4. patches GRUB to boot straight into the unattended autoinstall, and
#   5. repacks a hybrid BIOS+UEFI bootable ISO with xorriso.
#
# Env overrides:
#   REPO_ROOT     repo root (default: three levels up from this script)
#   SRC_ISO       path to an existing Ubuntu Server ISO (skips download)
#   UBUNTU_ISO_URL  download URL if SRC_ISO is unset
#   ISO_CACHE     dir to cache the downloaded ISO (default: /isocache)
#   OUT_ISO       output path (default: /out/rnfleet-appliance-ubuntu-2404.iso)
#   VOL_ID        ISO volume label (default: RNFLEET_APPLIANCE)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
ISO_CACHE="${ISO_CACHE:-/isocache}"
OUT_ISO="${OUT_ISO:-/out/rnfleet-appliance-ubuntu-2404.iso}"
VOL_ID="${VOL_ID:-RNFLEET_APPLIANCE}"
UBUNTU_ISO_URL="${UBUNTU_ISO_URL:-}"
UBUNTU_RELEASE_BASE="${UBUNTU_RELEASE_BASE:-https://releases.ubuntu.com/24.04/}"
UBUNTU_ISO_FALLBACK="https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso"

WORK="$(mktemp -d)"
ISO_ROOT="$WORK/iso"
BOOT="$WORK/BOOT"
trap 'rm -rf "$WORK"' EXIT

log() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# 0. Tooling (xorriso + 7z). Auto-install when run as root on Debian/Ubuntu.
# ---------------------------------------------------------------------------
ensure_tools() {
  local missing=0
  command -v xorriso >/dev/null 2>&1 || missing=1
  command -v 7z >/dev/null 2>&1 || command -v 7za >/dev/null 2>&1 || missing=1
  command -v curl >/dev/null 2>&1 || missing=1
  if [ "$missing" -eq 1 ]; then
    if [ "$(id -u)" -eq 0 ] && command -v apt-get >/dev/null 2>&1; then
      log "Installing build tools (xorriso, p7zip-full, curl)..."
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq xorriso p7zip-full curl ca-certificates
    else
      echo "Missing xorriso/7z/curl and cannot auto-install. Install them and retry." >&2
      exit 1
    fi
  fi
}
# SEVENZ is resolved after ensure_tools() installs p7zip (see bottom of file).
SEVENZ=""

# ---------------------------------------------------------------------------
# 1. Obtain the source ISO.
# ---------------------------------------------------------------------------
get_iso() {
  if [ -n "${SRC_ISO:-}" ] && [ -f "${SRC_ISO:-}" ]; then
    log "Using provided SRC_ISO=$SRC_ISO"
    SOURCE_ISO="$SRC_ISO"
    return
  fi
  # Resolve the current point-release filename (point releases get superseded, so
  # a hard-coded URL eventually 404s). Fall back to a pinned version if listing fails.
  if [ -z "$UBUNTU_ISO_URL" ]; then
    local fname
    fname="$(curl -fsSL "$UBUNTU_RELEASE_BASE" 2>/dev/null \
      | grep -oE 'ubuntu-24\.04\.[0-9]+-live-server-amd64\.iso' | sort -V | uniq | tail -1 || true)"
    if [ -n "$fname" ]; then
      UBUNTU_ISO_URL="${UBUNTU_RELEASE_BASE}${fname}"
    else
      UBUNTU_ISO_URL="$UBUNTU_ISO_FALLBACK"
    fi
  fi
  mkdir -p "$ISO_CACHE"
  local fname; fname="$(basename "$UBUNTU_ISO_URL")"
  SOURCE_ISO="$ISO_CACHE/$fname"
  if [ ! -f "$SOURCE_ISO" ]; then
    log "Downloading $UBUNTU_ISO_URL (~3 GB, cached in $ISO_CACHE)..."
    curl -fL --retry 3 -o "$SOURCE_ISO.part" "$UBUNTU_ISO_URL"
    mv "$SOURCE_ISO.part" "$SOURCE_ISO"
  else
    log "Using cached ISO $SOURCE_ISO"
  fi
}

# ---------------------------------------------------------------------------
# 2. Assemble the RNFleet payload that the autoinstall copies into the target.
# ---------------------------------------------------------------------------
stage_payload() {
  log "Staging RNFleet payload..."
  local p="$ISO_ROOT/rnfleet"
  mkdir -p "$p/apps" "$p/packages"
  cp "$REPO_ROOT/package.json" "$p/package.json"
  [ -f "$REPO_ROOT/package-lock.json" ] && cp "$REPO_ROOT/package-lock.json" "$p/package-lock.json"
  # Source trees WITHOUT node_modules (npm install runs in-target).
  cp -a "$REPO_ROOT/apps/device-runtime" "$p/apps/"
  cp -a "$REPO_ROOT/packages/contracts"  "$p/packages/"
  rm -rf "$p/apps/device-runtime/node_modules" "$p/packages/contracts/node_modules"
  cp "$SCRIPT_DIR/provision-appliance.sh" "$p/provision-appliance.sh"
  # Optional factory pre-seed: bake an enrollment.conf so the appliance enrolls
  # unattended on first boot. Keep secrets OUT of git — pass via ENROLLMENT_CONF.
  if [ -n "${ENROLLMENT_CONF:-}" ] && [ -f "${ENROLLMENT_CONF:-}" ]; then
    log "Baking factory pre-seed from $ENROLLMENT_CONF"
    cp "$ENROLLMENT_CONF" "$p/enrollment.conf"
  fi
  # Normalise EOLs (payload may be checked out on Windows).
  find "$p" -type f \( -name '*.sh' -o -name '30-rnfleet' \) -exec sed -i 's/\r$//' {} +
}

# ---------------------------------------------------------------------------
# 3. Inject autoinstall seed + patch GRUB for hands-off install.
# ---------------------------------------------------------------------------
inject_autoinstall() {
  log "Injecting autoinstall seed..."
  mkdir -p "$ISO_ROOT/autoinstall"
  cp "$SCRIPT_DIR/autoinstall/user-data" "$ISO_ROOT/autoinstall/user-data"
  cp "$SCRIPT_DIR/autoinstall/meta-data" "$ISO_ROOT/autoinstall/meta-data"
  sed -i 's/\r$//' "$ISO_ROOT/autoinstall/user-data" "$ISO_ROOT/autoinstall/meta-data"

  local grub="$ISO_ROOT/boot/grub/grub.cfg"
  log "Patching $grub..."
  # Boot the first entry quickly and unattended.
  sed -i 's/^set timeout=.*/set timeout=5/' "$grub"
  sed -i 's/^timeout=.*/timeout=5/' "$grub" 2>/dev/null || true
  # Append the autoinstall kernel args to every `linux` line that isn't already
  # patched. ds=nocloud points at the seed dir we just wrote.
  sed -i '/[[:space:]]autoinstall[[:space:]]/!s#\(linux[[:space:]]\+/casper/vmlinuz\)\([^\n]*\)#\1 autoinstall ds=nocloud\\;s=/cdrom/autoinstall/\2#' "$grub"
  # Make the default menu entry the (now unattended) install.
  sed -i '0,/^menuentry/s//set default=0\n&/' "$grub" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 4. Repack a hybrid BIOS+UEFI bootable ISO.
# ---------------------------------------------------------------------------
repack() {
  log "Extracting source ISO with 7z..."
  "$SEVENZ" -y x "$SOURCE_ISO" -o"$ISO_ROOT" >/dev/null
  # 7z drops El Torito boot images into a [BOOT] folder; move it aside so it is
  # not written back into the filesystem tree.
  if [ -d "$ISO_ROOT/[BOOT]" ]; then
    mkdir -p "$BOOT"
    mv "$ISO_ROOT/[BOOT]"/* "$BOOT"/
    rm -rf "$ISO_ROOT/[BOOT]"
  else
    echo "Expected [BOOT] dir from 7z extraction not found." >&2
    exit 1
  fi

  stage_payload
  inject_autoinstall

  log "Repacking ISO -> $OUT_ISO"
  mkdir -p "$(dirname "$OUT_ISO")"
  xorriso -as mkisofs -r \
    -V "$VOL_ID" \
    -o "$OUT_ISO" \
    --grub2-mbr "$BOOT/1-Boot-NoEmul.img" \
    -partition_offset 16 \
    --mbr-force-bootable \
    -append_partition 2 0xEF "$BOOT/2-Boot-NoEmul.img" \
    -appended_part_as_gpt \
    -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
    -c '/boot.catalog' \
    -b '/boot/grub/i386-pc/eltorito.img' \
      -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
    -eltorito-alt-boot \
    -e '--interval:appended_partition_2:::' \
      -no-emul-boot \
    "$ISO_ROOT"

  log "Done. Output: $OUT_ISO"
  ls -lh "$OUT_ISO"
}

ensure_tools
SEVENZ="$(command -v 7z || command -v 7za)"
get_iso
mkdir -p "$ISO_ROOT"
repack
