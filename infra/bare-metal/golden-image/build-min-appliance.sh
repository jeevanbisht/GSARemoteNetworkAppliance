#!/usr/bin/env bash
#
# build-min-appliance.sh — build a MINIMAL, bootable RNFleet appliance image from
# scratch using mmdebstrap (Debian bookworm). Produces a compressed qcow2 that
# boots on any hypervisor / bare-metal with no local dependency.
#
# Designed to run inside a privileged Debian container (provider-agnostic), e.g.:
#   docker run --rm --privileged \
#       -v <repo>:/repo:ro -v <out>:/out \
#       debian:bookworm-slim bash /repo/infra/bare-metal/golden-image/build-min-appliance.sh
#
# Why Debian-minimal (not Alpine): the runtime needs systemd units, glibc, and
# Debian package names (strongswan-swanctl, charon-systemd, frr, nodejs). This
# bakes the SAME stack as provision-appliance.sh but on a tiny base, so the image
# is ~10x smaller than a full Ubuntu install while behaving identically.
set -euo pipefail

REPO="${REPO:-/repo}"
OUT="${OUT:-/out}"
SUITE="${SUITE:-bookworm}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
IMG_SIZE="${IMG_SIZE:-4G}"
IMG_RAW="$OUT/rnfleet-appliance-min.raw"
IMG_QCOW="$OUT/rnfleet-appliance-min.qcow2"
HOSTNAME_DEF="rnfleet-appliance"
APP_USER="rnfleet"
# SHA-512 crypt of "rnfleet" (same as the autoinstall user-data).
APP_PWHASH='$6$rnfleetsalt01$vUpX8/EVag8y4TylWLuqe/jCnpKfxobgNSWy94KrJaM.xzDMOBKx/5mpr9aiC3kXTHMWhScuUkyYCdw0QEnCR0'

log(){ echo -e "\n=== $* ==="; }

# Packages baked into the base image. The appliance stack mirrors
# provision-appliance.sh; grub-*-bin (not the meta packages) avoids debconf
# install-device prompts so the build stays non-interactive.
INCLUDE="systemd-sysv,udev,dbus,init,kmod,linux-image-amd64,\
grub-efi-amd64-bin,grub-pc-bin,grub-common,grub2-common,\
ifupdown,isc-dhcp-client,iproute2,iputils-ping,openssh-server,\
ca-certificates,curl,gnupg,sudo,locales,less,nano,xz-utils,zstd,\
strongswan-swanctl,charon-systemd,strongswan-pki,libcharon-extra-plugins,\
libstrongswan-extra-plugins,frr,frr-pythontools,dnsmasq,nftables"

# Provider-neutral extension points (used by the cloud provider trees, e.g.
# infra/cloud/azure/appliance-image). Both are no-ops unless set, so the default
# bare-metal/Hyper-V image is byte-identical to before:
#   EXTRA_INCLUDE   — extra comma-separated packages appended to the base set.
#   EXTRA_CONFIGURE — path (inside the build container) to a shell script run in
#                     the target chroot AFTER provisioning, BEFORE the bootloader.
if [ -n "${EXTRA_INCLUDE:-}" ]; then
  INCLUDE="$INCLUDE,$EXTRA_INCLUDE"
fi

cleanup() {
  set +e
  if mountpoint -q /mnt/appliance 2>/dev/null; then
    for m in dev/pts dev proc sys boot/efi ""; do
      umount -lf "/mnt/appliance/$m" 2>/dev/null
    done
  fi
  if [ -n "${LOOP:-}" ]; then
    kpartx -d "$LOOP" 2>/dev/null
    losetup -d "$LOOP" 2>/dev/null
  fi
}
trap cleanup EXIT

log "Installing build tooling"
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null
apt-get -qq install -y mmdebstrap parted gdisk dosfstools e2fsprogs \
  grub-efi-amd64-bin grub-pc-bin grub-common qemu-utils kpartx util-linux fdisk \
  ca-certificates >/dev/null

log "Creating raw image ($IMG_SIZE) + GPT partitions"
rm -f "$IMG_RAW" "$IMG_QCOW"
truncate -s "$IMG_SIZE" "$IMG_RAW"
# p1 BIOS boot (1M), p2 ESP (256M, fat32), p3 root (rest, ext4)
sgdisk -Z "$IMG_RAW" >/dev/null
sgdisk -n1:0:+1M   -t1:ef02 -c1:"BIOS"  "$IMG_RAW" >/dev/null
sgdisk -n2:0:+256M -t2:ef00 -c2:"ESP"   "$IMG_RAW" >/dev/null
sgdisk -n3:0:0     -t3:8300 -c3:"root"  "$IMG_RAW" >/dev/null

