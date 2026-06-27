# Runbook: Onboard a Manually-Created VM to the Control-Plane

This guide connects a Linux machine you created yourself (any cloud, bare metal,
Raspberry Pi, etc.) to your RNFleet **control-plane (CP)** so it appears as an
online device in the portal and can receive config (including a GSA IPSec/BGP
tunnel).

> The runtime is **device- and provider-agnostic** — nothing here is Azure-specific.
> The only hard requirement is **outbound HTTPS (443) to the control-plane**.

> **Prefer a zero-touch appliance?** If you control the image, build the prebaked
> **RNFleet appliance image** instead (`infra/cloud/azure/bootstrap/image/`). It
> ships Node, strongSwan, FRR and the runtime preinstalled, and a first-boot
> wizard (`rnfleet-setup`) that prompts the operator for the same values below —
> no manual install steps. Use this manual runbook when you cannot rebuild the
> VM image.

---

## What you need before you start

| Item | Current value (confirm before use) | Notes |
| --- | --- | --- |
| Control-plane URL | `https://rnfleet-cp-a7nzwz.azurewebsites.net` | `CONTROL_PLANE_URL` |
| Fleet PSK (CP auth) | `dev-fleet-psk` | `FLEET_PSK` — must match the CP's `FLEET_PSK` |
| A unique Device ID | e.g. `device-007` | `DEVICE_ID` — **must be unique** in the fleet |
| Site ID | e.g. `lab-site` | `SITE_ID` — free-form grouping label |
| Tunnel PSK (only for GSA) | e.g. `microsoft12345` | `TUNNEL_PSK` — IPSec key; can also be pushed from the portal |

**Target OS:** Ubuntu 22.04 / 24.04 (the install script uses `apt`). Other distros
work but you'll adapt the package steps.

**Connectivity check (run on the VM):**
```bash
curl -fsS https://rnfleet-cp-a7nzwz.azurewebsites.net/health && echo OK
```
You should get `200`/`OK`. If this fails, fix egress (firewall/NSG/proxy) first —
the device only needs **outbound** 443; no inbound ports are required.

---

## Step 1 — Get the runtime source onto the VM

The agent is a Node monorepo (`apps/device-runtime` + the `@rnfleet/contracts`
workspace), so copy the **repo source tree** (not just one folder).

### Option A — Bundle from your workstation and `scp` (recommended)

Run on your **workstation** (PowerShell), from the repo root
`C:\AIProjects\jb\Inspire\RNAppliance\RNFleetManager`:

```powershell
$repo = "C:\AIProjects\jb\Inspire\RNAppliance\RNFleetManager"
$out  = "$env:TEMP\rnfleet-src.tar.gz"
# Bundle the source, excluding node_modules, .git, and the CP local data store.
tar -czf $out -C $repo `
  --exclude="node_modules" --exclude=".git" `
  --exclude="apps/control-plane/data" `
  package.json apps packages

# Copy the bundle + packaging files to the VM (replace user@VM_IP).
scp $out user@VM_IP:/tmp/rnfleet-src.tar.gz
```

Then on the **VM**:
```bash
sudo mkdir -p /tmp/rnfleet-src /tmp/rnfleet-packaging
sudo tar -xzf /tmp/rnfleet-src.tar.gz -C /tmp/rnfleet-src
# Stage the packaging files the installer expects:
sudo cp /tmp/rnfleet-src/apps/device-runtime/packaging/device-runtime.env.example /tmp/rnfleet-packaging/
sudo cp /tmp/rnfleet-src/apps/device-runtime/packaging/systemd/rnfleet-device-runtime.service /tmp/rnfleet-packaging/
```

### Option B — `git clone` on the VM
If the VM can reach your Git remote (and you have credentials):
```bash
git clone https://github.com/jeevanbisht/RNFleetManager.git /tmp/rnfleet-src
sudo mkdir -p /tmp/rnfleet-packaging
sudo cp /tmp/rnfleet-src/apps/device-runtime/packaging/device-runtime.env.example /tmp/rnfleet-packaging/
sudo cp /tmp/rnfleet-src/apps/device-runtime/packaging/systemd/rnfleet-device-runtime.service /tmp/rnfleet-packaging/
```

---

## Step 2 — (Only for a GSA tunnel) install strongSwan + FRR

Registration and heartbeat need **only Node** (installed in Step 3). Install these
**now** if this device will run a GSA IPSec/BGP tunnel:

```bash
sudo apt-get update
sudo apt-get install -y strongswan strongswan-swanctl charon-systemd frr frr-pythontools

