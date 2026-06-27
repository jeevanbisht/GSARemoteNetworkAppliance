# Minimal RNFleet appliance image (golden image)

Builds a **minimal, bootable** RNFleet edge-appliance image from scratch with
`mmdebstrap` (Debian bookworm) instead of a full Ubuntu install. The result is a
compressed **qcow2 (~0.7 GB)** that boots on any hypervisor / bare-metal with no
local dependency — roughly **10x smaller** than the full-OS golden VHDX (~6 GB).
It also converts to a Hyper-V **VHDX** (see below) and doubles as a **LAN
default-gateway router** (`LAN → appliance → GSA`).

It bakes the exact same stack as `infra/bare-metal/iso/provision-appliance.sh`
(strongSwan/swanctl + charon-systemd, FRR/BGP, Node 22, the device runtime, the
first-boot enrollment wizard, and the **LAN-router** role: dnsmasq DHCP/DNS +
nftables NAT), so a minimal-image appliance behaves identically to an ISO install.

## Why Debian-minimal (not Alpine)
The runtime depends on **systemd** units, **glibc**, and Debian/Ubuntu package
names (`strongswan-swanctl`, `charon-systemd`, `frr`, `nodejs`). Alpine's OpenRC +
musl would require rewriting every unit and config. Debian-minimal keeps the whole
stack working unchanged while still landing ~1.1 GB on disk / ~0.5 GB compressed.

## Build (runs entirely in Docker — no host tooling needed)
Requires Docker with privileged containers (loop + mount). From the repo root:

```powershell
$repo = (Resolve-Path .).Path
$out  = "$repo\..\dist\golden-min"   # any writable output dir
New-Item -ItemType Directory -Force $out | Out-Null
docker run --rm --privileged -v "$repo`:/repo:ro" -v "$out`:/out" `
  debian:bookworm-slim bash /repo/infra/bare-metal/golden-image/build-min-appliance.sh
```

Output: `$out/rnfleet-appliance-min.qcow2`.

### Convert to Hyper-V VHDX (optional)
For a Hyper-V Gen2 VM, convert the qcow2 to a dynamic VHDX (also runs in Docker —
no host `qemu-img` needed):

```powershell
docker run --rm -v "$out`:/out" debian:bookworm-slim bash -c `
  "apt-get update -qq && apt-get install -y -qq qemu-utils && cd /out && `
   qemu-img convert -O vhdx -o subformat=dynamic rnfleet-appliance-min.qcow2 rnfleet-appliance-min.vhdx"
```

Output: `$out/rnfleet-appliance-min.vhdx` (~2 GB dynamic). Create a **Gen2** VM with
**Secure Boot off** and a COM port for the serial console.

### Resuming after a failure
`build-min-appliance.sh` keeps the intermediate raw image (with the debootstrapped
rootfs) in the output dir. If a late stage fails (grub, provision), re-run just the
fast tail without repeating mmdebstrap:

```powershell
docker run --rm --privileged -v "$repo`:/repo:ro" -v "$out`:/out" `
  debian:bookworm-slim bash /repo/infra/bare-metal/golden-image/finish-min-appliance.sh
```

## Image layout / boot
- **GPT** with BIOS-boot (ef02), **ESP** (fat32), and **ext4 root**.
- GRUB installed for **EFI (removable `/EFI/BOOT/BOOTX64.EFI`, no NVRAM entry)**
  *and* **BIOS (i386-pc)** — boots on Hyper-V Gen2, Azure Gen2, KVM/OVMF, AWS UEFI,
  and legacy BIOS/bare-metal alike.
- Kernel `root=` pinned by **UUID** (so it boots regardless of device naming).
- **Serial console** on `ttyS0,115200` + local tty `tty1`. The first-boot wizard is
  shown on **both** (see below); `serial-getty@ttyS0` and `getty@tty1` enabled.
- **DNS**: `/etc/resolv.conf` ships as a **regular file** with public bootstrap
  resolvers and is overwritten by ifupdown/dhclient with the DHCP-provided
  nameservers at runtime. It is **not** a symlink to systemd-resolved's stub —
  systemd-resolved is not installed, so a stub symlink would dangle and break DNS.
- WAN = `eth0` via DHCP (`net.ifnames=0` for predictable `ethN`), brought up with
  **`allow-hotplug`** (non-blocking boot). The LAN-router service claims a second
  NIC if present and no-ops on single-NIC hosts (`LAN → appliance → GSA`).

## First boot
The appliance comes up **unenrolled**: the device runtime is disabled and the
enrollment wizard `rnfleet-setup` runs on the console. It is presented on **both
the video console (`tty1`) and the serial port (`ttyS0`)** — a getty wrapper
(`rnfleet-console-entry`) runs the wizard on whichever console until the appliance
is enrolled, then drops to a normal login. (This is needed because the kernel
cmdline makes `ttyS0` the `/dev/console`, so a single-console wizard would only
appear on serial.)

Before the prompts the wizard prints a **Network interfaces** summary — each NIC's
link state, IPv4 address/subnet (CIDR) and MAC, plus the default gateway and DNS
servers — so you can confirm WAN/LAN addressing before enrolling.

Drop a `/etc/rnfleet/enrollment.conf` pre-seed for unattended enrollment. See
`apps/device-runtime/packaging/firstboot/enrollment.conf.example`.

Default login: `rnfleet` / `rnfleet` (sudo). **Change this for production.**

## Verified
The build self-verifies the rootfs (services enabled, runtime gated, kernel/grub
present) and a QEMU boot smoke test confirms GRUB → kernel → UUID root mount →
systemd → `rnfleet-lan-router` → the first-boot enrollment wizard. Validated live
on a **Hyper-V Gen2 VM** (2026-06-23): converted to VHDX, booted, the wizard
appeared on both consoles with the Network interfaces panel, enrolled, and the
device came **online** on the control-plane. See `status.md` → "Minimal Golden
Image (qcow2/VHDX) + LAN Router + Dual-Console Wizard".
