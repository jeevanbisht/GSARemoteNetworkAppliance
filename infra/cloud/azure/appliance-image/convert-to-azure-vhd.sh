#!/usr/bin/env bash
#
# convert-to-azure-vhd.sh — convert the appliance qcow2 into an Azure-compatible
# FIXED VHD (vpc subformat), with the virtual size rounded UP to a whole MiB.
#
# Azure rejects images that are not a fixed VHD whose virtual size is an exact
# multiple of 1 MiB. qcow2/VHDX (dynamic) are NOT accepted by managed-disk /
# image creation.
#
# Run in a qemu-img container (provider-agnostic), e.g.:
#   docker run --rm -v <out>:/out debian:bookworm-slim \
#     bash /out/convert-to-azure-vhd.sh /out/rnfleet-appliance-min.qcow2 \
#                                       /out/rnfleet-appliance-azure.vhd
set -euo pipefail

SRC="${1:-/out/rnfleet-appliance-min.qcow2}"
DST="${2:-/out/rnfleet-appliance-azure.vhd}"
MIB=$((1024 * 1024))

[ -f "$SRC" ] || { echo "source image not found: $SRC"; exit 1; }

if ! command -v qemu-img >/dev/null 2>&1; then
  echo "=== installing qemu-utils ==="
  export DEBIAN_FRONTEND=noninteractive
  apt-get -qq update >/dev/null
  apt-get -qq install -y qemu-utils >/dev/null
fi

echo "=== source ==="
qemu-img info "$SRC" | sed 's/^/  /'

# Round the virtual size UP to a whole MiB (Azure requirement).
VSIZE="$(qemu-img info --output=json "$SRC" | grep -o '"virtual-size": *[0-9]*' | grep -o '[0-9]*')"
ROUNDED=$(( (VSIZE + MIB - 1) / MIB * MIB ))
echo "  virtual-size = $VSIZE bytes -> aligned $ROUNDED bytes ($((ROUNDED/MIB)) MiB)"

WORK="$(dirname "$DST")/.azure-convert.raw"
echo "=== qcow2 -> raw (resize to MiB boundary) ==="
qemu-img convert -f qcow2 -O raw "$SRC" "$WORK"
qemu-img resize -f raw "$WORK" "$ROUNDED"

echo "=== raw -> fixed VHD (vpc, force_size) ==="
rm -f "$DST"
qemu-img convert -f raw -O vpc -o subformat=fixed,force_size "$WORK" "$DST"
rm -f "$WORK"

echo "=== result ==="
ls -lh "$DST" | awk '{print "  vhd: "$5"  "$9}'
qemu-img info -f vpc "$DST" | sed 's/^/  /'

# Sanity: parse the VHD footer explicitly (-f vpc) — probing without -f can
# mis-detect a fixed VHD as raw and report size+512. Azure needs the VPC virtual
# size (data portion) to be a whole number of MiB.
OUT_VSIZE="$(qemu-img info -f vpc --output=json "$DST" | grep -o '"virtual-size": *[0-9]*' | grep -o '[0-9]*')"
if [ $(( OUT_VSIZE % MIB )) -ne 0 ]; then
  echo "ERROR: output virtual size $OUT_VSIZE is NOT a multiple of 1 MiB"; exit 1
fi
echo "OK: fixed VHD virtual size is MiB-aligned ($((OUT_VSIZE/MIB)) MiB) — ready for Azure upload"
