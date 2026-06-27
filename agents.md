# RNFleetManager Agent Context

This document gives implementation agents full project context so work stays consistent, scalable, and cloud-portable.

## 1) Project Mission

RNFleetManager manages Linux edge appliances (mini PCs with WAN/LAN NICs), establishes secure network connectivity (including IPSec scenarios to Microsoft Global Secure Access), and enables centralized remote lifecycle management.

## 2) Product Scope

### Core outcomes

- Zero-touch or low-touch device onboarding
- Remote registration and configuration management
- Deterministic WAN/LAN behavior on dual-NIC devices
- Secure tunnel lifecycle management
- Fleet observability, auditability, and safe rollouts

### Non-goals (for now)

- Hard lock-in to a single cloud provider
- Rich local device UI beyond minimal recovery/status

## 3) Repository Boundaries

```text
apps/         # deployable systems
packages/     # shared contracts and libraries
infra/        # deployment/infrastructure assets
operations/   # runbooks, incident, compliance
docs/         # architecture + ADRs
scripts/      # repeatable automation
```

### Strict separation rule

- Product logic belongs in `apps/*` and `packages/*`.
- Provider-specific deployment assets belong in `infra/cloud/<provider>/*`.

## 4) Application Responsibilities

## `apps/control-plane`

- Device registry and lifecycle state
- Desired-state config authoring/versioning
- Job orchestration (push/apply/rotate/restart)
- Telemetry ingestion and health tracking
- Audit trails and operator action history

## `apps/device-runtime`

- Bootstrap + claim/enrollment
- Management agent for control-plane sync
- Network agent for WAN/LAN roles, routing/firewall
- Tunnel agent for IPSec lifecycle
- Watchdog + safety rollback to last-known-good

## `apps/portal`

- Fleet inventory/status views
- Policy/profile management UX
- Rollout controls and blast-radius awareness
- RBAC-aware operations and audit visibility

## 5) Shared Packages

## `packages/contracts`

- Versioned schemas for:
  - registration
  - desired-state config
  - command/jobs
  - telemetry envelopes

## `packages/policy-engine`

- Layered config merge:
  - global baseline
  - environment/site profile
  - device override
  - emergency override
- Capability targeting and conflict validation

## `packages/device-sdk`

- Secure device/control-plane communication primitives
- Retry/backoff and message handling helpers

## `packages/shared`

- Logging, typed error models, utility primitives

## 6) Configuration Model (Authoritative)

All fleet behavior must be represented as versioned desired-state config.

### Requirements

- Schema-validated before publish
- Signed before delivery to devices
- Applied idempotently on device
- Rollback on failed convergence/health checks

## 7) Security Baseline

- Per-device identity (certificate-backed preferred)
- mTLS for device/control-plane communication
- Least-privilege RBAC for operators and services
- Signed config and signed sensitive remote actions
- Full audit trail for all config/action changes

## 8) Azure-First Deployment Context

Azure is the first deployment target, while the product remains cloud-agnostic.

### Current Azure target

- Subscription: `bf9a0b19-cd7b-4515-ba71-0495728d691c`
- Resource Group: `RNFleet`

### Azure assets location

```text
infra/cloud/azure/
  environments/{dev,staging,prod}
  bootstrap/
  pipelines/
```

Do not place Azure-specific assumptions in core domain code.

## 9) Delivery and Scalability Principles

1. Contract-first interfaces across all components.
2. Stateless scale-out for API surfaces.
3. Queue-based orchestration for fleet jobs.
4. Safe progressive rollout (small canary -> broader waves).
5. Health-gated deployment with automated rollback.

## 10) Expected Engineering Conventions

- Keep modules aligned to domain responsibilities.
- Prefer explicit typed contracts over implicit coupling.
- Avoid cross-app direct imports; use `packages/*`.
- Keep infrastructure concerns out of product runtime logic.
- Update architecture docs/ADR when boundary-level decisions change.

## 11) Project Status & Planning Files (MUST READ FIRST)

### 🎯 Quick Start for Agents

**Always start by reading these three files in order:**

1. **`status.md`** (root) — **CURRENT STATE SNAPSHOT**
   - **Purpose**: Real-time project progress, completion checklist, blockers
   - **Read when**: Starting any work session
   - **Contains**:
     - Current phase and milestone status (✅ Complete, 🔄 In Progress, 🚧 Blocked)
     - Summary of what's been done (Phases 1-5)
     - Cloud endpoint URLs and credentials
     - Immediate next steps with priority colors (🔴 Critical, 🟡 High, 🟠 Medium, 🟢 Low)
     - **CURRENT**: Phase 5C completion details (4-device fleet online in westus3)
     - Known limitations and open blockers
     - Success metrics and key numbers
   - **Update frequency**: After each major milestone or phase completion
   - **Last update**: Phase 6 validated end-to-end (live GSA tunnels device-005/006) + bare-metal appliance ISO validated on Hyper-V (provider-agnostic install → live GSA tunnel/BGP off Azure) + appliance branding & interactive first-boot wizard (ASCII logo, `FIRSTBOOT_INTERACTIVE`, per-field Y/n confirmation, post-enrollment & BGP-verification docs)