# Enable the BGP daemon (FRR ships with it off by default):
sudo sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons
sudo systemctl enable --now frr
sudo systemctl enable --now strongswan || sudo systemctl enable --now strongswan-starter
```

> Skip this step for a "registration-only" device; you can add it later before
> pushing a tunnel config.

---

## Step 3 — Install the runtime

The repo ships an installer that installs Node 22 (if missing), creates
`/opt/rnfleet`, runs `npm install`, and installs the systemd unit:

```bash
sudo bash /tmp/rnfleet-src/apps/device-runtime/packaging/install-device-runtime.sh
```

What it does:
- installs **Node 22** from NodeSource if not already present,
- copies the source to **`/opt/rnfleet`** and runs `npm install --omit=dev --workspaces`,
- seeds **`/etc/rnfleet/device-runtime.env`** from the example (only if absent),
- installs and enables **`rnfleet-device-runtime.service`**.

---

## Step 4 — Configure the device env

Edit `/etc/rnfleet/device-runtime.env` and set the values for **this** device:

```bash
sudo tee /etc/rnfleet/device-runtime.env >/dev/null <<'EOF'
CONTROL_PLANE_URL=https://rnfleet-cp-a7nzwz.azurewebsites.net
FLEET_PSK=dev-fleet-psk
TUNNEL_PSK=microsoft12345
DEVICE_ID=device-007
SITE_ID=lab-site
LOOP_SECONDS=10
EOF
```

Key points:
- **`DEVICE_ID` must be unique** — reusing an existing ID collides with that device.
- **`FLEET_PSK` must equal the CP's `FLEET_PSK`** (auth header `x-fleet-psk`), or
  registration returns `401`.
- `TUNNEL_PSK` is the IPSec key; you can leave it as a placeholder and push the
  real PSK from the portal later (the portal's PSK takes precedence).

---

## Step 5 — Start the agent

```bash
sudo systemctl restart rnfleet-device-runtime.service
systemctl is-active rnfleet-device-runtime.service     # -> active
journalctl -u rnfleet-device-runtime.service -n 30 --no-pager
```

Expected log line:
```
device-runtime started for device-007; control-plane=https://rnfleet-cp-a7nzwz.azurewebsites.net
```
The agent registers immediately, then heartbeats every `LOOP_SECONDS` seconds.

---

## Step 6 — Verify on the control-plane / portal

**Via REST** (from anywhere with the PSK):
```bash
curl -fsS -H "x-fleet-psk: dev-fleet-psk" \
  https://rnfleet-cp-a7nzwz.azurewebsites.net/api/v1/portal/devices | jq '.devices[] | select(.deviceId=="device-007")'
```
You should see `status: "online"` and the reported WAN/LAN IPs.

**Via portal:** open <https://rnfleet-portal-a7nzwz.azurewebsites.net> — the device
appears in the device table as **online** within ~10–20s.

---

## Step 7 — (Optional) Push a GSA tunnel from the portal

Once the device is online and strongSwan/FRR are installed (Step 2):

1. In the portal, open the **Tunnel & BGP** form.
2. Paste the Entra remote-network **connectivity JSON** and click **Parse & Fill**.
3. Pick **IKE Phase 1 / Phase 2 combinations**, enter the **PSK**, set local
   networks (e.g. `10.0.1.0/24`), select your device, and click **Push All Config**.
4. The multi-step progress stepper runs **Submit → fetch/apply → IPSec SA → BGP**
   and turns green once the device reports the tunnel up and BGP established.

---

## Troubleshooting

| Symptom | Cause / Fix |
| --- | --- |
| `401 Unauthorized` on register | `FLEET_PSK` on the device ≠ the CP's `FLEET_PSK`. Fix the env value and restart. |
| Device never appears | Check egress 443 to the CP (`curl .../health`); check `journalctl` for errors; confirm `CONTROL_PLANE_URL` has no trailing slash/typo. |
| `@rnfleet/contracts` not found at start | Source wasn't copied as a full monorepo. Re-bundle including `package.json`, `apps/`, **and** `packages/`, then re-run the installer so `npm install --workspaces` links the workspace. |
| Service flaps / `node: not found` | Node 22 missing. Re-run the installer or `node --version` should be `v22.x`. |
| Tunnel comes up but **SSH drops** | Expected for broad GSA prefixes that cover your admin client's egress IP — the return path is pulled into the tunnel. Use the cloud serial console / out-of-band access for in-guest work while the tunnel is up. |
| BGP **flaps** (established → connecting) | Ensure you're on the current runtime: it pins the GSA endpoint `/32` to the WAN underlay so encrypted ESP can't recurse into the tunnel. Re-bundle/reinstall if your source predates that fix. |

---

## Notes

- **No inbound ports** are needed on the device — it always dials out to the CP.
- The agent is **idempotent and self-healing**: it reconciles desired config each
  loop and reverts a tunnel that breaks management connectivity.
- **After a control-plane redeploy/restart, re-push device configs** — the CP's
  file store resets to baseline, which can drop a live tunnel until the real config
  is pushed again.
- To remove a device later: use the portal's **Remove** button (or
  `DELETE /api/v1/portal/devices/<id>`), then stop the service on the box:
  `sudo systemctl disable --now rnfleet-device-runtime.service`.
