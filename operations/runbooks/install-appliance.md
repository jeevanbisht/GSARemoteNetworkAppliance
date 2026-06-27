# RNFleet Appliance — Installation Guide (Step by Step)

This guide walks an operator through installing an RNFleet edge appliance, from
hardware/network prep, through OS install and enrollment, to bringing up a live
Microsoft Global Secure Access (GSA) IPSec/BGP tunnel. It also documents the
**network port requirements** the appliance needs.

The appliance is **provider-agnostic** (portable Linux: Node 22 + strongSwan +
FRR). The same runtime and first-boot wizard (`rnfleet-setup`) are used whether
you install from the bare-metal ISO, the Azure image, or onto an existing Ubuntu
box — so the enrollment experience below is identical for all three paths.

---

## 0) Port requirements (read first)

The appliance only ever **dials out**. **No inbound ports are required on the WAN.**
Open the following on any firewall/NSG/proxy between the appliance WAN and the
internet.

### Mandatory — management plane

| Direction | Protocol / Port | Peer | Purpose |
| --- | --- | --- | --- |
| Outbound | **TCP 443 (HTTPS)** | Control-plane URL | Device registration, heartbeat, config pull, telemetry (mTLS/PSK). **Hard requirement.** |
| Outbound | **UDP/TCP 53 (DNS)** | Site/upstream DNS | Resolve control-plane + GSA endpoints |
| Outbound | **UDP 123 (NTP)** | NTP server | Clock sync (required — IPSec/IKE and cert validation are time-sensitive) |

### Required only for a GSA IPSec/BGP tunnel

| Direction | Protocol / Port | Peer | Purpose |
| --- | --- | --- | --- |
| Outbound | **UDP 500 (IKE)** | GSA edge gateway | IKEv2 phase-1 negotiation |
| Outbound | **UDP 4500 (IKE NAT-T / ESP)** | GSA edge gateway | IKEv2 NAT-traversal + ESP-in-UDP (the appliance uses NAT-T) |
| Outbound | **ESP / IP proto 50** | GSA edge gateway | Native ESP — only if NAT-T is not in play (NAT-T/UDP 4500 is the norm) |
| Outbound | **TCP 179 (BGP)** | GSA peer inner IP | BGP session — **runs *inside* the IPSec tunnel**, not exposed on the WAN |

> The appliance is always the **initiator/CPE** (per GSA requirement AR-003), so
> the GSA tunnel ports above only need to be open **outbound**. The remote side
> (Microsoft) is the responder.

### LAN side (served by the appliance to client devices)

If the appliance acts as the LAN default gateway (dual-NIC), it serves DHCP/DNS to
the LAN via `dnsmasq`. These listen **only on the LAN interface**:

| Listener | Protocol / Port | Purpose |
| --- | --- | --- |
| dnsmasq DHCP | UDP 67/68 | Hand out LAN client addresses |
| dnsmasq DNS | UDP/TCP 53 | Resolve for LAN clients |

### Local management (host-only)

| Service | Port | Notes |
| --- | --- | --- |
| Control-plane (self-host) | TCP 4000 | Only if you self-host the CP; on Azure it sits behind 443 |
| Portal (self-host) | TCP 4100 | Only if you self-host the portal; on Azure it sits behind 443 |
| SSH (optional) | TCP 22 | Out-of-band/admin only; restrict to a management network |

> **Tunnel caveat:** when a broad GSA prefix (e.g. `0.0.0.0/0`) is advertised, the
> return path for your admin client's egress IP can be pulled into the tunnel and
> **SSH over the WAN may drop**. Use the platform serial/iDRAC/iLO console for
> in-guest work while a wide-prefix tunnel is up.

---

## 1) Prerequisites

### Hardware

- **x86-64** mini PC / server, UEFI **or** legacy BIOS (hybrid boot supported)
- **~10 GB disk**, **2 GB+ RAM**
- **2 network interfaces**:
  - **WAN** — reaches the internet / control-plane (auto-detected as the interface
    holding the default route; names like `enp1s0`/`eno1` are fine, nothing is
    hardcoded to `eth0`)
  - **LAN** — the client-side network the appliance routes/serves

### Enrollment values (have these ready)

| Value | Env var | Notes |
| --- | --- | --- |
| Control-plane URL | `CONTROL_PLANE_URL` | e.g. `https://rnfleet-cp-a7nzwz.azurewebsites.net` (no trailing slash) |
| Fleet PSK | `FLEET_PSK` | Must match the control-plane's `FLEET_PSK` or registration returns `401` |
| Device ID | `DEVICE_ID` | **Must be unique** in the fleet (e.g. `device-007`); auto-derived from `/etc/machine-id` if not set |
| Site ID | `SITE_ID` | Free-form grouping label (e.g. `lab-site`) |
| Tunnel PSK (GSA only) | `TUNNEL_PSK` | IPSec key for the device link; can also be pushed from the portal later (portal value wins) |