# Whole-disk loop (for BIOS grub) + kpartx device-mapper partition nodes (visible
# inside the container's /dev, unlike losetup -P partition nodes).
LOOP="$(losetup --find --show "$IMG_RAW")"
kpartx -as "$LOOP"
BASE="$(basename "$LOOP")"
ESP_PART="/dev/mapper/${BASE}p2"; ROOT_PART="/dev/mapper/${BASE}p3"
echo "loop=$LOOP  esp=$ESP_PART  root=$ROOT_PART"
sleep 1
mkfs.fat -F32 -n ESP "$ESP_PART" >/dev/null
mkfs.ext4 -q -L root "$ROOT_PART"

mkdir -p /mnt/appliance
mount "$ROOT_PART" /mnt/appliance

log "mmdebstrap $SUITE -> rootfs (this is the long step)"
mmdebstrap \
  --variant=important \
  --components="main" \
  --include="$INCLUDE" \
  --aptopt='Apt::Install-Recommends "false"' \
  --skip=check/empty \
  "$SUITE" /mnt/appliance "$MIRROR"

# Mount the ESP now (after the base is laid down) for grub EFI install.
mkdir -p /mnt/appliance/boot/efi
mount "$ESP_PART" /mnt/appliance/boot/efi

log "Staging appliance payload"
PAY=/mnt/appliance/opt/rnfleet-bootstrap
mkdir -p "$PAY/apps" "$PAY/packages"
cp "$REPO/package.json" "$PAY/"
[ -f "$REPO/package-lock.json" ] && cp "$REPO/package-lock.json" "$PAY/"
cp -a "$REPO/apps/device-runtime" "$PAY/apps/"
cp -a "$REPO/packages/contracts"  "$PAY/packages/"
cp "$REPO/infra/bare-metal/iso/provision-appliance.sh" "$PAY/"
cp /etc/resolv.conf /mnt/appliance/etc/resolv.conf

# Optional provider hook: copy it into the target so the chroot can run it.
if [ -n "${EXTRA_CONFIGURE:-}" ]; then
  [ -f "$EXTRA_CONFIGURE" ] || { echo "EXTRA_CONFIGURE not found: $EXTRA_CONFIGURE"; exit 1; }
  cp "$EXTRA_CONFIGURE" /mnt/appliance/root/extra-configure.sh
  chmod +x /mnt/appliance/root/extra-configure.sh
  echo "staged EXTRA_CONFIGURE hook: $EXTRA_CONFIGURE"
fi

ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
ESP_UUID="$(blkid -s UUID -o value "$ESP_PART")"

log "Writing in-chroot configure script"
cat > /mnt/appliance/root/configure.sh <<CHROOT
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "$HOSTNAME_DEF" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME_DEF
EOF

# Locale
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
locale-gen >/dev/null 2>&1 || true

# fstab
cat > /etc/fstab <<EOF
UUID=$ROOT_UUID  /          ext4  errors=remount-ro  0 1
UUID=$ESP_UUID   /boot/efi  vfat  umask=0077         0 1
EOF

# WAN networking: eth0 via DHCP (net.ifnames=0 gives predictable ethN).
# allow-hotplug (not auto) so networking.service does NOT block boot waiting on
# DHCP — udev brings eth0 up asynchronously when it appears. An appliance must
# boot fast even when the WAN has a slow/absent DHCP server.
cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet dhcp
EOF

# Bound the DHCP attempt so a dead WAN never stalls bring-up for minutes.
if [ -f /etc/dhcp/dhclient.conf ]; then
  grep -q '^timeout ' /etc/dhcp/dhclient.conf || echo 'timeout 15;' >> /etc/dhcp/dhclient.conf
fi

# Login user (created BEFORE provision so install-device-runtime reuses it).
if ! id -u "$APP_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$APP_USER"
fi
echo '$APP_USER:$APP_PWHASH' | chpasswd -e
usermod -aG sudo "$APP_USER"
# Lock direct root login; rnfleet has sudo.
passwd -l root >/dev/null 2>&1 || true

# Serial console (GSA testing uses the serial console) + local tty.
systemctl enable serial-getty@ttyS0.service >/dev/null 2>&1 || true
systemctl enable ssh.service >/dev/null 2>&1 || true
# Offline-safe symlinks (chroot has no running systemd): console getty + nftables.
mkdir -p /etc/systemd/system/getty.target.wants /etc/systemd/system/multi-user.target.wants
ln -sf /lib/systemd/system/serial-getty@.service /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service
ln -sf /lib/systemd/system/nftables.service /etc/systemd/system/multi-user.target.wants/nftables.service

# ---- Provision the RNFleet runtime + LAN router + first-boot wizard ----
bash /opt/rnfleet-bootstrap/provision-appliance.sh

