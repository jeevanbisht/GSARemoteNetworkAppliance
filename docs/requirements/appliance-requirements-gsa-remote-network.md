# Appliance Requirements for Microsoft Global Secure Access Remote Networks

This page captures appliance (CPE) requirements for RNFleetManager based on Microsoft Learn guidance, with explicit source/version metadata and a retrieval checkpoint.

## Source and version checkpoint

**Checkpoint captured:** `2026-06-19T15:15:55.951-07:00`

| Source | Canonical URL | MS date | Page updated | Version identifiers |
|---|---|---|---|---|
| How to Create Remote Networks | https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-create-remote-networks | 2026-04-15 | 2026-06-15 | `document_version_independent_id: eb82f9e3-6a80-a989-9c77-8c146382f037`, `git_commit_id: d2b1d2db3c2666465f000b2eab8c11bae1830820` |
| How to add device links to remote networks | https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-manage-remote-network-device-links | 2026-03-23 | 2026-06-15 | `document_version_independent_id: 22ff5837-17dd-d3f8-8338-0f8d407a3d7d`, `git_commit_id: d2b1d2db3c2666465f000b2eab8c11bae1830820` |
| Global Secure Access remote network configurations | https://learn.microsoft.com/en-us/entra/global-secure-access/reference-remote-network-configurations | 2026-03-13 | 2026-04-22 | `document_version_independent_id: 202872e3-3ec2-7227-b2b1-0e9071773b19`, `git_commit_id: a11629565e0ba12b8cd63c63566446b9150cab69` |
| How to configure routers for remote networks | https://learn.microsoft.com/en-us/entra/global-secure-access/how-to-configure-customer-premises-equipment | 2026-03-25 | 2026-03-25 | `document_version_independent_id: 5a318e5b-af36-c848-3a91-170acd992f98`, `git_commit_id: e40ec8d20d439303a0aac501fb8ade6761cf6763` |

## Appliance (CPE) requirements

| ID | Requirement | Source quote |
|---|---|---|
| AR-001 | Appliance must support IPSec, IKEv2, and BGP. | “Customer premises equipment (CPE) must support... IPSec... IKEv2... BGP.” (How to Create Remote Networks) |
| AR-002 | IPSec tunnel must use route-based, any-to-any selectors (`0.0.0.0/0`). | “Remote network connectivity solution uses RouteBased VPN configuration with any-to-any (wildcard or 0.0.0.0/0) traffic selectors.” (How to Create Remote Networks) |
| AR-003 | Appliance must initiate tunnel establishment toward Global Secure Access. | “Remote network connectivity solution uses Responder modes. Your CPE must initiate the connection.” (How to Create Remote Networks) |
| AR-004 | IKE/IPSec crypto policy on appliance must exactly match link policy configured in Entra. | “the IPSec/IKE policy you specify must match the policy you enter on your CPE.” (Manage device links) |
| AR-005 | If using default policy, appliance must use one of the documented default Phase 1 and Phase 2 combinations. | “You must specify both a Phase 1 and Phase 2 combination on your CPE.” (Remote network configurations) |
| AR-006 | Appliance must be configured with CPE public IP, BGP local/peer IPs (with role reversal awareness), and ASN. | “Pay close attention to the Peer and Local BGP addresses... details are reversed...” (Manage device links) |
| AR-007 | Appliance ASN must be different from Microsoft ASN and use valid ranges (excluding reserved values). | “A BGP-enabled connection... requires that they have different ASNs.” + valid ASN restrictions. (Manage device links, Remote network configurations) |
| AR-008 | Appliance BGP IP values must avoid reserved addresses and overlap with on-prem ranges. | “Refer to the valid BGP addresses list for reserved values...” (How to Create Remote Networks, Remote network configurations) |
| AR-009 | Appliance must use the same PSK configured in the device link security configuration. | “The same secret key must be used on your respective CPE.” (Manage device links) |
| AR-010 | Use both Microsoft and Internet Access forwarding profiles when licensed to avoid traffic drops. | “To avoid unintended traffic loss, associate both the Microsoft traffic profile and the Internet Access traffic profile...” (How to Create Remote Networks) |

## Operational validation checkpoints

During provisioning and support workflows, verify:

1. IKE profile match (phase 1 and phase 2).
2. PSK match between Entra device link and appliance.
3. BGP local/peer IP mapping and ASN values.
4. Current CPE public IP and current Microsoft endpoint IP from **View configuration**.
5. Traffic profile association to prevent unintended drops.

## RNFleetManager implementation implications

- Device-runtime tunnel agent must support IKEv2/IPSec + BGP orchestration.
- Control-plane templates must model PSK, BGP fields, ASN, selectors, and profile assignment.
- Provisioning flows should include explicit preflight checks for AR-001 through AR-010 before apply.

### How the tunnel agent realizes these requirements

- **AR-002 (route-based, `0.0.0.0/0` selectors)** — implemented with strongSwan
  **swanctl/vici** and a route-based **XFRM interface** (`ipsec-gsa`). The child SA
  uses `local_ts/remote_ts = 0.0.0.0/0` but is bound by `if_id_in`/`if_id_out`, so
  only traffic routed to `ipsec-gsa` is encrypted — management traffic is never
  hijacked. (vici is required: the legacy `ipsec.conf` starter does not reliably
  honor `if_id`.)
- **AR-003 (CPE initiates)** — the agent initiates via `swanctl --initiate`
  (`start_action = start`); the device always dials out to the GSA endpoint.
- **AR-004/AR-005 (crypto match)** — IKE/ESP proposals are mapped from the
  control-plane `tunnel.ipsecPolicy` (Azure custom policy names → strongSwan tokens),
  so the appliance policy exactly matches the Entra link policy.
- **AR-006/AR-007/AR-008 (BGP)** — FRR peers over the tunnel; local BGP `/32` on
  `ipsec-gsa`, GSA peer `/32` routed through it. ASN/BGP IPs come from config.
- **AR-009 (PSK)** — `TUNNEL_PSK` carries the device-link PSK, decoupled from the
  control-plane `FLEET_PSK` credential.
- The implementation is **device-agnostic** (portable Linux: strongSwan/FRR/`ip`),
  so the same appliance runtime works on any CPE, not only Azure VMs.