### Connectivity preflight (run from the appliance network)

```bash
curl -fsS https://<control-plane-host>/health && echo OK
```

You should get `200`/`OK`. If it fails, fix **outbound 443** egress before
continuing — that is the appliance's only hard network requirement.

---

## 2) Choose an install path

| Target | How | When to use |
| --- | --- | --- |
| **Bare metal / generic VM** | Autoinstall ISO (`infra/bare-metal/iso/`) | Physical appliance or any hypervisor — zero-touch wipe-and-install |
| **Azure VM** | Packer image (`infra/cloud/azure/bootstrap/image/`) | Azure-hosted appliance |
| **Existing Ubuntu box** | `provision-appliance.sh` / manual runbook | You can't rebuild the image (see `operations/runbooks/onboard-manual-vm-to-control-plane.md`) |

All three install the **same** runtime + `rnfleet-setup` wizard. The steps below
cover the **bare-metal ISO** (the most general path) and the **existing-box**
path.

---

## 3A) Install via the bare-metal ISO (recommended)

### Step 1 — Build the ISO

**Windows + Docker Desktop:**

```powershell
cd infra\bare-metal\iso
.\build-appliance-iso.ps1
# or reuse an ISO you already downloaded:
.\build-appliance-iso.ps1 -SrcIso D:\iso\ubuntu-24.04.2-live-server-amd64.iso -OutDir D:\images
```

**Linux / CI:**

```bash
cd infra/bare-metal/iso
sudo OUT_ISO=$PWD/out/rnfleet-appliance.iso bash build-appliance-iso.sh
```

Output (default): `<repo>\..\dist\rnfleet-appliance-ubuntu-2404.iso`. The first run
caches the ~3 GB Ubuntu Server ISO in `dist\iso-cache\`.

> **Before building for production:** change the default login. Edit
> `autoinstall/user-data` and replace the `identity.password` hash
> (`openssl passwd -6` / `mkpasswd --method=SHA-512`), or switch to SSH keys
> (`ssh.authorized-keys`, `allow-pw: false`). The shipped default is
> `rnfleet` / `rnfleet`.

### Step 2 — Write the ISO to boot media

- USB: Rufus / balenaEtcher, or
  `dd if=rnfleet-appliance-ubuntu-2404.iso of=/dev/sdX bs=4M status=progress`
- Or attach as virtual media (iDRAC/iLO/IPMI) or to a VM.

> ⚠️ The install is **unattended and wipes the disk**. Boot it only on hardware
> you intend to convert into an appliance.

### Step 3 — Boot and let it install

The target installs Ubuntu 24.04 LTS (whole-disk), bakes in Node 22, strongSwan
(swanctl/vici), FRR (BGP on), IP forwarding, the **device runtime** (installed but
**disabled** — no identity yet), and the first-boot wizard, then reboots. Each box
gets its own `/etc/machine-id`, so the Device ID is unique per appliance.

### Step 4 — First-boot enrollment

On first boot, `rnfleet-setup` runs on **both** the video console (tty1) and the
serial port (ttyS0). It prints a **Network interfaces** summary (per-NIC
IPv4/subnet, MAC, gateway, DNS), then prompts for:

- Control-plane URL
- Device ID (auto-filled)
- Site ID
- Enrollment key (fleet PSK)
- Optional IPSec tunnel PSK (or push it later from the portal)

The runtime then enables itself and the device comes online.

#### Optional: unattended / fleet enrollment (no prompt)

Pre-seed `/etc/rnfleet/enrollment.conf` (see `enrollment.conf.example` baked into
the image) before first boot, or bake values into `user-data`. With a valid
`FLEET_PSK` present the wizard enrolls silently and starts the runtime.

To **show the wizard pre-filled** for a guided lab install, add
`FIRSTBOOT_INTERACTIVE=true` to the pre-seed — the wizard appears with every field
defaulted, asking `Use "X"? [Y/n]` per field.

---

## 3B) Install onto an existing Ubuntu box

On Ubuntu 22.04 / 24.04, copy the repo source tree to the box and run the
provisioner (it installs the tunnel stack, Node 22, the runtime, and the wizard):

```bash
sudo bash infra/bare-metal/iso/provision-appliance.sh
```

Then enroll:

```bash
sudo rnfleet-setup
```

For the full manual variant (bundle/`scp`, per-step installer, env file), follow
the companion runbook `onboard-manual-vm-to-control-plane.md`.

---

## 4) Verify the device is online

**REST (from anywhere with the PSK):**

```bash
curl -fsS -H "x-fleet-psk: <FLEET_PSK>" \
  https://<control-plane-host>/api/v1/portal/devices \
  | jq '.devices[] | select(.deviceId=="<DEVICE_ID>")'
