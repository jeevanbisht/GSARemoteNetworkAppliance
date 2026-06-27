#!/usr/bin/env bash
#
# provision-appliance.sh — turn a freshly installed Ubuntu system into an RNFleet
# bare-metal appliance. This is the provider-agnostic analog of the Packer image's
# shell provisioners; it is invoked:
#   * by the autoinstall ISO (late-commands, via `curtin in-target`), and
#   * standalone on any existing Ubuntu box:  sudo bash provision-appliance.sh
#
# It installs the tunnel stack (strongSwan/swanctl + FRR), Node 22, the RNFleet
# device runtime, and the first-boot enrollment wizard. The runtime is left
# DISABLED with no identity; the wizard (rnfleet-setup) enables it once the
# operator enrolls the appliance.
#
# Payload layout (this script's directory is the payload root):
#   ./package.json ./package-lock.json
#   ./apps/device-runtime/...      (incl. packaging/ with install + firstboot assets)
#   ./packages/contracts/...
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" -ne 0 ]; then
  echo "provision-appliance.sh must run as root (try: sudo bash $0)" >&2
  exit 1
fi

PAYLOAD_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_DIR="$PAYLOAD_DIR/apps/device-runtime/packaging"
FB_DIR="$PKG_DIR/firstboot"
SYSTEMD_DIR="$PKG_DIR/systemd"

echo "==> RNFleet appliance provisioning (payload: $PAYLOAD_DIR)"

# ---------------------------------------------------------------------------
# 1. Tunnel stack: strongSwan (swanctl/vici) + FRR (BGP). Idempotent — the ISO's
#    autoinstall `packages:` may already have installed these; standalone runs do
#    it here. The tunnel agent drives modern `swanctl` (NOT the legacy starter).
# ---------------------------------------------------------------------------
need_pkgs=""
for p in strongswan-swanctl charon-systemd strongswan-pki libcharon-extra-plugins \
         libstrongswan-extra-plugins frr frr-pythontools dnsmasq nftables \
         ca-certificates curl gnupg; do
  dpkg -s "$p" >/dev/null 2>&1 || need_pkgs="$need_pkgs $p"
done
if [ -n "$need_pkgs" ]; then
  apt-get update
  apt-get install -y $need_pkgs
fi

# Enable the BGP daemon (off by default in FRR).
sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons
# Allow IP forwarding so the appliance can route tunnelled traffic.
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-rnfleet-forwarding.conf
# Use swanctl-based charon-systemd; disable the legacy starter.
systemctl disable --now strongswan-starter 2>/dev/null || true
systemctl enable strongswan 2>/dev/null || systemctl enable strongswan-starter 2>/dev/null || true
systemctl enable frr 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1b. LAN router role: the appliance acts as the default gateway for a client
#     LAN and routes traffic to GSA (split tunnel) and the local WAN. dnsmasq
#     serves DHCP/DNS; rnfleet-lan-router applies the LAN IP + nftables NAT.
#     dnsmasq is left DISABLED here — rnfleet-lan-router starts it ONLY when a
#     separate LAN NIC exists (so single-NIC cloud VMs don't fail at boot).
# ---------------------------------------------------------------------------
LAN_DIR="$PKG_DIR/lan-router"
systemctl disable --now dnsmasq 2>/dev/null || true
install -m 0755 "$LAN_DIR/rnfleet-lan-router.sh"      /usr/local/sbin/rnfleet-lan-router
mkdir -p /etc/rnfleet
if [ ! -f /etc/rnfleet/lan-router.conf ]; then
  install -m 0644 "$LAN_DIR/lan-router.conf.example"  /etc/rnfleet/lan-router.conf
fi
install -m 0644 "$LAN_DIR/lan-router.conf.example"    /etc/rnfleet/lan-router.conf.example
install -m 0644 "$LAN_DIR/rnfleet-lan-router.service" /etc/systemd/system/rnfleet-lan-router.service
sed -i 's/\r$//' /usr/local/sbin/rnfleet-lan-router
systemctl enable nftables 2>/dev/null || true
systemctl enable rnfleet-lan-router.service 2>/dev/null || true
# Offline-safe: guarantee the wants symlink even when systemd isn't running
# (e.g. provisioning inside a build chroot / curtin in-target).
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/rnfleet-lan-router.service \
       /etc/systemd/system/multi-user.target.wants/rnfleet-lan-router.service

# ---------------------------------------------------------------------------
# 2. Stage the monorepo subset the installer expects, then run the shared
#    install-device-runtime.sh (installs Node 22, the runtime, its systemd unit).
# ---------------------------------------------------------------------------
rm -rf /tmp/rnfleet-src /tmp/rnfleet-packaging
mkdir -p /tmp/rnfleet-src/apps /tmp/rnfleet-src/packages /tmp/rnfleet-packaging

cp "$PAYLOAD_DIR/package.json" /tmp/rnfleet-src/package.json
[ -f "$PAYLOAD_DIR/package-lock.json" ] && cp "$PAYLOAD_DIR/package-lock.json" /tmp/rnfleet-src/package-lock.json
cp -a "$PAYLOAD_DIR/apps/device-runtime" /tmp/rnfleet-src/apps/
cp -a "$PAYLOAD_DIR/packages/contracts" /tmp/rnfleet-src/packages/

