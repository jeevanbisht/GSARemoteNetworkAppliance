# Operator Portal

Web console for fleet visibility, policy management, rollout control, and operational troubleshooting.

## Module Responsibilities

- `src/pages`: route-level views (fleet, device, configs, rollouts)
- `src/components`: reusable UI components
- `src/services`: API clients and data access
- `src/state`: application and server-state management
- `src/auth`: session, RBAC, and protected routes

## UX Principles

- Operational clarity first (health, drift, rollout status)
- Guardrails for risky actions (confirmations, scope previews)
- Full operator action traceability via audit context

## MVP Runtime Notes

- Start with: `npm run start:portal` (from repository root)
- Default port: `4100`
- Configure API base and PSK from the portal settings panel.
- `CONTROL_PLANE_PUBLIC_URL` / `PORTAL_DEFAULT_PSK` env vars seed the browser's
  control-plane URL and PSK (served via `/runtime-config.js`).

## Deploying to Vercel

The portal ships a serverless entrypoint (`api/index.js`) and a `vercel.json`
rewrite that routes every request into the Express app (which serves the static
UI and the dynamic `/runtime-config.js`). To deploy:

1. In Vercel, import the repo and set **Root Directory** = `apps/portal`.
2. Framework preset **Other**; no build command; install `npm install`.
3. Environment variables:
   - `CONTROL_PLANE_PUBLIC_URL` — URL of the deployed control-plane project.
   - `PORTAL_DEFAULT_PSK` — same value as the control-plane `FLEET_PSK`.
4. Deploy.

The control-plane and portal are **two separate Vercel projects from the same
repo**. See [`docs/vercel-deployment.md`](../../docs/vercel-deployment.md) for
the full two-project setup, including the per-project **Ignored Build Step** that
makes each project rebuild only when its own folder changes.

## Critical Network Change UX

Portal is responsible for operator guardrails on LAN IP/subnet updates:

- explicit warning for critical LAN changes
- confirmation before push
- clear display of apply result and rollback status

## Current UI Layout

- Professional responsive layout (desktop + smaller screens)
- Device table with:
  - WAN interface and WAN IP
  - WAN public IP
  - Adapter/interface details (MAC + IPv4/IPv6)
- Separate forms for:
  - Device Configuration (IP Config)
  - Tunnel Configuration
- **Tunnel & BGP form is fully config-complete from the UI** — no device-side editing
  is required to stand up a GSA tunnel:
  - **Entra Graph JSON import** — paste the remote-network connectivity JSON and
    "Parse & Fill" auto-populates GSA/peer endpoints, ASNs, BGP addresses, and region.
  - **IKE Phase 1 / Phase 2 combination dropdowns** — the official GSA combination
    tables (P1 1–8, P2 1–3) are selectable by number; a live preview shows the resolved
    algorithms (e.g. Combo 7 → AES256-SHA384-DHGroup14, Combo 2 → GCMAES192) and the
    selection is pushed as `tunnel.ipsecPolicy`.
  - **PSK field** (with show/hide toggle) — the IPSec pre-shared key is pushed as
    `tunnel.psk`; leaving it blank preserves the existing device-side key.
  - **"Push All Config" with a multi-step progress stepper** — submitting the config
    drives a live stepper (Submit → Device fetch/apply → IPSec SA → BGP session) with a
    percentage bar, elapsed timer, and a "still working…" hint, so the operator never
    sees a frozen/hung UI during the ~tens of seconds it takes to establish end-to-end.
    Progress is reconciled from the device heartbeat and turns green only once the
    device reports the tunnel up and BGP established.
- Device actions: register, delete (with confirm), restart tunnel, run diagnostics
- **Per-row Remove button** in the device table (in addition to delete in the device
  detail modal) for quick fleet cleanup, with a confirmation guardrail
- **Audit log with category filters** — checkboxes for Device, Config, Tunnel/BGP,
  and Action. Each shows a live count and toggles visibility of matching events; an
  empty-state message appears when no events match the selected filters.
