<div align="center">

# RNFleetManager

### Centralized fleet management for secure Linux edge appliances

Onboard, configure, and operate a fleet of Linux edge appliances that establish **IPSec + BGP
tunnels to Microsoft Global Secure Access (GSA)** remote networks — from a single, policy-driven
control plane, with safe rollouts and automatic rollback.

[![Node](https://img.shields.io/badge/Node-18%2B-339933?logo=node.js&logoColor=white)](https://nodejs.org)
[![Monorepo](https://img.shields.io/badge/Monorepo-npm_workspaces-CB3837?logo=npm&logoColor=white)](#-repository-layout)
[![Deploy: Vercel](https://img.shields.io/badge/Deploy-Vercel-000000?logo=vercel&logoColor=white)](#️-deployment)
[![GSA Validated](https://img.shields.io/badge/GSA_IPSec%2BBGP-validated_end--to--end-2EAD33)](#-secure-tunnel-gsa--device-agnostic)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

[Overview](#what-is-rnfleetmanager) · [Architecture](#-architecture) · [Secure Tunnel](#-secure-tunnel-gsa--device-agnostic) · [Quick Start](#-run-the-mvp-locally) · [Deployment](#️-deployment) · [Security](#-security-model)

</div>

---

## What is RNFleetManager?

**RNFleetManager** is a fleet-management platform for **Linux-based edge appliances** (dual-NIC mini
PCs, Raspberry Pis, bare-metal CPE, or cloud VMs). It handles the full lifecycle — zero-/low-touch
onboarding, remote configuration, secure tunnel management, and fleet observability — while keeping
every appliance connected to a Microsoft Global Secure Access remote network over a self-healing
**IPSec + BGP** data plane.

It is built as a clean, contract-first monorepo with three deployable planes — a **device runtime**,
a **control plane**, and an **operator portal** — and a strict rule that core product logic stays
**cloud-agnostic** while provider-specific assets live under `infra/cloud/<provider>/`.

> **Why it exists:** connecting an edge site to GSA is easy to do once by hand and hard to do
> *reliably at scale*. RNFleetManager makes the tunnel, the routing, and the device configuration
> **declarative, versioned, signed, and rollback-safe** — so a fleet of appliances stays healthy
> without on-site hands.

---

## Table of Contents

- [✨ Highlights](#-highlights)
- [🏗 Architecture](#-architecture)
- [🔐 Secure Tunnel (GSA) — device-agnostic](#-secure-tunnel-gsa--device-agnostic)
- [🗂 Repository Layout](#-repository-layout)
- [🧭 Core Design Principles](#-core-design-principles)
- [🚀 Run the MVP Locally](#-run-the-mvp-locally)
- [☁️ Deployment](#️-deployment)
- [🛡 Critical LAN Change Safety](#-critical-lan-change-safety)
- [🔒 Security Model](#-security-model)
- [📚 Documentation](#-documentation)
- [✅ Project Status](#-project-status)
- [🤝 Contributing](#-contributing)
- [📄 License](#-license)

---

## ✨ Highlights

| Capability | What it does |
|---|---|
| **Zero-/low-touch onboarding** | Appliances enroll and claim identity on first boot — including an interactive first-boot wizard and a provider-agnostic installer ISO. |
| **Declarative desired-state config** | Fleet behavior is versioned, schema-validated, and signed before it reaches a device. |
| **Self-healing GSA tunnel** | Route-based IPSec (strongSwan/swanctl) + eBGP (FRR) to a GSA remote network, with a watchdog that auto-reverts on lost management connectivity. |
| **Safe rollouts & rollback** | Two-phase device apply, health-gated convergence, and automatic rollback to last-known-good. |
| **Fleet observability** | Live telemetry (WAN/LAN interfaces, IPs, routes, tunnel & BGP session state) surfaced in the portal. |
| **Operator portal** | Device inventory, IP/tunnel configuration, Entra GSA JSON import, rollout controls, and a filterable audit log. |
| **Cloud-agnostic core** | Runs on bare metal, Raspberry Pi, or any cloud VM; Azure-specific assets stay isolated under `infra/cloud/azure/`. |

---

## 🏗 Architecture

Three independent planes communicate through versioned contracts:

```
            ┌──────────────────────────┐
            │     Operator Portal       │   apps/portal
            │  inventory · config · RBAC │   (web UI + API)
            └────────────┬──────────────┘
                         │  versioned contracts
            ┌────────────▼──────────────┐
            │      Control Plane         │   apps/control-plane
            │  registry · desired-state  │   (stateless API)
            │  jobs · telemetry · audit  │
            └────────────┬──────────────┘
                         │  register · pull config · heartbeat
            ┌────────────▼──────────────┐
            │     Device Runtime         │   apps/device-runtime
            │  bootstrap · network agent │   (Linux edge appliance)
            │  tunnel agent · watchdog   │
            └────────────┬──────────────┘
                         │  IPSec + BGP (strongSwan + FRR)
            ┌────────────▼──────────────┐
            │  Microsoft Global Secure   │
            │     Access remote network  │
            └────────────────────────────┘
```

| Plane | Responsibilities |
|---|---|
| **`apps/control-plane`** | Device registry & lifecycle state · desired-state config authoring/versioning · job orchestration (push/apply/rotate/restart) · telemetry ingestion · audit trails. |
| **`apps/device-runtime`** | Bootstrap & enrollment · management agent (control-plane sync) · network agent (WAN/LAN roles, routing/firewall) · tunnel agent (IPSec lifecycle) · watchdog with last-known-good rollback. |
| **`apps/portal`** | Fleet inventory/status · policy/profile management · rollout controls with blast-radius awareness · RBAC-aware operations and audit visibility. |

Shared, cloud-agnostic logic lives in `packages/` — `contracts` (versioned schemas), `policy-engine`
(layered config merge), `device-sdk`, and `shared` utilities.

---

## 🔐 Secure Tunnel (GSA) — device-agnostic

The device runtime establishes an IPSec tunnel to a Microsoft Global Secure Access remote network
and peers with it over BGP. The design depends only on portable Linux primitives, so it runs
identically on bare metal, a Raspberry Pi, or a VM on any cloud.

- **strongSwan via swanctl/vici** — connections/secrets render to `/etc/swanctl/swanctl.conf`; the
  agent uses `swanctl` (not the legacy `ipsec.conf` starter) because only vici reliably honors
  `if_id`.
- **Route-based XFRM interface (`ipsec-gsa`)** — the child SA is bound by `if_id`, so even though
  GSA requires `0.0.0.0/0` traffic selectors, **only traffic routed to `ipsec-gsa` is encrypted** —
  management traffic is never hijacked.
- **eBGP inside the tunnel (FRR)** — single-hop eBGP exchanges prefixes dynamically, installing only
  GSA-advertised ranges into the kernel (split-tunnel).
- **Self-heal watchdog** — verifies management connectivity after every apply and auto-reverts the
  tunnel if it's lost. No cloud API or out-of-band rescue required.

> **Status:** validated end-to-end against a live GSA remote network — IKE/IPSec SA established,
> route-based `ipsec-gsa` interface up, and eBGP established with GSA-advertised prefixes installed
> (split-tunnel). Cloud-specific tooling (Azure NSGs, `az`, Serial Console) is **test/recovery
> scaffolding only** and is never baked into the shipped agent.

See [`docs/architecture/system-overview.md`](docs/architecture/system-overview.md) and
[`apps/device-runtime/README.md`](apps/device-runtime/README.md).

---

## 🗂 Repository Layout

```text
RNFleetManager/
├─ apps/                      # deployable products
│  ├─ control-plane/          # registry, desired-state, jobs, telemetry, audit (API)
│  ├─ device-runtime/         # edge appliance agent loop + packaging (systemd, first-boot)
│  └─ portal/                 # operator web UI + API
├─ packages/                  # shared, cloud-agnostic libraries
│  ├─ contracts/              # versioned schemas (registration, config, jobs, telemetry)
│  ├─ device-sdk/             # device ↔ control-plane communication primitives
│  ├─ policy-engine/          # layered desired-state config merge
│  └─ shared/                 # logging, error models, utilities
├─ infra/                     # infrastructure-as-code & deployment assets
│  ├─ bare-metal/iso/         # provider-agnostic appliance installer ISO (Ubuntu autoinstall)
│  └─ cloud/azure/            # Azure-only assets (kept isolated from product code)
├─ operations/                # runbooks, incident management, compliance
├─ docs/                      # architecture, ADRs, requirements
└─ scripts/                   # repeatable developer/CI automation
```

**Strict separation rule:** product logic lives in `apps/*` and `packages/*`; provider-specific
deployment assets live in `infra/cloud/<provider>/*`.

---

## 🧭 Core Design Principles

1. **Domain separation** — device, control plane, and UI evolve independently.
2. **Contract-first** — all cross-service communication uses versioned schemas in `packages/contracts`.
3. **Policy-driven** — fleet behavior is declarative desired-state config.
4. **Operational safety** — staged rollouts, signed configs, health checks, rollback-first workflows.
5. **Scale-ready** — async job orchestration and stateless control-plane components.
6. **Cloud separation** — provider-specific assets stay isolated under `infra/cloud/*` (Azure-first today).

---

## 🚀 Run the MVP Locally

A runnable end-to-end MVP is included: control-plane API, portal UI, and the device-runtime agent
loop. For fast local E2E, API calls use a shared pre-shared-key header (`x-fleet-psk`, default
`dev-fleet-psk`).

### Prerequisites

- Node.js 18+

### Install & start (separate terminals)

```bash
npm install

npm run start:control-plane   # API on http://localhost:4000
npm run start:portal          # UI  on http://localhost:4100
npm run start:device          # device-runtime agent loop
```

Open the portal at **http://localhost:4100**, using API base `http://localhost:4000` and PSK
`dev-fleet-psk`.

### End-to-end flow you can exercise

1. Device registers to the control-plane.
2. Device pulls desired config and applies it.
3. Device sends a heartbeat with tunnel status.
4. Portal shows live device status.
5. Portal pushes config and dispatches jobs (`restart_tunnel`, `run_diagnostics`, `apply_config`).

> The PSK header is a **local-development convenience**. Production uses the certificate-backed,
> mTLS-based [security model](#-security-model).

---

## ☁️ Deployment

RNFleetManager runs anywhere Node.js does. Common targets:

| Target | Notes |
|---|---|
| **Vercel (control-plane + portal)** | Each app deploys as its **own Vercel project** from this one repo, pinned to its Root Directory (`apps/control-plane`, `apps/portal`). See [`docs/vercel-deployment.md`](docs/vercel-deployment.md) for root dirs, env vars, the per-project *Ignored Build Step* (`scripts/vercel-ignore.sh`), and the in-memory-storage caveat. |
| **Bare-metal appliance ISO** | Provider-agnostic Ubuntu autoinstall image under [`infra/bare-metal/iso/`](infra/bare-metal/iso/) — validated installing to a live GSA tunnel/BGP off-cloud. |
| **Azure** | Azure-specific image build and environments under [`infra/cloud/azure/`](infra/cloud/azure/), kept isolated from core product code. |

---

## 🛡 Critical LAN Change Safety

LAN IP/subnet updates are treated as **critical changes** and use a safe apply pipeline:

1. **Control-plane validation** — reject invalid ranges / interface/IP/prefix conflicts early.
2. **Two-phase device apply** — `prepare → commit`, with post-apply interface/connectivity verification.
3. **Automatic rollback** — restore last-known-good config on failure and report the reason.
4. **Portal guardrails** — explicit operator confirmation and per-device last-apply outcome.

---

## 🔒 Security Model

- **Per-device identity** — certificate-backed identity preferred.
- **mTLS** for device ↔ control-plane communication (PSK is local-dev only).
- **Least-privilege RBAC** for operators and services.
- **Signed config** and signed sensitive remote actions.
- **Full audit trail** for every config and action change.

---

## 📚 Documentation

| Document | Purpose |
|---|---|
| [`agents.md`](agents.md) | Comprehensive project/agent context and conventions. |
| [`docs/architecture/system-overview.md`](docs/architecture/system-overview.md) | System design and the GSA data plane. |
| [`docs/architecture/project-structure.md`](docs/architecture/project-structure.md) | Repository layout reference. |
| [`docs/adr/`](docs/adr/) | Architecture Decision Records (e.g. monorepo domain boundaries). |
| [`docs/requirements/appliance-requirements-gsa-remote-network.md`](docs/requirements/appliance-requirements-gsa-remote-network.md) | GSA remote-network appliance requirements. |
| [`docs/vercel-deployment.md`](docs/vercel-deployment.md) | Two-project Vercel deployment walkthrough. |

---

## ✅ Project Status

The end-to-end data plane has been **validated against a live GSA remote network** — IPSec SA
established, route-based `ipsec-gsa` interface up, and eBGP established with GSA-advertised prefixes
installed (split-tunnel) — across a multi-device test fleet, plus a bare-metal appliance ISO
validated on Hyper-V. This is an actively evolving project; expect APIs and storage to change as it
moves toward production hardening (persistent storage, per-device identity, observability).

---

## 🤝 Contributing

Contributions, issues, and feature requests are welcome.

1. Fork and create a feature branch.
2. Keep changes inside the right domain boundary (`apps/*` / `packages/*` for product logic,
   `infra/cloud/<provider>/*` for provider assets).
3. Run `npm run check` and ensure services still start.
4. Update architecture docs / ADRs when boundary-level decisions change.
5. Open a Pull Request with a clear description.

See [`agents.md`](agents.md) for the full set of engineering conventions.

---

## 📄 License

[MIT](LICENSE) — free to use, fork, and modify.