2. **`plan.md`** (root) — **ROADMAP & TASK BREAKDOWN**
   - **Purpose**: Detailed 48-hour priorities, Phase breakdown, timeline estimates
   - **Read when**: Starting a new phase or need to understand dependencies
   - **Contains**:
     - **CURRENT**: Phase 5D immediate actions (real telemetry parsing + schema + portal display)
     - Phase 5C completion criteria and verification
     - Weeks 2-4 roadmap (Phases 6-10 with time estimates)
     - Release criteria (MVP → Closed Beta → Open Beta → Production)
     - Technical debt and known issues
     - Timeline estimates by phase
     - SQL todo tracking (see below)
   - **Update frequency**: Every 2 days or when scope changes
   - **Last update**: Phase 6 IPSec/BGP validated; Entra JSON import in portal; bare-metal ISO build (`infra/bare-metal/iso/`) added + validated on Hyper-V; appliance logo + interactive first-boot wizard (`FIRSTBOOT_INTERACTIVE`, per-field confirmation)

3. **`docs/requirements/healthcheck.md`** — **REQUIREMENTS DRIFT DETECTION**
   - **Purpose**: Monitor GSA appliance requirements from Microsoft Learn for breaking changes
   - **Read when**: Starting week-long cycles to detect MS doc updates
   - **Contains**:
     - Baseline metadata (MS Learn doc IDs, versions, snapshot dates)
     - Procedure for running healthcheck (curl + diff against baseline)
     - List of 10 appliance requirements with document citations
     - Change detection results and impact analysis
   - **Update frequency**: Weekly or when new requirements suspected

### 📊 SQL Todo Tracking

The session database (`~/.copilot/session-state/*/session.db`) contains two tables:

- **`todos`** table: Tasks for current and next phases
  - Columns: `id`, `title`, `description`, `status` (pending/in_progress/done/blocked), `created_at`, `updated_at`
  - Query ready todos: `SELECT * FROM todos WHERE status='pending' AND NOT EXISTS (SELECT 1 FROM todo_deps td JOIN todos t2 ON td.depends_on=t2.id WHERE td.todo_id=todos.id AND t2.status!='done')`
  - **Current status**: 11 done, 1 pending (`ipsec-integration-plan`)

- **`todo_deps`** table: Task dependencies (todo_id → depends_on)
  - Use to enforce task ordering
  - Example: config-push-test must complete before job-execution-test
  - **Current**: `ipsec-integration-plan` is the only remaining pending task

### 🔄 Phase 5C Current Status & What Changed

**PHASE 5C COMPLETED**:
- **Issue resolved**: Devices 002-004 registration failure
- **Action taken**: Reconfigured per-device runtime env, corrected systemd service path, restarted runtime services
- **Current state**: `device-001`..`device-004` online in `/api/v1/portal/devices`
- **Region state**: All test VMs deployed in **westus3** only

**Telemetry Work Now Active (Phase 5D)**:
- Device runtime parses `ip -o -4 addr show` + `ip route show`
- Heartbeat now carries `networkState` with interface/IP/route snapshot
- Control-plane stores network telemetry from heartbeat
- Portal displays WAN interface+IP, WAN public IP, LAN IP, route count, and adapter details
- Portal forms split by config domain: Device Configuration (IP) and Tunnel Configuration

**Impact on Roadmap**:
- Phase 5C unblocked and complete
- Fleet-wide validation baseline established (4 active devices)
- Phase 5D (real telemetry) is now the critical path

**Current Phase 5B/5C/5D todos**:
```sql
-- See what's ready to start:
SELECT id, title FROM todos 
WHERE status='pending' 
ORDER BY id;

-- Mark todo in progress:
UPDATE todos SET status='in_progress' WHERE id='config-push-test';

-- Mark todo complete:
UPDATE todos SET status='done' WHERE id='config-push-test';
```

### 🔗 Documentation Hierarchy

```
agents.md (THIS FILE - comprehensive agent context)
├─ status.md (snapshot of right now)
├─ plan.md (detailed roadmap + SQL todos)
├─ docs/requirements/healthcheck.md (requirement drift detection)
├─ docs/architecture/system-overview.md (system design)
├─ docs/architecture/project-structure.md (repo layout)
└─ docs/requirements/appliance-requirements-gsa-remote-network.md (GSA spec)
```

## 12) Monitoring & Status Tracking (DETAILED)

### Real-time Status (`status.md`)
- **What it's for**: Quick snapshot of what phase we're in and what's blocking progress
- **When to update**: After major milestones (phase completion, major blocker discovery)
- **Key sections**:
  - Completion status by phase (visual progress)
  - Technical state (auth method, persistence, network integration level)
  - Immediate next steps with color-coded priority
  - Known limitations with checkbox tracking

