# RNFleetManager Project Plan

**Current Phase**: Phase 6 - IPSec + BGP Integration (Validated ✅) · Bare-metal appliance ISO validated ✅  
**Status**: Phase 5D Complete ✅ | Phase 6 Validated End-to-End ✅ | Provider-agnostic bare-metal install proven on Hyper-V ✅  
**Updated**: 2026-06-23 10:30 UTC-7

---

## 📍 Current Milestone

✅ **Phase 5D checkpoint**: Real network telemetry live in portal
- WAN/LAN IPs, WAN public IP, route count all parsed from OS
- Portal displays WAN (interface/IP), WAN public IP, LAN IP columns
- LAN apply workflow with rollback safety implemented
- Responsive portal UX with split config sections

✅ **Phase 6 validated**: IPSec + BGP integration live end-to-end
- Tunnel agent generates real strongSwan (swanctl/vici) + FRR config
- Live device (device-005) established IPSec SA + eBGP to a GSA remote network
- 66 GSA-advertised prefixes received and installed via route-based `ipsec-gsa`
- BGP session state tracked end-to-end (vtysh → live heartbeat probe → portal)
- Portal has structured Tunnel & BGP form + Entra JSON import
- `sample-config.md` with real Entra connectivity config + architecture diagram

✅ **Bare-metal appliance ISO validated** (provider-agnostic, off-Azure):
- `infra/bare-metal/iso/` builds a hands-off Ubuntu 24.04 autoinstall ISO (hybrid BIOS+UEFI, 3.17 GB) via Docker/xorriso, with the same runtime + first-boot wizard as the Azure image
- Tested live on a **Hyper-V Gen2 VM**: unattended install → auto-enroll → registered online → **live GSA tunnel** (IPSec ESTABLISHED to `20.150.152.150`, BGP Established 584 prefixes, egress via GSA `151.206.133.1`)
- Fixed `curtin in-target` chroot bugs (no PID-1 systemd): guarded `systemctl` calls, explicit `/var/lib/rnfleet` mkdir, offline wizard-enable symlink, unattended pre-seed path

✅ **Appliance branding + interactive first-boot wizard** (2026-06-23):
- ASCII globe logo + captions (`Global Secure Access` / `Remote Network Appliance` / `Version 1`) in the console MOTD + wizard header; single source `rnfleet-logo.txt`, installed to `/etc/rnfleet/logo.txt` by both the bare-metal provisioner and the Azure Packer template
- `FIRSTBOOT_INTERACTIVE=true` pre-seed flag shows the wizard pre-filled (review/override each value) instead of silent enrollment; per-field `Use "X"? [Y/n]` validation + final apply confirmation
- Docs: post-enrollment changes (`rnfleet-setup --force` / edit `device-runtime.env`) + on-device GSA tunnel/BGP/egress verification in `infra/bare-metal/iso/README.md`

---

## 🎯 Next 48-Hour Priority Work

### Phase 6: IPSec + BGP (HIGHEST PRIORITY) 🔄

**What's done**:
- ✅ `apps/device-runtime/src/agents/tunnel/index.js` — strongSwan + FRR config writer + BGP state reader
- ✅ Structured tunnel schema: `gsa.{endpoint,asn,bgpAddress,region}` + `peer.{endpoint,asn,bgpAddress,localNetworks[]}`
- ✅ `validateTunnelConfig()` in contracts, wired to config-push endpoint
- ✅ `bgpSessionState` in heartbeat, stored in control-plane, rendered in portal BGP column
- ✅ Entra Graph API JSON paste-and-fill in portal tunnel form
- ✅ `sample-config.md` with real sample + architecture diagram

**Remaining**:
1. **Packer image update** ✅ DONE
   - `strongswan-swanctl` + `frr` installed in `ubuntu-appliance.pkr.hcl` provisioner
   - `frr` (+ `bgpd`) and `strongswan` services enabled at boot; `vtysh` available
   - Image bakes the latest `apps/device-runtime` source (incl. tunnel-agent fixes)

2. **Live IPSec tunnel test** ✅ DONE (device-005, GSA remote network `NewLink1`/`Link1`)
   - Pushed tunnel config via control-plane; runtime brought up `rnfleet-gsa`
   - `swanctl --list-sas` shows IKE **ESTABLISHED** + CHILD_SA **INSTALLED**
     (`AES_CBC_256/HMAC_SHA2_384/MODP_2048`, ESP `AES_GCM_16_256`)

