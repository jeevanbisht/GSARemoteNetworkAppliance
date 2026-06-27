# Device Runtime

On-device runtime responsible for bootstrap, config reconciliation, secure tunnel lifecycle, and self-healing.

## Module Responsibilities

- `src/bootstrap`: claim flow and first-run identity setup
- `src/agents/management`: control-plane sync and job execution
- `src/agents/network`: WAN/LAN role enforcement and routing
- `src/agents/tunnel`: secure tunnel session management
- `src/agents/watchdog`: health checks and automatic recovery
- `src/platform`: OS-level adapters (systemd/network/firewall)
- `src/safety`: last-known-good state and rollback logic

## Runtime Principles

- Idempotent reconciliation loop
- Fail-closed for unsafe config
- Automatic fallback to known-good configuration

## MVP Runtime Notes

- Start with: `npm run start:device` (from repository root)
- Required environment values (defaults provided):
  - `CONTROL_PLANE_URL` (default `http://localhost:4000`)
  - `FLEET_PSK` (default `dev-fleet-psk`) — control-plane auth secret
  - `TUNNEL_PSK` (default falls back to `FLEET_PSK`) — IPSec pre-shared key for the
    GSA tunnel, kept independent from the control-plane credential
  - `DEVICE_ID` (default `device-001`)

## Tunnel Agent (IPSec + BGP) — device-agnostic

`src/agents/tunnel` brings up a secure tunnel to a Microsoft Global Secure Access
(GSA) remote network. It assumes only a generic Linux box — it works identically on
bare metal, a Raspberry Pi, or a VM on any cloud. No cloud metadata or hardcoded
interface names are used (the WAN device is auto-detected from the default route).

- **strongSwan via swanctl/vici** — the agent generates `/etc/swanctl/swanctl.conf`
  (connections + secrets) and drives `swanctl --load-all` / `--initiate` /
  `--terminate` / `--list-sas`. The modern vici interface is used instead of the
  legacy `ipsec.conf` starter because only vici reliably honors `if_id`.
- **Route-based XFRM interface** — the child SA is bound to the `ipsec-gsa` XFRM
  interface via `if_id_in`/`if_id_out`. GSA is a route-based gateway that requires
  `0.0.0.0/0` traffic selectors; binding by `if_id` means only traffic routed to
  `ipsec-gsa` is encrypted, so management traffic (SSH, guest agent) is never
  hijacked. A `charon { install_routes = no }` drop-in is written as defense-in-depth.
- **BGP over the tunnel (FRR)** — the local BGP `/32` lives on `ipsec-gsa` and the GSA
  peer `/32` is routed through it, so eBGP is single-hop. Advertised prefixes flow in
  dynamically; no static routes.
- **Tunnel-endpoint underlay pin (recursive-routing protection)** — the GSA tunnel
  endpoint (the ESP destination) is pinned with a `/32` host route via the WAN gateway
  whenever the XFRM interface is (re)created. GSA route-based gateways advertise broad
  internet prefixes that can cover the endpoint's own public IP; without the pin the
  kernel would prefer that more-specific BGP route (next-hop `ipsec-gsa`) and send the
  encrypted ESP packets back into the tunnel, causing recursive routing that tears the
  SA down — the tunnel and BGP session then flap continuously. A `/32` is the longest
  possible prefix, so it always wins longest-prefix-match over any broader advertised
  route, keeping ESP on the underlay. Device/provider-agnostic (gateway auto-detected;
  falls back to on-link for point-to-point WANs).
- **Config-driven crypto** — IKE/ESP proposals are mapped from the Azure custom
  IPSec/IKE policy (`tunnel.ipsecPolicy`); defaults match the GSA "Custom" policy.
- **Config-driven PSK** — the IPSec pre-shared key resolves in precedence order
  `tunnel.psk` (pushed from the portal) → `TUNNEL_PSK` env → `FLEET_PSK` env →
  `dev-fleet-psk`. This lets an operator set/rotate the GSA key entirely from the UI
  without touching the device; an empty `tunnel.psk` keeps the existing device-side key.
- **Self-heal watchdog** — after applying the tunnel the agent verifies management
  connectivity (the management **default route must be unchanged**, plus an optional
  active probe to a configurable `tunnel.healthCheckHost`). If connectivity is lost it
  auto-reverts the tunnel (terminate + load an idle `start_action = none` config). This
  is portable and needs no cloud API or out-of-band rescue.
  - The watchdog **never pings the default gateway**: many cloud and enterprise
    gateways (e.g. Azure's VNet gateway at `x.x.x.1`) never answer ICMP, so a gateway
    ping yields false negatives that would wrongly revert a healthy tunnel. Reachability
    is only probed when `tunnel.healthCheckHost` is explicitly set.
- **Live status reporting** — every reconcile loop re-probes the real IPSec/BGP state
  (`swanctl --list-sas` + `vtysh show bgp summary`) so the heartbeat reflects the
  current SA/BGP state, not the snapshot captured at the last config apply (a tunnel
  can establish moments after `applyTunnelConfig()` returns). BGP "established" is
  detected from FRR's numeric `PfxRcd` column, which FRR prints instead of the literal
  word `Established`.

## Appliance Packaging

- Systemd service: `packaging/systemd/rnfleet-device-runtime.service`
- Default env template: `packaging/device-runtime.env.example`
- Linux install script: `packaging/install-device-runtime.sh`
- **First-boot enrollment wizard**: `packaging/firstboot/` — `rnfleet-setup.sh`
  (the wizard; prints a NIC IP/subnet/gateway/DNS summary, then prompts), and
  `rnfleet-console-entry.sh` (getty wrapper that shows the wizard on **both**
  `tty1` and `ttyS0` until enrolled, then execs `agetty`). `enrollment.conf.example`
  is the unattended pre-seed; `rnfleet-logo.txt` is the branding banner.
- **LAN-router role**: `packaging/lan-router/` — turns a 2-NIC appliance into the
  LAN default gateway (`LAN → appliance → GSA`) via dnsmasq DHCP/DNS + nftables NAT;
  no-ops on single-NIC hosts.

## Critical LAN Change Handling

Device runtime handles LAN IP/subnet changes with safety controls:

- precheck interface existence and current address state
- apply in two phases (`prepare -> commit`)
- verify post-apply interface state
- rollback to last-known-good LAN address on failure
