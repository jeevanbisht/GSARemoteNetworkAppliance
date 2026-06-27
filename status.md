# RNFleetManager Status Tracker

**Last Updated**: 2026-06-23 21:40 UTC-7  
**Project Phase**: Phase 6 Validated ✅ — IPSec + BGP Integration (strongSwan + FRR + Portal BGP UI ✅; live GSA tunnels on device-005 + device-006 ✅ **ESTABLISHED end-to-end**, split-tunnel data plane validated; device-006 = clean-deploy regression proof + **full portal-driven config (PSK + IKE combos + multi-step progress) validated end-to-end via Playwright**, recursive-routing flap fixed) · **Bare-metal appliance ISO + Hyper-V validated ✅** (provider-agnostic install → unattended enroll → live GSA tunnel/BGP off Azure) · **appliance branding + interactive first-boot wizard** (ASCII logo, `FIRSTBOOT_INTERACTIVE`, per-field Y/n confirmation) · **Minimal golden image (~0.7 GB qcow2 / VHDX) + LAN-router + dual-console wizard with NIC summary, validated on Hyper-V Gen2** (online on control-plane; DNS + slow-boot + `set -e` bugs fixed) · **Azure Gen2 VHD image tooling** (publish the same golden image to Azure via fixed-VHD convert + `az`; provider-neutral build hooks)

---

## 🎯 Executive Summary

RNFleetManager MVP is **fully validated end-to-end**. Phase 6 IPSec + BGP integration is **validated end-to-end**: the tunnel agent generates real strongSwan (swanctl/vici) and FRR config, and two live devices (`device-005`, `device-006`) have each established an IPSec SA and eBGP session to a Microsoft GSA remote network — receiving and installing GSA-advertised prefixes in route-based (`ipsec-gsa`) split-tunnel mode. `device-006` is a **clean deploy that proved the fixed runtime brings the tunnel up automatically with no manual debugging**. The portal has a full Tunnel & BGP config form (with Entra Graph API JSON import) and a live BGP column. Fleet has 4 devices online (`device-001` to `device-004`) in westus3 plus the `device-005` and `device-006` GSA test appliances in westus2.

### Device-005 — Live GSA Tunnel Test (✅ ESTABLISHED, updated 2026-06-22)
- **Subscription**: `3b328940-6e2a-4b01-bcff-d2c8cfa0da1d` (Visual Studio Enterprise, `jeevanbhotmail.onmicrosoft.com` tenant) — **separate from the westus3 dev fleet**, proving cloud/sub portability.
- **RG / Region**: `RN1` / **westus2**.
- **VM**: `rnfleet-device-005`, Ubuntu 24.04, Standard_D2s_v5. Public IP `4.246.81.122`, WAN `eth0`=10.0.0.4, LAN `eth1`=10.0.1.4 (dual-NIC).
- **Provisioning**: portable **cloud-init** (no custom image, no inbound dependency) — embedded device-runtime + contracts (gzip/base64), installs Node 22 + strongSwan/swanctl + FRR, starts systemd runtime. Registered as `device-005`, heartbeating.
- **Tunnel config** (from Entra remote network `NewLink1` / link `Link1`, config v32):
  - GSA: endpoint `20.150.156.174`, ASN `65476`, BGP `192.168.1.2`, region westUS3
  - Peer: endpoint `4.246.81.122`, ASN `65005`, BGP `192.168.1.1`, localNetworks `10.0.1.0/24`
  - IPSec/IKE custom policy: IKE AES256/SHA384/DHGroup14 (P1 Combo 7); ESP GCMAES256/PFS None (P2 Combo 1); SA 3600s
  - PSK `microsoft12345` (set in `/etc/rnfleet/device-runtime.env` → `TUNNEL_PSK`)
- **Result**: ✅ **fully established end-to-end**. IKE_SA_INIT + IKE_AUTH succeed (`AES_CBC_256/HMAC_SHA2_384/MODP_2048`, ESP `AES_GCM_16_256`); CHILD_SA INSTALLED; XFRM interface `ipsec-gsa` up; **eBGP established with 66 prefixes received** from GSA gateway and installed into the kernel via `ipsec-gsa`. Control-plane dashboard: `tunnelStatus=up`, `bgp=established`.
- **Data plane**: split-tunnel — GSA-advertised prefixes (M365/Entra ranges, e.g. `13.107.x`, `20.20.x`) route through `ipsec-gsa`; general internet egresses locally via WAN (`4.246.81.122`). Verified with `ip route get` + live interface counters.
- **Bug fixes made during this test** (device-runtime):
  1. `managementHealthy()` no longer pings the default gateway (Azure VNet gateway never answers ICMP → caused false watchdog reverts that deleted `ipsec-gsa` + SA every apply). Now only pings an explicitly-configured `healthCheckHost`.
  2. Steady-state heartbeat now does a **live** SA/BGP probe (`collectTunnelDiagnostics`) instead of reporting the stale apply-time status snapshot.
  3. `readBgpSessionState()` now recognizes FRR's numeric-PfxRcd representation of an established session (previously only matched the literal word "Established", which FRR never prints).