cp "$PKG_DIR/install-device-runtime.sh"            /tmp/rnfleet-packaging/install-device-runtime.sh
cp "$PKG_DIR/device-runtime.env.example"           /tmp/rnfleet-packaging/device-runtime.env.example
cp "$SYSTEMD_DIR/rnfleet-device-runtime.service"   /tmp/rnfleet-packaging/rnfleet-device-runtime.service

sed -i 's/\r$//' /tmp/rnfleet-packaging/install-device-runtime.sh
chmod +x /tmp/rnfleet-packaging/install-device-runtime.sh
/tmp/rnfleet-packaging/install-device-runtime.sh

# ---------------------------------------------------------------------------
# 3. First-boot enrollment wizard + console service + login banner + preseed.
# ---------------------------------------------------------------------------
install -m 0755 "$FB_DIR/rnfleet-setup.sh"             /usr/local/sbin/rnfleet-setup
install -m 0755 "$FB_DIR/rnfleet-console-entry.sh"     /usr/local/sbin/rnfleet-console-entry
install -m 0755 "$FB_DIR/30-rnfleet"                   /etc/update-motd.d/30-rnfleet
mkdir -p /etc/rnfleet
install -m 0644 "$FB_DIR/enrollment.conf.example"      /etc/rnfleet/enrollment.conf.example
[ -f "$FB_DIR/rnfleet-logo.txt" ] && install -m 0644 "$FB_DIR/rnfleet-logo.txt" /etc/rnfleet/logo.txt
# Legacy single-console wizard unit — installed for reference but NOT enabled.
# The wizard now runs as the getty entry on BOTH consoles (see drop-ins below).
install -m 0644 "$SYSTEMD_DIR/rnfleet-firstboot.service" /etc/systemd/system/rnfleet-firstboot.service
# Show the first-boot wizard on BOTH the video console (tty1) and the serial port
# (ttyS0): override each getty's ExecStart to run rnfleet-console-entry, which
# prompts until the box is enrolled and then execs a normal login.
for inst in getty@tty1 serial-getty@ttyS0; do
  dropdir="/etc/systemd/system/${inst}.service.d"
  mkdir -p "$dropdir"
  cat > "$dropdir/10-rnfleet-firstboot.conf" <<'DROPIN'
[Service]
ExecStart=
ExecStart=-/usr/local/sbin/rnfleet-console-entry %I
DROPIN
done
# Optional factory pre-seed: if the payload ships a real enrollment.conf, install
# it so the appliance enrolls UNATTENDED on first boot (no console prompt).
if [ -f "$PAYLOAD_DIR/enrollment.conf" ]; then
  echo "==> Installing factory pre-seed /etc/rnfleet/enrollment.conf"
  install -m 0600 "$PAYLOAD_DIR/enrollment.conf" /etc/rnfleet/enrollment.conf
fi
# Normalise line endings in case the payload was checked out on Windows.
sed -i 's/\r$//' /usr/local/sbin/rnfleet-setup /usr/local/sbin/rnfleet-console-entry /etc/update-motd.d/30-rnfleet
# daemon-reload needs a running systemd; harmless to skip during an offline
# install (curtin in-target chroot) — the first real boot reloads units anyway.
systemctl daemon-reload 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Appliance gating: runtime DISABLED + no identity until enrollment; the
#    first-boot wizard runs on BOTH consoles (video tty1 + serial ttyS0) until
#    the box is enrolled, then each console drops to a normal login.
#    NB: this may run in an offline chroot (autoinstall in-target) where systemd
#    is not running, so we fall back to manipulating the wants symlinks directly.
# ---------------------------------------------------------------------------
WANTS_DIR="/etc/systemd/system/multi-user.target.wants"
GETTY_WANTS="/etc/systemd/system/getty.target.wants"
mkdir -p "$WANTS_DIR" "$GETTY_WANTS"
# Disable the runtime (no identity yet) — offline-safe.
systemctl disable rnfleet-device-runtime.service 2>/dev/null || true
rm -f "$WANTS_DIR/rnfleet-device-runtime.service"
rm -f /etc/rnfleet/device-runtime.env
rm -f /var/lib/rnfleet/.configured
# The wizard rides the gettys now — make sure the legacy single-console unit is
# NOT also enabled (it would fight the gettys for /dev/console = the serial port).
systemctl disable rnfleet-firstboot.service 2>/dev/null || true
rm -f "$WANTS_DIR/rnfleet-firstboot.service" "$GETTY_WANTS/rnfleet-firstboot.service"
# Enable both console gettys — guarantee the wants symlinks even offline. The
# 10-rnfleet-firstboot drop-ins make each getty run the enrollment wizard first.
systemctl enable getty@tty1.service serial-getty@ttyS0.service 2>/dev/null || true
ln -sf /lib/systemd/system/getty@.service        "$GETTY_WANTS/getty@tty1.service"
ln -sf /lib/systemd/system/serial-getty@.service "$GETTY_WANTS/serial-getty@ttyS0.service"

echo "==> RNFleet appliance provisioning complete (unenrolled; wizard armed on tty1 + ttyS0)."