```

Expect `status: "online"` with reported WAN/LAN IPs.

**Portal:** open the portal URL — the device appears as **online** within ~10–20s.

---

## 5) Push and verify a GSA tunnel (optional)

### Push from the portal

1. Open the **Tunnel & BGP** form.
2. Paste the Entra remote-network **connectivity JSON** → **Parse & Fill**.
3. Pick **IKE Phase 1 / Phase 2** combinations, enter the **PSK**, set local
   networks (e.g. `10.0.1.0/24`), select the device → **Push All Config**.
4. The stepper runs **Submit → fetch/apply → IPSec SA → BGP** and turns green once
   the device reports tunnel up + BGP established.

### Verify on the appliance (don't rely only on the portal)

```bash
# IPSec/IKE SAs (expect ESTABLISHED + INSTALLED, ESP over UDP 4500 NAT-T)
sudo swanctl --list-sas | grep -E 'ESTABLISHED|INSTALLED'

# BGP session + learned prefixes (expect Established, non-zero PfxRcd)
sudo vtysh -c "show bgp summary"

# Data-plane egress proof — should resolve via the ipsec-gsa interface
ip route get 1.1.1.1
curl -s https://api.ipify.org; echo   # returns the GSA edge IP when steering works
```

One-shot health snapshot:

```bash
echo "== IPSec =="; sudo swanctl --list-sas | grep -E 'ESTABLISHED|INSTALLED'
echo "== BGP =="; sudo vtysh -c "show bgp summary"
echo "== Egress =="; ip route get 1.1.1.1
WAN=$(ip route show default | awk '{print $5; exit}')
echo "  through tunnel : $(curl -s https://api.ipify.org)"
echo "  local WAN ($WAN): $(curl -s --interface "$WAN" https://api.ipify.org)"
```

---

## 6) Managing the appliance after enrollment

**Re-run the wizard (recommended):**

```bash
sudo rnfleet-setup --force      # re-runs interactively, pre-filled with current values
```

(Without `--force`, an already-enrolled box just reports status and exits.)

**Edit config directly (one-off tweak):**

```bash
sudo nano /etc/rnfleet/device-runtime.env       # mode 0600
sudo systemctl restart rnfleet-device-runtime.service
```

`device-runtime.env` holds `CONTROL_PLANE_URL`, `FLEET_PSK`, `TUNNEL_PSK`,
`DEVICE_ID`, `SITE_ID`, `LOOP_SECONDS`.

**Check status / logs:**

```bash
systemctl status rnfleet-device-runtime.service
journalctl -u rnfleet-device-runtime.service -f
```

> Tunnel/IPSec settings (PSK, GSA endpoint, IKE params) are normally **pushed from
> the portal** and override local values — change those in the portal, not the
> local env file.

---

## 7) Troubleshooting

| Symptom | Cause / Fix |
| --- | --- |
| `401 Unauthorized` on register | Device `FLEET_PSK` ≠ control-plane `FLEET_PSK`. Fix env, restart. |
| Device never appears | Check **outbound 443** (`curl .../health`); check `journalctl`; confirm `CONTROL_PLANE_URL` has no trailing slash/typo. |
| Tunnel up but **SSH drops** | Expected when a broad GSA prefix covers your admin egress IP — return path pulled into the tunnel. Use serial/out-of-band console. |
| IPSec never establishes | Verify **outbound UDP 500 + UDP 4500** are open to the GSA edge; verify NTP/clock sync; confirm PSK + IKE phase-1/2 match the Entra device link. |
| BGP flaps (established → connecting) | Ensure current runtime (pins the GSA endpoint `/32` to the WAN underlay so ESP can't recurse into the tunnel). Reinstall if source predates that fix. |
| `node: not found` / service flaps | Node 22 missing — re-run the installer; `node --version` should be `v22.x`. |

---

## Related docs

Paths are relative to the repository root (`RNFleetManager/`):

- `infra/bare-metal/iso/README.md` — ISO build details + GSA/BGP verification
- `operations/runbooks/onboard-manual-vm-to-control-plane.md` — manual onboarding
- `docs/requirements/appliance-requirements-gsa-remote-network.md` — GSA CPE spec (AR-001…AR-010)
- `sample-config.md` — real Entra connectivity JSON + architecture diagram
