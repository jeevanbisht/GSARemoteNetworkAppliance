#!/usr/bin/env bash
#
# finish-min-appliance.sh — resume an appliance image build from an existing raw
# image whose rootfs was already laid down by build-min-appliance.sh (mmdebstrap).
# Re-runs ONLY the staging + in-chroot configure + grub + qcow2 steps, so grub /
# provisioning can be iterated without re-running the slow debootstrap.
#
#   docker run --rm --privileged -v <repo>:/repo:ro -v <out>:/out \
#       debian:bookworm-slim bash /repo/infra/bare-metal/golden-image/finish-min-appliance.sh
set -euo pipefail

REPO="${REPO:-/repo}"
OUT="${OUT:-/out}"
IMG_RAW="$OUT/rnfleet-appliance-min.raw"
IMG_QCOW="$OUT/rnfleet-appliance-min.qcow2"
HOSTNAME_DEF="rnfleet-appliance"
APP_USER="rnfleet"
APP_PWHASH='$6$rnfleetsalt01$vUpX8/EVag8y4TylWLuqe/jCnpKfxobgNSWy94KrJaM.xzDMOBKx/5mpr9aiC3kXTHMWhScuUkyYCdw0QEnCR0'

log(){ echo -e "\n=== $* ==="; }

cleanup() {
  set +e
  if mountpoint -q /mnt/appliance 2>/dev/null; then
    for m in dev/pts dev proc sys boot/efi ""; do umount -lf "/mnt/appliance/$m" 2>/dev/null; done
  fi
  if [ -n "${LOOP:-}" ]; then kpartx -d "$LOOP" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; fi
}
trap cleanup EXIT

[ -f "$IMG_RAW" ] || { echo "no raw image at $IMG_RAW — run build-min-appliance.sh first"; exit 1; }

log "Installing tooling"
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null
apt-get -qq install -y kpartx qemu-utils dosfstools e2fsprogs util-linux ca-certificates >/dev/null

log "Re-attaching raw image"
LOOP="$(losetup --find --show "$IMG_RAW")"
kpartx -as "$LOOP"; BASE="$(basename "$LOOP")"
ESP_PART="/dev/mapper/${BASE}p2"; ROOT_PART="/dev/mapper/${BASE}p3"
echo "loop=$LOOP esp=$ESP_PART root=$ROOT_PART"; sleep 1
mkdir -p /mnt/appliance
mount "$ROOT_PART" /mnt/appliance
mount "$ESP_PART"  /mnt/appliance/boot/efi

log "Re-staging appliance payload"
PAY=/mnt/appliance/opt/rnfleet-bootstrap
rm -rf "$PAY"; mkdir -p "$PAY/apps" "$PAY/packages"
cp "$REPO/package.json" "$PAY/"
[ -f "$REPO/package-lock.json" ] && cp "$REPO/package-lock.json" "$PAY/"
cp -a "$REPO/apps/device-runtime" "$PAY/apps/"
cp -a "$REPO/packages/contracts"  "$PAY/packages/"
cp "$REPO/infra/bare-metal/iso/provision-appliance.sh" "$PAY/"
cp /etc/resolv.conf /mnt/appliance/etc/resolv.conf

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

sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
locale-gen >/dev/null 2>&1 || true

cat > /etc/fstab <<EOF
UUID=$ROOT_UUID  /          ext4  errors=remount-ro  0 1
UUID=$ESP_UUID   /boot/efi  vfat  umask=0077         0 1
EOF

cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet dhcp
EOF

if [ -f /etc/dhcp/dhclient.conf ]; then
  grep -q '^timeout ' /etc/dhcp/dhclient.conf || echo 'timeout 15;' >> /etc/dhcp/dhclient.conf
fi

if ! id -u "$APP_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$APP_USER"
fi
echo '$APP_USER:$APP_PWHASH' | chpasswd -e
usermod -aG sudo "$APP_USER"
passwd -l root >/dev/null 2>&1 || true

systemctl enable serial-getty@ttyS0.service >/dev/null 2>&1 || true
systemctl enable ssh.service >/dev/null 2>&1 || true
# Offline-safe symlinks (chroot has no running systemd): console getty + nftables.
mkdir -p /etc/systemd/system/getty.target.wants /etc/systemd/system/multi-user.target.wants
ln -sf /lib/systemd/system/serial-getty@.service /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service
ln -sf /lib/systemd/system/nftables.service /etc/systemd/system/multi-user.target.wants/nftables.service

bash /opt/rnfleet-bootstrap/provision-appliance.sh

cat > /etc/default/grub <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="RNFleet"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="console=tty1 console=ttyS0,115200n8 net.ifnames=0 biosdevname=0"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF

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

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /opt/rnfleet-bootstrap
CHROOT
chmod +x /mnt/appliance/root/configure.sh

log "Entering chroot"
mount --bind /dev  /mnt/appliance/dev
mount --bind /dev/pts /mnt/appliance/dev/pts
mount -t proc proc /mnt/appliance/proc
mount -t sysfs sys /mnt/appliance/sys
chroot /mnt/appliance /usr/bin/env LOOP="$LOOP" bash /root/configure.sh
rm -f /mnt/appliance/root/configure.sh
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /mnt/appliance/etc/resolv.conf

log "Verification"
for u in ssh serial-getty@ttyS0 getty@tty1 strongswan frr nftables rnfleet-lan-router; do
  ls /mnt/appliance/etc/systemd/system/*.wants/$u* /mnt/appliance/etc/systemd/system/multi-user.target.wants/$u* >/dev/null 2>&1 \
    && echo "  [on]  $u" || echo "  [--]  $u (check)"
done
ls /mnt/appliance/etc/systemd/system/multi-user.target.wants/rnfleet-device-runtime.service >/dev/null 2>&1 \
  && echo "  WARN runtime enabled" || echo "  [ok] runtime gated (waits for enrollment)"
for f in usr/bin/node opt/rnfleet/apps/device-runtime/src/agent.js \
         usr/local/sbin/rnfleet-setup usr/local/sbin/rnfleet-lan-router \
         etc/rnfleet/lan-router.conf boot/grub/grub.cfg boot/efi/EFI/BOOT/BOOTX64.EFI; do
  [ -e "/mnt/appliance/$f" ] && echo "  [ok] $f" || echo "  [MISSING] $f"
done
ls /mnt/appliance/boot/vmlinuz-* >/dev/null 2>&1 && echo "  [ok] kernel present" || echo "  [MISSING] kernel"
du -sh --one-file-system /mnt/appliance 2>/dev/null | awk '{print "  rootfs used: "$1}' || true

log "Convert to compressed qcow2"
sync
for m in dev/pts dev proc sys boot/efi ""; do umount -lf "/mnt/appliance/$m" 2>/dev/null || true; done
kpartx -d "$LOOP"; losetup -d "$LOOP"; LOOP=""
rm -f "$IMG_QCOW"
qemu-img convert -O qcow2 -c "$IMG_RAW" "$IMG_QCOW"

log "DONE"
ls -lh "$IMG_QCOW" | awk '{print "  qcow2: "$5"  "$9}'
qemu-img info "$IMG_QCOW" | sed 's/^/  /'
