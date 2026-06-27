# Control Plane

Central management service for device identity, policy/config lifecycle, rollouts, and fleet operations.

## Module Responsibilities

- `src/api`: public and internal endpoints
- `src/auth`: mTLS/OIDC/token validation and RBAC
- `src/registry`: device records, capabilities, lifecycle state
- `src/config`: desired-state templates, versions, signatures
- `src/jobs`: rollout plans, execution queue, retries
- `src/telemetry`: heartbeat, health, and metrics ingestion
- `src/audit`: append-only operational event history

## Non-Functional Goals

- Stateless horizontal scale
- Idempotent job execution
- Full auditability for all config and action paths

## MVP Runtime Notes

- Start with: `npm run start:control-plane` (from repository root)
- Default port: `4000`
- Authentication: shared PSK header `x-fleet-psk` (default `dev-fleet-psk`)

## Storage Drivers

State (devices, configs, jobs, audit) is held behind a small store abstraction
(`src/store.js`) with two drivers:

| Driver   | Selected when                                  | Persistence |
| -------- | ---------------------------------------------- | ----------- |
| `file`   | default off-Vercel (or `STORE_DRIVER=file`)    | `data/store.json` on a writable disk (local dev, Azure App Service, bare metal) |
| `memory` | default on Vercel (or `STORE_DRIVER=memory`)   | process memory only — **ephemeral** |

Override with the `STORE_DRIVER` environment variable.

## Deploying to Vercel

The control-plane ships a serverless entrypoint (`api/index.js`) and a
`vercel.json` rewrite that routes every request into the Express app. To deploy:

1. In Vercel, create a project from this repo and set the **Root Directory** to
   `apps/control-plane`.
2. Set environment variables:
   - `FLEET_PSK` — shared device/portal secret (do not ship the default).
   - `STORE_DRIVER` — defaults to `memory` on Vercel automatically.
3. Deploy. The API is served at the project URL (e.g.
   `https://<project>.vercel.app/health`, `/api/v1/portal/devices`).

> **⚠️ Temporary storage on Vercel.** With the default `memory` driver, all
> state lives in a single function instance's RAM. It is **lost on cold start**
> (after a few minutes idle) and is **not shared** when Vercel scales to more
> than one instance. This is suitable for demos and short-lived testing only.
> For a real device fleet, wire up a durable backend (e.g. Upstash/Vercel KV or
> Postgres) behind `src/store.js` before relying on it.

> The control-plane and portal deploy as **two separate Vercel projects from the
> same repo**. See [`docs/vercel-deployment.md`](../../docs/vercel-deployment.md)
> for the full two-project setup and per-project Ignored Build Step.

## Critical LAN Config Governance

Control-plane is the policy gate for LAN IP/subnet changes:

- validate critical network fields (interface/IP/prefix)
- version and audit each critical change request
- expose apply/rollback state from device heartbeats to portal
