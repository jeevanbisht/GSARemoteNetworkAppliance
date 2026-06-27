# RNFleet Bare-Metal Appliance ISO

> **Status: ✅ Validated (2026-06-23)** — built a 3.17 GB hybrid BIOS+UEFI ISO and
> tested it live on a Hyper-V Gen2 VM: unattended install → auto-enroll → device
> online on the control-plane → **live GSA tunnel off Azure** (IPSec ESTABLISHED,
> BGP Established with 584 prefixes, internet egress via the GSA edge). See
> `status.md` → "Bare-Metal Appliance ISO + Hyper-V" for the full run.

Build a **hands-off Ubuntu 24.04 installer** that turns any physical server (or
VM) into an RNFleet edge appliance — the bare-metal equivalent of the Azure
appliance image. Boot it, let it install unattended, and on first boot the
console enrollment wizard (`rnfleet-setup`) asks for the minimum config.

This tree is **provider-agnostic** — nothing here is Azure-specific. The same
runtime, tunnel stack, and first-boot wizard used by the Azure image are baked in.

## What the ISO produces

A server installed with:

- Ubuntu 24.04 LTS Server (whole-disk, UEFI **or** BIOS — hybrid boot)
- Node.js 22, **strongSwan (swanctl/vici)**, **FRR** (BGP daemon on), IP forwarding
- The RNFleet **device runtime** (installed, but **disabled** — no identity yet)
- The **first-boot enrollment wizard** `rnfleet-setup` (runs on the console until
  the appliance is enrolled — on **both** the video console and the serial port),
  plus the login status banner (MOTD). Before the prompts it shows a **Network
  interfaces** summary (per-NIC IPv4 address/subnet, MAC, default gateway, DNS).
- A default admin login `rnfleet` / `rnfleet` (**change this** — see below)

Each physical box gets its own `/etc/machine-id` at install time, so the
auto-generated Device ID is unique per appliance.

## Files

| File | Purpose |
| --- | --- |
| `autoinstall/user-data` | Ubuntu autoinstall (Subiquity) config — the unattended install recipe |
| `autoinstall/meta-data` | NoCloud meta-data (instance id) |
| `provision-appliance.sh` | In-target provisioner (tunnel stack + runtime + wizard). Reusable standalone. |
| `build-appliance-iso.sh` | Remaster script (Linux/Docker): injects autoinstall + payload, repacks bootable ISO |
| `build-appliance-iso.ps1` | Windows wrapper — runs the build in an `ubuntu:24.04` Docker container |

## Build (Windows + Docker Desktop)

```powershell
cd infra\bare-metal\iso
.\build-appliance-iso.ps1
# or reuse an ISO you already downloaded:
.\build-appliance-iso.ps1 -SrcIso D:\iso\ubuntu-24.04.2-live-server-amd64.iso -OutDir D:\images
```