3. **BGP session validation** ✅ DONE
   - FRR starts with generated config; `vtysh -c "show bgp summary"` shows peer **established**
   - 66 GSA-advertised prefixes received and installed via `ipsec-gsa`
   - Portal BGP column flips to `established`

4. **Audit trail for tunnel events** ✅ DONE
   - `tunnel_up`/`tunnel_down`/`bgp_established`/`bgp_down` events emitted with `bgpSessionState`

**Bug fixes during live validation** (device-runtime):
- `managementHealthy()` no longer pings the default gateway (Azure VNet gateway never
  answers ICMP → false watchdog reverts that tore down `ipsec-gsa` + SA every apply)
- Heartbeat now reports **live** SA/BGP status instead of the apply-time snapshot
- `readBgpSessionState()` recognizes FRR's numeric-`PfxRcd` established representation

---

### Phase 5D: Network Telemetry & Real State Parsing ✅ COMPLETE

**Status**: All success criteria met.

- ✅ Real WAN/LAN telemetry visible in portal
- ✅ WAN public IP resolved and displayed
- ✅ LAN apply with two-phase rollback safety
- ✅ Responsive portal UX, split config sections

---

### Phase 5C (Completed): Fleet-Wide Foundations

**Completed**:

1. ✅ Deployed and stabilized 4-device fleet in westus3
2. ✅ Resolved registration issue for devices 002-004
3. ✅ Portal API now reports all 4 devices online

### Phase 5C: Multi-Device & Scaling (HIGH) ✅

**Goal**: Validate concurrent device management, independent state, and fleet-wide operations.

**Acceptance Criteria**:
- [x] Deploy 3 additional test VMs (4 devices total)
- [x] Each registers with unique DEVICE_ID
- [x] Portal shows all 4 devices independently
- [ ] Config push to subset works (e.g., devices 1-2 only)
- [x] Each device maintains own state (config version, tunnel status)
- [ ] Jobs for device-1 don't affect device-2

**Tasks**:
1. **Deploy 3 more VMs** (5 min each = 15 min total)
   - device-002, device-003, device-004
   - Each in separate vnet subnet (or same vnet, different IPs)
   - Configure unique DEVICE_ID and SITE_ID
   - Verify each registers independently

2. **Test fleet-wide config push** (10 min)
   - Push config to all 4 devices
   - Verify all apply independently
   - Check audit shows 4 separate events

3. **Test fleet health dashboard** (10 min)
   - View portal device list
   - Verify all 4 visible with independent status
   - Verify filtering/sorting by status

---

### Phase 5D: Network Telemetry (MEDIUM) 🔄

**Goal**: Replace mocked network state with real OS data.

**Current State**: Runtime now parses `ip addr` and `ip route`; portal now renders WAN/LAN IP and route count.

**Changes Needed**:

1. **Device runtime integration** (40 min) ✅
   - Parse `ip addr show` to extract eth0/eth1 IPs
   - Parse `ip route` to detect WAN/LAN routing
   - Parse `strongswan status` (when installed) for real tunnel state
   - Report actual values in heartbeat

2. **Update device heartbeat schema** (10 min) ✅
   - Add `networkState: { wanIp, lanIp, wanRoutes, lanRoutes }`
   - Add `tunnelMetrics: { tunnelState, bytesIn, bytesOut }`

3. **Update portal to display telemetry** (15 min) ✅
   - Show network card IPs in device detail view
   - Show tunnel bytes transferred
   - Show route table snippet

---

## 🚀 Weeks 2-4: Foundation for Production

### Phase 6: Real IPSec Integration (2-3 days) ✅ VALIDATED
- ✅ Tunnel agent: strongSwan + FRR config writer + BGP state reader
- ✅ Structured `gsa`/`peer` tunnel schema in contracts
- ✅ BGP session state end-to-end in portal
- ✅ Install strongSwan + FRR in Packer image
- ✅ Live tunnel bring-up test vs GSA VPN gateway (device-005, ESTABLISHED)
- ✅ BGP session establishment + route exchange validation (66 prefixes)

### Phase 7: Database & Persistence (2-3 days)
- Replace file-based store with Postgres (or Cosmos)
- Add schema for devices, configs, jobs, audit
- Implement data migrations framework
- Test multi-instance control-plane (scale out)