# ---- Optional provider hook (e.g. Azure agent / cloud-init) ----
if [ -f /root/extra-configure.sh ]; then
  echo "=== running EXTRA_CONFIGURE hook in chroot ==="
  bash /root/extra-configure.sh
  rm -f /root/extra-configure.sh
fi

# ---- Bootloader ----
cat > /etc/default/grub <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="RNFleet"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="console=tty1 console=ttyS0,115200n8 net.ifnames=0 biosdevname=0"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF

# EFI (removable path so it boots with no NVRAM entry — portable across clouds /
# Hyper-V Gen2) AND BIOS (grub-pc) for legacy/bare-metal.
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=rnfleet --removable --no-nvram --recheck "$LOOP" || \
  grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=rnfleet --removable --no-nvram --recheck
grub-install --target=i386-pc --recheck "$LOOP" || echo "WARN: BIOS grub-install failed (EFI still OK)"
update-grub
# grub-mkconfig may bake the build-time device-mapper path into the kernel root=
# (grub-probe can't derive a UUID from /dev/mapper/* in the chroot). Force root by
# UUID so the image boots on the real machine where that path doesn't exist.
sed -i "s#root=/dev/[^ ]*#root=UUID=$ROOT_UUID#g" /boot/grub/grub.cfg
grep -q "root=UUID=$ROOT_UUID" /boot/grub/grub.cfg && echo "grub root pinned to UUID=$ROOT_UUID"

# Trim apt caches to keep the image small.
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /opt/rnfleet-bootstrap
CHROOT

chmod +x /mnt/appliance/root/configure.sh

log "Entering chroot (bind /dev /proc /sys)"
mount --bind /dev  /mnt/appliance/dev
mount --bind /dev/pts /mnt/appliance/dev/pts
mount -t proc proc /mnt/appliance/proc
mount -t sysfs sys /mnt/appliance/sys
LOOP="$LOOP" chroot /mnt/appliance /usr/bin/env LOOP="$LOOP" bash /root/configure.sh
rm -f /mnt/appliance/root/configure.sh
# DNS: ship a real /etc/resolv.conf with public bootstrap resolvers. Do NOT
# symlink to systemd-resolved's stub (systemd-resolved is not installed, so the
# symlink would dangle and break DNS). At runtime ifupdown/dhclient overwrites
# this regular file with the DHCP-provided nameservers; the public resolvers are
# the fallback when DHCP supplies none.
rm -f /mnt/appliance/etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /mnt/appliance/etc/resolv.conf

log "Verification (inside built rootfs)"
echo "--- enabled units ---"
for u in ssh serial-getty@ttyS0 getty@tty1 strongswan frr nftables rnfleet-lan-router; do
  ls -l /mnt/appliance/etc/systemd/system/*.wants/$u* /mnt/appliance/etc/systemd/system/multi-user.target.wants/$u* 2>/dev/null \
    | grep -q . && echo "  [on]  $u" || echo "  [--]  $u (check)"
done
echo "--- runtime DISABLED (factory) ? ---"
ls /mnt/appliance/etc/systemd/system/multi-user.target.wants/rnfleet-device-runtime.service 2>/dev/null \
  && echo "  WARN runtime enabled" || echo "  [ok] runtime not enabled (waits for enrollment)"
echo "--- key files ---"
for f in usr/bin/node opt/rnfleet/apps/device-runtime/src/agent.js \
         usr/local/sbin/rnfleet-setup usr/local/sbin/rnfleet-lan-router \
         etc/rnfleet/lan-router.conf boot/grub/grub.cfg boot/efi/EFI/BOOT/BOOTX64.EFI; do
  [ -e "/mnt/appliance/$f" ] && echo "  [ok] $f" || echo "  [MISSING] $f"
done
echo "--- kernel ---"; ls /mnt/appliance/boot/vmlinuz-* 2>/dev/null || echo "  NO KERNEL"
echo "--- rootfs size ---"; du -sh --one-file-system /mnt/appliance 2>/dev/null | awk '{print "  used: "$1}' || true

log "Unmount + convert to compressed qcow2"
sync
for m in dev/pts dev proc sys boot/efi ""; do umount -lf "/mnt/appliance/$m" 2>/dev/null || true; done
kpartx -d "$LOOP"; losetup -d "$LOOP"; LOOP=""
qemu-img convert -O qcow2 -c "$IMG_RAW" "$IMG_QCOW"
rm -f "$IMG_RAW"

log "DONE"
ls -lh "$IMG_QCOW" | awk '{print "  qcow2: "$5"  "$9}'
qemu-img info "$IMG_QCOW" | sed 's/^/  /'
