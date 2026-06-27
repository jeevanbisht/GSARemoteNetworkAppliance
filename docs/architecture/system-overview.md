# System Overview

## High-Level Components

1. **Edge Device Runtime (`apps/device-runtime`)**
   - Bootstraps and registers device
   - Applies desired-state config
   - Manages network role (WAN/LAN) and secure tunnel lifecycle
   - Reports telemetry, health, and inventory

2. **Control Plane (`apps/control-plane`)**
   - Device identity and registration
   - Policy/config authoring and versioning
   - Job orchestration for rollout/operations
   - Audit, observability, and lifecycle management

3. **Operator Portal (`apps/portal`)**
   - Fleet inventory and status
   - Config profile management
   - Rollout controls and operational actions

## Configuration Model

Configuration is layered and merged in this order:

`global baseline -> environment/site profile -> device override -> emergency override`

All configuration is:

- schema-validated
- versioned
- signed before distribution
- applied with rollback support

## Critical Network Change Workflow

For LAN IP/subnet updates, RNFleetManager uses a safety-oriented workflow:

1. Control-plane validates network intent (interface/IP/prefix constraints).
2. Device runtime performs two-phase apply (prepare, then commit).
3. Device verifies post-apply health and interface state.
4. On failure, device rolls back to last-known-good config and reports reason.
5. Portal surfaces critical-change status and audit trail for operators.

## Scale Considerations

- Stateless API pods for horizontal scaling
- Queue-backed job workers for push operations
- Time-series telemetry pipeline for large fleet visibility
- Capability-based targeting to prevent incompatible config pushes

## Secure Tunnel + BGP Data Plane (GSA)

The device runtime establishes an IPSec tunnel to a Microsoft Global Secure Access
(GSA) remote network and peers with it over BGP. The design is **device- and
provider-agnostic** — it depends only on portable Linux primitives (strongSwan, FRR,
`ip`/XFRM) and runs identically on bare metal, a Raspberry Pi, or a VM on any cloud.

- **strongSwan via swanctl/vici** — connections/secrets are rendered to
  `/etc/swanctl/swanctl.conf`; the agent uses `swanctl` (not the legacy `ipsec.conf`
  starter) because only vici reliably honors `if_id`.
- **Route-based XFRM interface (`ipsec-gsa`)** — the child SA is bound by
  `if_id_in`/`if_id_out`. GSA requires `0.0.0.0/0` traffic selectors; binding by
  `if_id` ensures only traffic routed to `ipsec-gsa` is encrypted, so management
  traffic is never hijacked.
- **BGP inside the tunnel (FRR)** — local BGP `/32` on `ipsec-gsa`, GSA peer `/32`
  routed through it (single-hop eBGP); prefixes exchanged dynamically.
- **Self-heal watchdog** — after apply, the agent verifies management connectivity
  (the management default route must stay unchanged; an active reachability probe runs
  only against an explicitly configured `tunnel.healthCheckHost`) and auto-reverts the
  tunnel if it is lost. The watchdog never pings the default gateway, because many
  cloud/enterprise gateways (e.g. Azure's VNet gateway) do not answer ICMP. No cloud API
  or out-of-band rescue is needed.
- **Live status** — each reconcile loop re-probes the real IPSec SA and BGP session so
  device heartbeats report current state rather than the last apply-time snapshot.

> **Validation status:** the full data plane has been validated end-to-end against a live
> GSA remote network — IKE/IPSec SA established, route-based `ipsec-gsa` interface up,
> and eBGP established with GSA-advertised prefixes installed into the kernel
> (split-tunnel: only GSA-advertised ranges traverse the tunnel; other traffic egresses
> locally). See `status.md` for the device-005 test record.

> Cloud-specific tooling (e.g. Azure NSGs, `az` CLI, Serial Console) is **test and
> recovery scaffolding only** and must never be baked into the shipped agent or
> packaging.