### Phase 8: Per-Device Identity (2 days)
- Replace PSK with per-device certificates
- Integrate Azure Key Vault for cert storage
- Add device enrollment flow
- Add certificate rotation automation

### Phase 9: Observability & Safety (3 days)
- Structured logging (correlation IDs, trace spans)
- Metrics export (Prometheus/ApplicationInsights)
- Health checks and automated rollback
- Canary/staged deployment mechanics

### Phase 10: Hardening & Ops (2-3 days)
- Security audit (RBAC, input validation, secret handling)
- CI/CD pipeline (GitHub Actions or Azure DevOps)
- Disaster recovery runbook
- Load testing (100+ devices)

---

## 📊 Success Metrics (Current MVP)

| Metric | Target | Current | Status |
|--------|--------|---------|--------|
| Device registration latency | <2s | ~1s | ✅ |
| Heartbeat frequency | 10s | 10s | ✅ |
| Config push to apply | <20s | ~15s (2 polls) | ✅ |
| Job execution latency | <10s | ~10s | 🔄 Testing |
| Fleet size | 1000+ devices | 4 devices | ✅ Phase 5C |
| Data persistence | Postgres | JSON files | 🚧 Phase 7 |
| Per-device auth | Certs | PSK shared | 🚧 Phase 8 |

---

## 🎯 Release Criteria

### MVP Release (Now - this week)
- [x] Core control-plane API (register, config, jobs)
- [x] Portal UI (device list, config push, job creation)
- [x] Device agent loop (register, fetch, apply, report)
- [x] Cloud deployment (Azure App Services)
- [x] Appliance image (Packer, Ubuntu 24.04, Node.js 22)
- [x] E2E test (device deployed, registered, heartbeating)
- [x] Config push E2E test
- [x] Multi-device test

### Closed Beta (Next 1-2 weeks)
- [ ] Real network telemetry (IP addrs, routes, tunnel state)
- [x] Real IPSec integration (strongSwan, BGP)
- [ ] Multiple devices concurrent management
- [ ] Audit trail export
- [ ] Health dashboard
- [ ] Critical LAN change workflow hardening (canary + maintenance window)

### Open Beta / Production (Weeks 3-4)
- [ ] Database persistence (Postgres/Cosmos)
- [ ] Per-device identity (certificates)
- [ ] RBAC and operator roles
- [ ] Disaster recovery procedures
- [ ] Load testing (100+ devices)

---

## 🔧 Technical Debt & Known Issues

### Pre-Alpha Limitations
- [ ] File-based store not thread-safe (single App Service only)
- [ ] PSK shared across all devices (security risk)
- [x] Network telemetry mocked (hardcoded values)
- [x] IPSec/BGP integrated and validated end-to-end (real strongSwan + FRR; tunnel status is live-probed, no longer always "up")
- [ ] No database schema version management
- [ ] No encryption at rest for config/credentials
- [ ] Device-to-control-plane communication not mTLS

### Performance Considerations
- [ ] Polling interval hardcoded to 10s (tunable needed)
- [ ] Config file I/O on every heartbeat (cache strategy)
- [ ] No rate limiting on portal API calls
- [ ] No circuit breaker for cloud service failures

### Operational Readiness
- [ ] No centralized logging aggregation
- [ ] No alerting on device offline/tunnel-down
- [ ] No automatic failover for control-plane
- [ ] No zero-downtime deployment strategy

---

## 📅 Timeline Estimate

| Phase | Duration | Status | 
|-------|----------|--------|
| Phase 5A: Deploy & Register | ✅ 4 hours | Complete |
| Phase 5B: Config & Jobs | ✅ 1-2 hours | Complete |
| Phase 5C: Multi-Device | ✅ 1-2 hours | Complete |
| Phase 5D: Network Telemetry | ✅ Complete | Complete |
| Phase 6: IPSec Integration | ✅ Validated | Complete |
| Phase 7: Database | ⏳ 2-3 days | Week 2 |
| Phase 8: Per-Device Identity | ⏳ 2 days | Week 2 |
| Phase 9: Observability | ⏳ 3 days | Week 2-3 |
| Phase 10: Hardening | ⏳ 2-3 days | Week 3 |

**Estimated MVP to Production**: 3-4 weeks

---

## 🔗 Related Files

- `status.md` — Real-time progress tracker
- `docs/architecture/system-overview.md` — System design
- `agents.md` — Implementation context for AI agents
- `docs/requirements/appliance-requirements-gsa-remote-network.md` — GSA spec