### Project Planning (`plan.md`)
- **What it's for**: Detailed task breakdown, dependencies, timeline, release criteria
- **When to update**: Every 2 days or when phase scope changes
- **Key sections**:
  - Current 48-hour priority work (Phase 5B/5C/5D) with acceptance criteria
  - Weeks 2-4 roadmap (Phases 6-10) with time estimates
  - Success metrics table (latency, fleet size, auth method, etc.)
  - Release criteria checklist (MVP → Closed Beta → Open Beta → Production)
  - Timeline estimate by phase (total ~3-4 weeks to production)

### Requirements Health (`docs/requirements/healthcheck.md`)
- **What it's for**: Detect if Microsoft's GSA appliance requirements have changed
- **When to update**: Weekly or when you suspect MS docs changed
- **Key sections**:
  - Baseline metadata snapshot (doc IDs, versions, dates from last check)
  - Manual health-check procedure (curl the docs, compare)
  - 10 appliance requirements with links and implementation notes
  - Change detection procedure and impact analysis

---

## 13) Current Phase Context (as of 2026-06-20 19:51 UTC-4)

### Phase 6: IPSec + BGP Integration
**Status**: ✅ Phase 5A–5D complete, 🔄 Phase 6 in progress

**What's done**:
- Tunnel agent written: generates **swanctl/vici** + FRR configs, drives `swanctl`
  (`--load-all`/`--initiate`/`--terminate`/`--list-sas`), reads live BGP via `vtysh`
- Route-based **XFRM-interface** mode (`ipsec-gsa`, bound by `if_id`) so the required
  `0.0.0.0/0` selectors never hijack management traffic; `install_routes = no` drop-in
- Portable self-heal **watchdog** auto-reverts the tunnel if management connectivity is lost
- Config-driven IKE/ESP crypto mapped from the Azure custom IPSec/IKE policy
- `TUNNEL_PSK` decoupled from control-plane `FLEET_PSK`
- Structured `gsa`/`peer` tunnel schema in contracts + `validateTunnelConfig()` wired to server
- `bgpSessionState` tracked end-to-end: device → heartbeat → control-plane → portal BGP column
- Portal has full Tunnel & BGP form with Entra Graph API JSON import
- Portal **audit log category filters** (Device, Config, Tunnel/BGP, Action)
- Packer image installs `strongswan-swanctl` + `charon-systemd` + `frr`, enables `strongswan` (not the legacy starter)
- `sample-config.md` with real Entra connectivity JSON + architecture diagram

**What's next**:
1. **Live tunnel test** — on a test device, push config from portal, verify
   `swanctl --list-sas` shows the SA installed and management SSH stays up
2. **BGP validation** — verify `vtysh` shows session `Established`
3. **Audit events** — `tunnel_up`/`tunnel_down` in audit trail

**Key files added/changed this session**:
- `apps/device-runtime/src/agents/tunnel/index.js` — new tunnel agent
- `apps/control-plane/src/contracts.js` — structured gsa/peer schema + validateTunnelConfig
- `apps/control-plane/src/server.js` — bgpSessionState in heartbeat, deep tunnel merge
- `apps/device-runtime/src/agent.js` — applyTunnelConfig + bgpSessionState in heartbeat
- `apps/portal/src/web/index.html` — BGP column, Tunnel & BGP form, Entra JSON import
- `sample-config.md` — real Entra GSA connectivity config sample + architecture diagram

---

## 14) Immediate Next Implementation Milestones

**Phase 6: IPSec + BGP** (THIS WEEK)
- Add strongSwan + FRR to Packer image
- Push tunnel config from portal → verify ipsec connection up
- Verify BGP session establishes (vtysh shows Established)
- Emit tunnel_up/down events in audit trail

**Phase 7: Database & Persistence** (Next week)
- Replace file-based store with Postgres or Cosmos DB
- Add schema migrations framework
- Enable multi-instance control-plane scale-out

**Phase 8+: Per-Device Identity, Observability, Hardening**
- See `plan.md` for detailed roadmap and time estimates

## 15) Critical LAN IP/Subnet Change Policy (NEW)

LAN IP/subnet changes are **critical operations** and must follow this sequence:

1. **Validate in control-plane**
   - Required fields: lan interface, IPv4, prefix length.
   - Reject invalid ranges/conflicts early.

2. **Two-phase device apply**
   - `prepare`: collect current LAN config + sanity checks.
   - `commit`: apply new LAN address and verify interface state/connectivity.

3. **Rollback on failure**
   - If verification fails, restore prior LAN address immediately.
   - Emit explicit rollback reason in heartbeat and audit.

4. **Portal guardrails**
   - Show critical warning and require explicit confirmation.
   - Display last apply outcome (success/rolled back) per device.