Output: `<repo>\..\dist\rnfleet-appliance-ubuntu-2404.iso` (default). The first run
downloads the ~3 GB Ubuntu Server ISO into `dist\iso-cache\` and reuses it after.

## Build (Linux / CI directly)

```bash
cd infra/bare-metal/iso
sudo OUT_ISO=$PWD/out/rnfleet-appliance.iso bash build-appliance-iso.sh
```

Requires `xorriso`, `p7zip-full`, `curl` (the script apt-installs them when run as
root).

## Deploy to hardware

1. **Write the ISO to USB** (e.g. with [Rufus](https://rufus.ie), balenaEtcher, or
   `dd if=rnfleet-appliance-ubuntu-2404.iso of=/dev/sdX bs=4M status=progress`),
   or attach it as virtual media (iDRAC/iLO/IPMI) or to a VM.
2. **Boot the target from the ISO.** The install is **unattended and wipes the
   disk** — boot only on hardware you intend to convert into an appliance.
3. The server installs Ubuntu, bakes in the runtime + wizard, and reboots.
4. **First boot:** `rnfleet-setup` runs on the console (video **and** serial) and,
   after printing a Network interfaces summary (IP/subnet/gateway/DNS), prompts for:
   - Control-plane URL · Device ID (auto) · Site ID · Enrollment key (fleet PSK)
   - optional IPSec tunnel PSK (can also be pushed later from the portal)
5. The device appears online in the portal; push its GSA tunnel config when ready.

### Unattended / fleet enrollment (no console prompt)

Pre-seed `/etc/rnfleet/enrollment.conf` (see `enrollment.conf.example` baked into
the image) before first boot, or bake values into `user-data`. With a valid
`FLEET_PSK` present the wizard enrolls silently and starts the runtime.

To **show the wizard pre-filled** (instead of silent enrollment) — handy for a
guided lab install where you want to review/override each value — add
`FIRSTBOOT_INTERACTIVE=true` to the pre-seed. The wizard then appears on the
console with every field defaulted from the pre-seed; press Enter to accept each
(it asks `Use "X"? [Y/n]` per field) or type an override, then confirm.

## Managing the appliance after enrollment

Once a device is enrolled you can change its settings at any time.

**Re-run the wizard (recommended):**

```bash
sudo rnfleet-setup --force
```

Re-runs the full interactive wizard pre-filled with the **current** values as
defaults. Press Enter to keep each (or type a new value), confirm per field, and
it rewrites the config and restarts the runtime. Without `--force`, running
`sudo rnfleet-setup` on an already-enrolled appliance just reports its status and
exits (guards against accidental re-enrollment).

**Edit the config directly (one-off tweak):**

```bash
sudo nano /etc/rnfleet/device-runtime.env     # mode 0600
sudo systemctl restart rnfleet-device-runtime.service
```

`/etc/rnfleet/device-runtime.env` holds `CONTROL_PLANE_URL`, `FLEET_PSK`,
`TUNNEL_PSK`, `DEVICE_ID`, `SITE_ID`, and `LOOP_SECONDS`. The runtime re-reads it
on start.

**Verify the change took effect:**

```bash
systemctl status rnfleet-device-runtime.service
journalctl -u rnfleet-device-runtime.service -f
```

> **Tunnel / IPSec settings** (PSK, GSA endpoint, IKE parameters) are normally
> **pushed from the portal/control-plane** and override local values at runtime —
> change those in the portal rather than the local env file.

## Verifying the GSA tunnel and BGP

After the portal pushes a GSA tunnel config, confirm the data path on the
appliance itself (don't rely only on the portal's reported status). These are the
exact checks used to validate a live device.

**1. IPSec/IKE security associations — strongSwan (swanctl/vici):**

```bash
sudo swanctl --list-sas
```

Look for the connection (e.g. `rnfleet-gsa`) **ESTABLISHED** with an IKEv2 SA to
the GSA gateway on UDP **4500** (NAT-T) and an installed CHILD_SA
(`INSTALLED, TUNNEL`, ESP `AES_GCM_16-256`). A quick liveness check:

```bash
sudo swanctl --list-sas | grep -E 'ESTABLISHED|INSTALLED'
```

**2. BGP session and learned routes — FRR (vtysh):**

```bash
sudo vtysh -c "show bgp summary"
```

The GSA neighbor (the tunnel's remote inner IP) should show state **Established**
with a non-zero **PfxRcd** (prefixes received). Then:

```bash
sudo vtysh -c "show ip bgp neighbors"        # detailed neighbor/AS info
sudo vtysh -c "show ip bgp"                   # the BGP RIB (learned prefixes)
sudo vtysh -c "show ip route bgp"             # BGP routes installed into the kernel
```

**3. Kernel FIB + data-plane egress — confirm traffic actually uses the tunnel:**

```bash
ip route get 1.1.1.1            # should resolve via the ipsec-gsa interface
```

"What's my IP" — your public egress address as the internet sees it. With the GSA
tunnel up this returns the **GSA edge IP**, not your local WAN's public IP:

```bash
curl -s https://ifconfig.me; echo            # or:
curl -s https://api.ipify.org; echo          # or:
curl -s https://checkip.amazonaws.com        # (any echo-IP service)
```

To prove the tunnel is doing the steering, compare egress **through** the tunnel
vs. your local WAN's real public IP (force the query out the WAN interface):

```bash
echo "egress (default path) : $(curl -s https://api.ipify.org)"
WAN=$(ip route show default | awk '{print $5; exit}')
echo "local WAN public IP   : $(curl -s --interface "$WAN" https://api.ipify.org)"
```

If the egress IP is the GSA edge and `ip route get` points at the tunnel
interface, the device is steering internet traffic through Global Secure Access.

**One-shot health snapshot:**

```bash
echo "== IPSec =="; sudo swanctl --list-sas | grep -E 'ESTABLISHED|INSTALLED'
echo "== BGP =="; sudo vtysh -c "show bgp summary"
echo "== Egress =="; ip route get 1.1.1.1
WAN=$(ip route show default | awk '{print $5; exit}')
echo "  through tunnel : $(curl -s https://api.ipify.org)"
echo "  local WAN ($WAN): $(curl -s --interface "$WAN" https://api.ipify.org)"
```

> **No tunnel yet?** A freshly enrolled device has no tunnel until the portal
> pushes one — `swanctl --list-sas` will be empty and BGP will have no GSA
> neighbor. Push the GSA tunnel config from the portal first, then re-run these.

## Hardware requirements

- **2 network interfaces**: WAN (internet / reaches the control-plane) and LAN.
  The WAN is auto-detected as the interface holding the default route — interface
  names like `enp1s0`/`eno1` are fine; nothing is hardcoded to `eth0`.
- Outbound **HTTPS (443)** to the control-plane. No inbound ports required.
- x86-64, UEFI or legacy BIOS, ~10 GB disk, 2 GB+ RAM.

## Security notes

- **Change the default password.** Edit `autoinstall/user-data` and replace the
  `identity.password` hash (`openssl passwd -6` or `mkpasswd --method=SHA-512`),
  or switch to SSH keys (`ssh.authorized-keys`, set `allow-pw: false`).
- The shared fleet PSK is for bootstrap/validation; move to per-device identity in
  production.

## Relationship to the other build paths

| Target | Build |
| --- | --- |
| Azure VM image | `infra/cloud/azure/bootstrap/image/` (Packer, azure-arm) |
| Bare metal / generic VM | **this tree** (autoinstall ISO) |
| Existing Ubuntu box | `operations/runbooks/onboard-manual-vm-to-control-plane.md` (or run `provision-appliance.sh` directly) |

All three install the **same** runtime + `rnfleet-setup` wizard, so the enrollment
experience is identical regardless of how the appliance was provisioned.