### Device-006 — Clean End-to-End Deploy on Fixed Runtime (✅ ESTABLISHED, updated 2026-06-22)
- **Purpose**: Prove the three device-005 bug fixes work on a **fresh deploy** — the runtime must bring the GSA tunnel up automatically with no manual debugging.
- **Subscription / RG / Region**: `3b328940-6e2a-4b01-bcff-d2c8cfa0da1d` / `RN1` / **westus2** (reused device-005's vnet).
- **VM**: `rnfleet-device-006`, Ubuntu 24.04, Standard_D2s_v5. Public IP `20.94.207.101`, WAN `eth0`=10.0.0.5, LAN `eth1`=10.0.1.5 (dual-NIC; eth1 auto-configured via Azure DHCP/netplan).
- **Provisioning**: same portable **cloud-init** bundle as device-005 (embedded device-runtime + contracts, Node 22 + strongSwan/swanctl + FRR). The 3 bug fixes are baked into the image. Registered + heartbeating within minutes; survives deallocate/start with a static public IP.
- **Tunnel config** (from Entra remote network `NewLink3` / link `ROLINIK2`, config v34):
  - GSA: endpoint `20.150.156.94`, ASN `65476`, BGP `192.168.3.2`, region westUS3
  - Peer: endpoint `20.94.207.101`, ASN `65006`, BGP `192.168.3.1`, localNetworks `10.0.1.0/24`
  - IPSec/IKE custom policy: IKE AES256/SHA384/DHGroup14 (P1 Combo 7); ESP **GCMAES192**/PFS None (**P2 Combo 2**); SA 3600s
  - PSK `microsoft12345` (set in `/etc/rnfleet/device-runtime.env` → `TUNNEL_PSK`)
- **Result**: ✅ **fully established end-to-end with zero runtime debugging**. IKE_SA ESTABLISHED (`AES_CBC_256/HMAC_SHA2_384/MODP_2048`); CHILD_SA INSTALLED (`ESP:AES_GCM_16-192` = GCMAES192, confirming Combo 2); XFRM interface `ipsec-gsa` up; **eBGP established with 584 prefixes received** from GSA and installed via `ipsec-gsa`; `10.0.1.0/24` advertised. Per-device provisioning was the only manual step (set `TUNNEL_PSK`, push config).
- **Data plane**: split-tunnel preserved — default route stays on WAN (`10.0.0.1` dev eth0); only GSA-advertised prefixes route through `ipsec-gsa`. ICMP to the GSA BGP peer fails (GSA gateways don't answer ping, like the VNet gateway) but the established eBGP/TCP session proves reachability.
- **Operational note**: `ROLINIK2` advertises a broad internet prefix set (198/199/200–208 ranges incl. Microsoft `204.79.197.x`). When the admin client's egress IP falls inside an advertised prefix, the SSH return path is pulled into the tunnel and admin SSH drops — use Azure Serial Console / `az vm run-command` for in-guest inspection in that case. The device itself stays healthy and heartbeating.

### Portal-Driven End-to-End Test on device-006 (✅ PASSED, 2026-06-23)
- **Goal**: prove the GSA tunnel can be stood up **entirely from the operator portal** — PSK, IKE Phase 1/2 combinations, and a multi-step progress UI — and validate it as a real user with browser automation (Playwright/`playwright-core` driving Edge against the live portal + control-plane).
- **Method / proof of UI-supplied PSK**: the device's `TUNNEL_PSK` env was deliberately set to a **wrong** value before the test, so the IPSec SA could only authenticate using the PSK pushed from the UI (`tunnel.psk = microsoft12345`). The Playwright run pasted the `NewLink3`/`ROLINIK2` connectivity JSON, set IKE P1 Combo 7 + P2 Combo 2, typed the PSK, set local nets `10.0.1.0/24`, and clicked **Push All Config**.
- **Result**: ✅ stepper advanced Submit → Device fetch/apply (v38) → **IPSec SA INSTALLED** (`ESP:AES_GCM_16-192`, confirming the UI-selected Combo 2 **and** that IKE auth succeeded on the UI PSK while the env PSK was wrong) → **BGP established (584 prefixes)**, reaching "Push complete · 100%" in ~18s. The multi-step progress UI showed live percentage, elapsed time, and a "still working…" hint — the admin never sees a hung UI.
- **Recursive-routing flap fix (device-runtime)**: the first run reached IPSec up but BGP **flapped** (established → `Connect` → re-establish, ~4-min cycle). Root cause: GSA advertises a broad prefix covering the tunnel endpoint `20.150.156.94`, so once BGP installed routes the kernel sent the **encrypted ESP** for the endpoint back into `ipsec-gsa` (recursive routing) → SA torn down → BGP dropped → repeat. **Fix**: the tunnel agent now pins the GSA endpoint with a `/32` host route via the WAN gateway whenever the XFRM interface is (re)created (`pinTunnelEndpointRoute`), so ESP always stays on the underlay (a `/32` always wins longest-prefix-match over any broader advertised route). After the fix, BGP held **established with 584 prefixes, no resets** across repeated checks. Device/provider-agnostic (gateway auto-detected; on-link fallback).
- **Bug fix #4 (device-runtime)**: tunnel-endpoint underlay `/32` pin to prevent recursive-routing tunnel/BGP flap (above). Adds to the three device-005 fixes.

### Bare-Metal Appliance ISO + Hyper-V — Provider-Agnostic Install (✅ VALIDATED, 2026-06-23)
- **Goal**: prove an appliance can be stood up on **non-Azure hardware** from a single installer ISO — no custom cloud image, no Azure dependency — and reach the same live GSA tunnel/BGP state. Validates the device/provider-agnostic design (`infra/bare-metal/iso/`).
- **Build**: `build-appliance-iso.ps1` remasters the stock Ubuntu 24.04 Live Server ISO inside a Docker `ubuntu:24.04` container (xorriso/7z), bakes in the RNFleet payload + autoinstall seed, patches GRUB for a hands-off `autoinstall ds=nocloud` boot, and repacks a **3.17 GB hybrid BIOS+UEFI ISO**. Optional `-EnrollmentConf` bakes a factory pre-seed so the box enrolls **unattended** (no console prompt) for headless test.
- **Install flow**: ISO boots → autoinstall wipes disk, installs Ubuntu + tunnel stack (strongSwan/swanctl + FRR) → `provision-appliance.sh` runs in-target (Node 22, device runtime, first-boot wizard; runtime **disabled**, no identity) → reboot → `rnfleet-setup` runs unattended from the pre-seed → enrolls to CP → runtime starts.
- **Test environment**: **Hyper-V Gen2 VM** (4 GB, 2 vCPU, 20 GB, Secure Boot off), WAN on the NAT-backed *Default Switch*, LAN on a private switch. Created/torn-down via an elevated `create-hyperv-vm.ps1` (UAC). The device runtime **auto-detected `eth0` as WAN from the default route** (not hardcoded) — proving hardware-agnosticism on Hyper-V virtual NICs.
- **Result**: ✅ device `rnfleet-hyperv-test` registered **online** and heartbeating with full telemetry, then (config pushed) brought up a **live GSA tunnel off Azure entirely**:
  - **IPSec**: `rnfleet-gsa` **ESTABLISHED** (IKEv2) to GSA gateway `20.150.152.150:4500`, CHILD_SA INSTALLED (`ESP:AES_GCM_16-256`, TUNNEL-in-UDP / NAT-T), traffic counters incrementing.
  - **BGP**: neighbor `192.168.1.2` (AS 65476, "GSA-Gateway") **Established**, **584 prefixes received** and installed into the kernel via `ipsec-gsa` (`proto bgp`).
  - **Data plane**: appliance egress public IP became a **Microsoft GSA egress IP** (`151.206.133.1`) vs. its local WAN public IP (`50.53.108.187`); `ip route get 1.1.1.1` → `via 192.168.1.2 dev ipsec-gsa`. Internet-bound traffic exits through GSA.
- **Chroot-safety bug fixes (shared provisioning scripts)** — the autoinstall `curtin in-target` step is a chroot with **no running systemd (PID 1)**, so the first install attempts failed:
  1. `install-device-runtime.sh` + `provision-appliance.sh`: guard all `systemctl` calls (`daemon-reload`/`enable`) with `|| true`; arm the first-boot wizard via an explicit `multi-user.target.wants` symlink (offline-safe) instead of relying on a live `systemctl enable`.
  2. `install-device-runtime.sh`: **`mkdir -p /var/lib/rnfleet`** before `chown` — `useradd --system --create-home` does not reliably create the home dir in the chroot, which aborted provisioning (`chown: cannot access '/var/lib/rnfleet'`, exit 1). Root-caused by capturing the in-target log to the EFI (FAT32) partition and reading it back by mounting the VHDX from the host.
  3. `rnfleet-setup.sh`: firstboot + a valid pre-seed (FLEET_PSK present) forces **UNATTENDED** so a headless appliance auto-enrolls instead of hanging on a console `read`.
- **Appliance branding + wizard UX (2026-06-23, after validation)**:
  - **ASCII globe logo + captions** (`Global Secure Access` / `Remote Network Appliance` / `Version 1`) baked to `/etc/rnfleet/logo.txt`, shown in the console MOTD login banner and atop the first-boot wizard. Single source: `apps/device-runtime/packaging/firstboot/rnfleet-logo.txt` (installed by the bare-metal provisioner and the Azure Packer template).
  - **`FIRSTBOOT_INTERACTIVE=true` pre-seed flag**: opts out of silent enrollment — the wizard appears on the console pre-filled from the pre-seed so the operator reviews/overrides each value (defaults + the PSK) before applying.
  - **Per-field + final confirmation**: the wizard now validates every required field is non-empty and asks `Use "X"? [Y/n]` after each entry (decline to re-enter), then a final `Apply this configuration? [Y/n]` summary — nothing is written/enrolled until confirmed.
  - **Post-enrollment changes documented**: `sudo rnfleet-setup --force` re-runs the wizard pre-filled with current values, or edit `/etc/rnfleet/device-runtime.env` + `systemctl restart rnfleet-device-runtime.service`.
  - **On-device GSA tunnel + BGP verification** documented (swanctl `--list-sas`, FRR `show bgp summary` / `show ip route bgp`, `ip route get`, "what's my IP" WAN-vs-tunnel egress comparison) in `infra/bare-metal/iso/README.md`.
- **Artifacts** (kept OUT of git): `dist/` / `dist2/` (validated baked-preseed ISO) / `dist3/` (interactive `FIRSTBOOT_INTERACTIVE` ISO) hold the 3.17 GB ISOs, `enrollment.conf` / `enrollment-interactive.conf` (test secrets), and the Hyper-V scripts. Repo stays ~3 MB.

### Minimal Golden Image (qcow2/VHDX) + LAN Router + Dual-Console Wizard — Hyper-V Gen2 (✅ VALIDATED, 2026-06-23)
- **Goal**: ship a **small** appliance image (appliance vendors expect ~hundreds of MB, not a 6 GB full-OS VHD) that is still device/provider-agnostic, doubles as a **LAN default-gateway router** (`LAN → appliance → GSA`), and presents the enrollment wizard on **both** the video and serial consoles. Build tree: `infra/bare-metal/golden-image/`.
- **Build**: `build-min-appliance.sh` debootstraps Debian bookworm with `mmdebstrap` and bakes the exact same stack as the ISO (`provision-appliance.sh`): strongSwan/swanctl + charon-systemd, FRR/BGP, Node 22, the device runtime, the first-boot wizard, and the LAN-router role (dnsmasq DHCP/DNS + nftables NAT). Output is a compressed **qcow2 (~0.7 GB)** — roughly **10× smaller** than the full-OS golden VHDX. Runs entirely in a privileged Docker container; no host tooling. `finish-min-appliance.sh` resumes the fast tail from the cached rootfs.
- **VHDX for Hyper-V**: `qemu-img convert -O vhdx -o subformat=dynamic` (run in Docker) produces `rnfleet-appliance-min.vhdx` (~2 GB dynamic) for Gen2 VMs. Deliverables live in `dist/golden-min/` (gitignored).
- **Test environment**: Hyper-V **Gen2** VM `GSA-min` (2 vCPU / 2 GB, Secure Boot **off**), WAN on the NAT-backed *Default Switch*, COM1 → named pipe for serial capture. Created/redeployed via an elevated `create-gsa-min-vm.ps1` (UAC). Runtime auto-detected `eth0` as WAN from the default route.
- **Result**: ✅ enrolled and **online** on the control-plane (`status=online`), heartbeating with WAN public IP. The wizard ran end-to-end (logo → **Network interfaces panel** → per-field prompts → "Appliance enrolled") on the serial console, and the device registered automatically once DNS worked. (Tunnel/BGP `down`/`unknown` until the portal pushes a GSA config — expected for a fresh enroll.)
- **First-boot wizard UX additions** (`apps/device-runtime/packaging/firstboot/`):
  - **Wizard on BOTH consoles**: a getty wrapper `rnfleet-console-entry.sh` runs the wizard on each console until enrolled, then execs `agetty`. Drop-ins override `getty@tty1` **and** `serial-getty@ttyS0`; the legacy single-console `rnfleet-firstboot.service` is disabled (it fought the gettys for `ttyS0`). A race guard in `rnfleet-setup.sh` prevents a double-enroll when one console finishes while the other is still prompting. *(Key gotcha: kernel cmdline `console=tty1 console=ttyS0,...` makes the **last** `console=` the `/dev/console`, so a single-console wizard only appeared on serial — hence the dual-getty approach.)*
  - **Network interfaces panel**: `rnfleet-setup` now prints each non-loopback NIC's link state, **IPv4 address/CIDR** and MAC, plus the **default gateway** (and its interface) and **DNS servers**, right above the enrollment prompts — so the operator confirms WAN/LAN addressing before enrolling.
- **Bug fixes made during this validation**:
  1. **Slow boot (~90 s)** — `/etc/network/interfaces` used `auto eth0` so `networking.service` blocked until DHCP timed out on a DHCP-less switch. Changed to **`allow-hotplug eth0`** (udev brings the WAN up async; networking.service finishes instantly) + `dhclient timeout 15`. Also `bind-interfaces`→**`bind-dynamic`** so lan-router dnsmasq doesn't fail when the LAN iface isn't settled at start.
  2. **DNS dead on every boot (root cause of "device never checks in")** — the build symlinked `/etc/resolv.conf` → systemd-resolved's stub (`/run/systemd/resolve/stub-resolv.conf`), but **systemd-resolved is not installed** in the minimal image, so the symlink dangled: no DNS → name resolution failed → the runtime could not reach the control-plane. The intended public-resolver fallback never ran because `ln -sf` itself succeeds. **Fix**: ship `/etc/resolv.conf` as a **real file** with public bootstrap resolvers; ifupdown/dhclient overwrites it with the DHCP-provided nameservers at runtime. Verified live: DNS resolves, CP `/health`=200, device registers online.
  3. **Wizard aborted right after the banner** — the new network panel read `/etc/resolv.conf` with `awk`, which exits non-zero when that file is absent (factory image, no lease yet). Under the script's `set -euo pipefail` that killed the whole wizard. Guarded the resolv.conf read with `[ -r ]`, tolerated failed route lookups, and call the helper as `show_network_summary || true`.
- **Commits**: `2b9a3ab` (non-blocking WAN + resilient dnsmasq), `f5be242` (wizard on both consoles), `2d91fac` (NIC summary panel), `8cd4d4c` (set -e guard), `e333fdf` (DNS real resolv.conf).
- **Artifacts** (gitignored): `dist/golden-min/rnfleet-appliance-min.{qcow2,vhdx}` + the Hyper-V/serial driver scripts in the session workspace.

### Azure Appliance Image — Gen2 VHD from the Golden Image (🧰 TOOLING, 2026-06-23)
- **Goal**: publish the **same validated golden appliance** to Azure (not a separate cloud-only build), so the bits are byte-identical across bare-metal / Hyper-V / Azure. Tree: `infra/cloud/azure/appliance-image/`.
- **Provider-neutral hooks**: `build-min-appliance.sh` gained two no-op-by-default extension points — `EXTRA_INCLUDE` (append packages) and `EXTRA_CONFIGURE` (run a script in the target chroot after provisioning). The default bare-metal/Hyper-V image is unchanged (neither hook set).
- **Azure layer** (`azure-configure.sh`, applied via the hooks with `EXTRA_INCLUDE=cloud-init,waagent`): forces `hv_*` modules into the initramfs (Gen2 VMBus boot), points cloud-init at the **Azure datasource** while **disabling cloud-init network management** (appliance keeps `ifupdown` for eth0/eth1), and sets the Azure Linux Agent (Debian pkg `waagent`) to provisioning-only (`Provisioning.Agent=cloud-init`). All inert off-Azure.
- **Toolchain** (PowerShell + Docker/qemu, no host deps): `build-azure-appliance.ps1` (build qcow2 + convert), `convert-to-azure-vhd.sh` (qcow2 → **fixed VHD**, virtual size rounded to a whole MiB — Azure's hard requirement; qcow2/VHDX are rejected), `publish-azure-image.ps1` (upload page blob via `az`, create **Gen2 managed image** + optional **Compute Gallery** version), `create-azure-vm.ps1` (Gen2 test VM, Serial Console enabled, optional cloud-init `-EnrollmentConf` pre-seed). Output → `dist/golden-azure/` (gitignored).
- **Status**: tooling + docs complete and syntax-validated; **not yet uploaded/deployed** (no Azure build run). `az login` + a `build-azure-appliance.ps1` run produces the VHD; `publish-azure-image.ps1` creates the image in RG `RN1`.

---

## 📊 Completion Status by Phase

### Phase 1: Requirements & Architecture ✅
- [x] GSA appliance requirements documented (`docs/requirements/appliance-requirements-gsa-remote-network.md`)
- [x] Requirements health-check framework created (`docs/requirements/healthcheck.md`)
- [x] System architecture overview drafted (`docs/architecture/system-overview.md`)
- [x] Project structure and domain boundaries defined (`docs/architecture/project-structure.md`, `agents.md`)

### Phase 2: MVP Implementation ✅
- [x] **Control-plane API** (`apps/control-plane/`)
  - Device registration endpoint
  - Configuration fetch/push
  - Job queue and execution tracking
  - Heartbeat ingestion and device state tracking
  - PSK-based authentication (header: `x-fleet-psk`)
  - File-backed store (JSON)

- [x] **Portal Web UI** (`apps/portal/`)
  - Fleet device list and status view
  - Config editor and push capability
  - Job creation and monitoring
  - Audit log viewer
  - Dynamic runtime config injection

- [x] **Device Runtime** (`apps/device-runtime/`)
  - Bootstrap registration flow
  - Config polling and state reconciliation
  - Job execution (restart_tunnel, run_diagnostics, etc.)
  - Heartbeat reporting to control-plane
  - Systemd service for appliance integration

- [x] **Shared Contracts** (`packages/contracts/`)
  - Device schema and registration contract
  - Config schema and defaults
  - Job types and telemetry envelopes
  - Validators for all payloads

### Phase 3: Cloud Deployment ✅
- [x] Azure Bicep infrastructure template (`infra/cloud/azure/bootstrap/mvp-foundation.bicep`)
- [x] App Service Plan (B1 tier)
- [x] Control-plane Web App deployed and healthy
- [x] Portal Web App deployed and healthy
- [x] Storage Account, Key Vault, Log Analytics, Application Insights provisioned
- [x] Startup probe issue fixed (public `/` and `/health` endpoints before PSK middleware)

**Cloud Endpoints:**
- Control-plane: `https://rnfleet-cp-a7nzwz.azurewebsites.net` (HTTP 200)
- Portal: `https://rnfleet-portal-a7nzwz.azurewebsites.net` (HTTP 200)

### Phase 4: Appliance Image Build ✅
- [x] Packer template created (`infra/cloud/azure/bootstrap/image/ubuntu-appliance.pkr.hcl`)
- [x] Ubuntu 24.04 base image configured
- [x] Node.js 22 LTS installed
- [x] Device runtime code provisioned
- [x] Systemd service installed and enabled
- [x] Install scripts and environment template created
- [x] Line-ending issue resolved (CRLF → LF via `sed`)
- [x] **Managed image built successfully**: `rnfleet-appliance-ubuntu-2404` in RNFleet RG

### Phase 5B: Config Push & Job Execution ✅
- [x] Config push tested & working (device-001)
  - Pushed tunnel config via portal API
  - Device fetched within 2 poll cycles (20s)
  - Config version incremented: 1 → 2
  - Device state file updated

- [x] Job execution tested & working
  - Created run_diagnostics job via portal API
  - Device picked up job (status: queued → completed)
  - Job executed and returned result: `{ tunnelStatus: "up" }`
  - Job-000001 completed in <8s

- [x] Additional job types tested
  - restart_tunnel job created and completed
  - Job-000002 executed successfully

- [x] Error handling validated
  - Invalid job type correctly rejected (HTTP 400)
  - Audit trail accurately logged all operations

- [x] Audit trail verified
  - Config updates recorded with version
  - Job creation and completion logged
  - All operations visible in audit endpoint

### Phase 5C: Multi-Device Fleet Testing ✅ **COMPLETE**

**Infrastructure Deployed**:
- ✅ 3 additional VMs deployed in westus3 (device-test-02, 03, 04)
- ✅ Each configured with unique DEVICE_ID (device-002, 003, 004)
- ✅ Device runtime installed on each
- ✅ Configuration files created: `/etc/rnfleet/device-runtime.env`
- ✅ Services started and running

**Resolved Issue**:
- ✅ Devices 002-004 registration issue resolved
- ✅ Runtime env and systemd service path corrected on each device
- ✅ All devices now visible in `/api/v1/portal/devices`

**Success Criteria**:
- [x] Resolve device registration issue
- [x] 4 devices all online in portal
- [x] Each device heartbeating independently
- [ ] Subset config push works (only affects target devices)
- [ ] Concurrent jobs execute without interference

---

- [x] Created vnet/subnet infrastructure in westus3 (image region)
- [x] Deployed test VM from managed image
  - VM Name: `rnfleet-device-test-01`
  - Public IP: `172.182.237.28`
  - Private IP: `10.0.1.4`
  - Region: westus3
- [x] SSH access verified (azureuser@172.182.237.28)
- [x] Device runtime systemd service auto-started
- [x] Configured `/etc/rnfleet/device-runtime.env` with cloud endpoint
- [x] Service restarted with cloud config
- [x] **Device successfully registered to control-plane**
  - Device ID: `device-001`
  - Status: `online`
  - Tunnel Status: `up`
  - Last Heartbeat: Active
  - Config Version: 1

---

## 🔧 Current Technical State

### Authentication & Security
- **Status**: PSK-only (dev/MVP mode)
- **Details**: Hardcoded shared secret via `x-fleet-psk` header
- **Default**: `dev-fleet-psk`
- **Planned**: Per-device certificates + Azure Key Vault (Phase 5)

### Data Persistence
- **Status**: File-backed JSON store (MVP)
- **Location**: `apps/control-plane/data/store.json`
- **Limitation**: Not multi-writer safe; single-instance only
- **Planned**: Postgres or Cosmos DB (Phase 5)

### Device Integration
- **Network**: Real interface telemetry (name/MAC/IPv4/IPv6/routes) now reported
- **IPSec**: Real strongSwan (swanctl/vici); live tunnel status probed each loop. Validated ESTABLISHED against a GSA remote network on device-005
- **BGP**: Real FRR; eBGP established with GSA (66 prefixes received/installed) in route-based `ipsec-gsa` split-tunnel mode
- **Routing**: Critical LAN apply path implemented with rollback safety
- **Systemd Service**: Ready (`rnfleet-device-runtime.service`)
- **Config File**: Template at `apps/device-runtime/packaging/device-runtime.env.example`

### Critical LAN IP/Subnet Change Safety (NEW)
- **Status**: ✅ Implemented and deployed
- **Why critical**: wrong LAN apply can cut off site traffic and lock out management paths
- **Required safeguards**:
  - strict control-plane validation (IP/prefix/interface conflicts)
  - two-phase device apply (`prepare -> commit`)
  - automatic rollback on verification failure
  - explicit operator confirmation + audit trail in portal
  - WAN public IP telemetry available in portal for IPSec/BGP planning

### Networking Constraints
- **Azure Subscription**: Egress-only (80/443 allowed)
- **Implication**: Control-plane must be public HTTPS; no inbound management protocols
- **Device Model**: Pull-based (device polls control-plane, not vice versa)

---

## 📋 Immediate Next Steps (Priority Order)

### 🟢 COMPLETE ✅: Phase 5D (Network Telemetry)
- ✅ Real WAN/LAN/route telemetry parsed and displayed
- ✅ WAN public IP for IPSec/BGP planning
- ✅ Responsive portal UX with split config sections

---

### 🟢 Phase 6: IPSec + BGP Integration — **VALIDATED END-TO-END**

**Goal**: Full strongSwan + FRR lifecycle wired to desired-state config. ✅ Achieved — live tunnel established against a GSA remote network on device-005.

**Completed this session**:
- ✅ Tunnel agent written (`apps/device-runtime/src/agents/tunnel/index.js`)
- ✅ Structured `gsa`/`peer` tunnel schema + `validateTunnelConfig()`
- ✅ BGP session state end-to-end (device → heartbeat → portal BGP column)
- ✅ Entra Graph API JSON import in portal
- ✅ `sample-config.md` with real Entra connectivity config + diagram
- ✅ Portal tunnel UX: per-device tunnel detail modal (applied GSA/peer config + live state), pretty audit log, Tunnels Up / BGP Established stat tiles
- ✅ Real `restart_tunnel` + `run_diagnostics` (`swanctl --list-sas`, vtysh bgp summary/routes) jobs; diagnostics surfaced in portal device modal
- ✅ Per-device modal actions: Restart Tunnel, Run Diagnostics (one-click jobs), Edit Tunnel Config (prefills the Tunnel & BGP form from applied config)

**Remaining**:
- [x] Install strongSwan + FRR in Packer image (`ubuntu-appliance.pkr.hcl`)
- [x] Live IPSec tunnel bring-up test vs GSA VPN gateway — ✅ **ESTABLISHED** on device-005 (see device-005 record above)
- [x] BGP session establishment + route exchange validation — ✅ eBGP established, 66 GSA prefixes received and installed
- [x] Tunnel events in audit trail (`tunnel_up`/`tunnel_down`/`bgp_established`/`bgp_down`)

---

### Phase 5D: Network Telemetry ✅ **COMPLETE**

**Goal**: Replace hardcoded network state with real OS data ✅

**Tasks**:
1. ✅ Update device agent to parse real network state
   - Parse `ip addr show` for eth0/eth1 IPs
   - Parse `ip route` for routing table
   - Include in heartbeat as networkState object

2. ✅ Update heartbeat schema in contracts
   - Extend validateHeartbeat to accept networkState
   - Add wanIp, lanIp, routes fields

3. ✅ Update portal to display telemetry
   - Show actual IPs in device detail view
   - Show network state summary
4. ✅ Add WAN public IP telemetry for IPSec/BGP planning
   - Runtime resolves WAN public egress IP
   - Control-plane stores `wanPublicIp`
   - Portal renders WAN Public IP column
5. ✅ Professional responsive portal UX update
   - Split config sections: Device Configuration vs Tunnel Configuration
   - Device and LAN adapter fields use dropdowns
   - WAN column shows interface + IP together
   - Improved responsive layout and visual styling

**Success Criteria**: ✅ All met — real WAN/LAN telemetry visible in portal

---

### Phase 6: IPSec + BGP Integration ✅ **VALIDATED END-TO-END**

**Goal**: Wire real strongSwan (IPSec) and FRR (BGP) lifecycle to desired-state config.

**Completed**:
- ✅ New tunnel agent (`apps/device-runtime/src/agents/tunnel/index.js`)
  - Generates **swanctl/vici** config from desired-state (`gsa`/`peer` objects)
  - Route-based **XFRM-interface** mode (`ipsec-gsa`, `if_id`) so `0.0.0.0/0` selectors don't hijack management traffic; `install_routes = no` drop-in
  - Portable self-heal **watchdog** auto-reverts the tunnel if management connectivity is lost (default-route-unchanged check + optional `healthCheckHost` probe; **never** pings the default gateway, since Azure's VNet gateway does not answer ICMP)
  - Live status: each loop re-probes real IPSec SA + BGP state so heartbeats are never stale
  - Generates FRR BGP config with neighbor, ASN, local networks
  - Drives `swanctl` (`--load-all`/`--initiate`/`--terminate`) and `systemctl reload frr` after write
  - Reads live BGP session state via `vtysh -c "show bgp summary"`
  - `TUNNEL_DRY_RUN=true` mode for safe pre-deploy testing
  - `TUNNEL_PSK` decoupled from control-plane `FLEET_PSK`
- ✅ Structured tunnel config schema in `contracts.js`
  - New `gsa` sub-object: `endpoint`, `asn`, `bgpAddress`, `region`
  - New `peer` sub-object: `endpoint`, `asn`, `bgpAddress`, `localNetworks[]`
  - `validateTunnelConfig()` exported and wired to config-push endpoint
- ✅ `bgpSessionState` tracked end-to-end
  - Device agent reads live state and reports in heartbeat
  - Control-plane stores `bgpSessionState` per device
  - Portal shows BGP column with colour-coded pill (established/active/idle/error)
- ✅ Entra Graph API JSON import in portal
  - Paste `connectivityConfiguration` response → auto-fills all GSA + peer fields
- ✅ Portal **audit log category filters** — Device, Config, Tunnel/BGP, Action checkboxes with live counts + empty-state
- ✅ `sample-config.md` — real Entra GSA BGP config sample + architecture diagram

**Remaining**:
- [x] Install strongSwan + FRR in Packer image
- [x] Test live IPSec tunnel bring-up against GSA VPN gateway — ✅ established on device-005
- [x] Validate BGP session establishes and routes are exchanged — ✅ 66 prefixes received/installed
- [x] Emit tunnel bring-up/down events in audit trail

---

### 🟢 LOW - Production Roadmap (Week 2+)

See `plan.md` for detailed roadmap:
- Phase 6: IPSec + BGP integration (2-3 days)
- Phase 7: Database persistence (2-3 days)
- Phase 8: Per-device identity (2 days)
- Phase 9: Observability & safety (3 days)
- Phase 10: Security & ops hardening (2-3 days)

**Estimated time to production**: 3-4 weeks from now

---

## 📁 Key Documentation Files

| File | Purpose | Status |
|------|---------|--------|
| `docs/requirements/appliance-requirements-gsa-remote-network.md` | GSA appliance requirements (10 requirements from MS Learn) | ✅ Current |
| `docs/requirements/healthcheck.md` | Requirements source health-check framework | ✅ Current |
| `docs/architecture/system-overview.md` | Architecture overview | ✅ Current |
| `docs/architecture/project-structure.md` | Repository layout and conventions | ✅ Current |
| `agents.md` | Implementation agent context | ✅ Current |
| `status.md` | This file — ongoing status tracker | ✅ Updated |
| `sample-config.md` | Real Entra GSA BGP connectivity config + diagram | ✅ New |

---

## 🐛 Known Limitations & TODOs

### Code/Implementation
- [ ] No real `/sys/class/net` enumeration for NIC detection
- [x] IPSec state live-probed via `swanctl --list-sas` (no longer mocked)
- [x] BGP session integration (FRR/`vtysh`), validated established end-to-end
- [ ] File-based store not thread-safe (single App Service instance only)
- [ ] No database migrations framework

### Cloud Infrastructure
- [ ] No CI/CD pipeline for control-plane/portal updates
- [ ] No auto-scaling for device-runtime workloads
- [ ] No disaster recovery plan
- [ ] Logging is basic (no structured correlation)

### Security
- [ ] PSK shared across all devices (replacement: per-device certs)
- [ ] No request signing/verification
- [ ] No operator RBAC (everyone has full access)
- [ ] No encrypted config storage at rest

### Operations
- [ ] No health dashboards or alerting
- [ ] No runbooks for common troubleshooting
- [ ] No compliance/audit export capabilities
- [ ] Device logs not centralized to cloud

---

## 🚨 Blockers / Open Questions

1. **Git line-ending handling**: Does `git clone` on Windows auto-apply `.gitattributes` before Packer runs? If not, future image builds may fail with CRLF issues.

2. **Appliance provisioning**: How will per-device secrets (PSK, device ID) be injected at boot time at scale? ZTP? Pre-configured cloud-init? Manual SSH? *(Partially answered: the bare-metal ISO supports an optional factory `enrollment.conf` pre-seed for unattended enrollment, and the first-boot wizard handles the interactive/manual case. Per-device PSK still pushed from the portal.)*

3. **Inbound tunnel closure**: If device is in an NDS that blocks inbound (only 443 egress), how will the IPSec tunnel from Gateways reach the appliance? **Answered + proven**: the appliance always **dials out** — IKE/NAT-T over **outbound UDP 500/4500** to the GSA gateway (ESP encapsulated in UDP 4500), BGP runs *inside* the tunnel. No inbound ports are required. Validated on the Hyper-V appliance behind the Default Switch NAT: IKE_SA + CHILD_SA established and BGP up with only outbound reachability. (Still open: the *fully* locked-down "443-egress-only" NDS where even UDP 500/4500 are blocked — that needs an IPSec-over-443 escape or relay model.)

4. **BGP adjacency**: Will BGP sessions run on appliance or on a separate router? (Affects device-runtime responsibilities.)

---

## 📞 How to Update This File

This file should be updated whenever:
- A phase completes (move checkmarks ✅)
- A blocker is identified or resolved
- Architecture/deployment decisions change
- A new priority item emerges
- Cloud endpoint URLs or credentials rotate

**Update frequency**: After each significant milestone or weekly checkpoint.

---

## 🔗 Related Documentation

- **Requirements**: `docs/requirements/healthcheck.md` — framework for monitoring source GSA docs
- **Agent Context**: `agents.md` — full implementation context for agents
- **Architecture**: `docs/architecture/system-overview.md` — system design and flows
- **Project Structure**: `docs/architecture/project-structure.md` — repository layout
