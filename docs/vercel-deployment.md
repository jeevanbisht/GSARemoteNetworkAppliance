# Deploying to Vercel (two projects, one repo)

The control-plane and the portal are separate apps in this monorepo. Vercel does
**not** auto-split a repo: a Vercel project maps to a single **Root Directory**,
so each app is its own Vercel project, with its own URL/domain, both connected to
the same GitHub repo (`jeevanbisht/RNFleetManager`, branch `main`).

```
GitHub repo (one)
├── apps/control-plane   ──>  Vercel project "rnfleet-control-plane"
└── apps/portal          ──>  Vercel project "rnfleet-portal"
```

Each app is already wired for Vercel:

- `api/index.js` — serverless entrypoint that imports the Express app.
- `vercel.json` — catch-all rewrite routing every request into Express.
- `src/server.js` — exports `app`; only calls `listen()` when run directly.

## 1. Create the control-plane project

1. Vercel → **Add New → Project → Import** `jeevanbisht/RNFleetManager`.
2. **Root Directory** = `apps/control-plane`.
3. **Framework Preset** = Other. Build Command: none. Install: `npm install`.
4. **Environment Variables**:
   - `FLEET_PSK` = your real shared secret (don't ship the `dev-fleet-psk` default).
   - `STORE_DRIVER` defaults to `memory` on Vercel automatically (ephemeral — see
     the control-plane README caveat).
5. Deploy. Note the resulting URL, e.g. `https://rnfleet-control-plane.vercel.app`.

## 2. Create the portal project

1. Vercel → **Add New → Project → Import** the **same** repo again.
2. **Root Directory** = `apps/portal`.
3. **Framework Preset** = Other. Build Command: none. Install: `npm install`.
4. **Environment Variables**:
   - `CONTROL_PLANE_PUBLIC_URL` = the control-plane project URL from step 1.
   - `PORTAL_DEFAULT_PSK` = the same value as the control-plane `FLEET_PSK`.
5. Deploy.

## 3. Scope each project's builds (so Vercel "diffs" the apps)

By default **both** projects rebuild on **every** push, even if only the other
app changed. Make each project rebuild only when its own folder (or shared
`packages/`) changes via **Settings → Git → Ignored Build Step**:

- control-plane project: `bash scripts/vercel-ignore.sh apps/control-plane`
- portal project:        `bash scripts/vercel-ignore.sh apps/portal`

The helper (`scripts/vercel-ignore.sh`) exits `1` (skip build) when nothing under
the watched paths changed, and `0` (build) otherwise. The first deploy always
builds.

## Notes

- **CORS**: the control-plane already sends permissive CORS (`app.use(cors())`),
  so the portal's browser calls to the control-plane URL work cross-origin.
- **Storage**: the control-plane uses the ephemeral in-memory store on Vercel.
  State resets on cold start / scale-out — fine for demos, not for a real fleet.
  Wire a durable backend behind `apps/control-plane/src/store.js` before
  production use.
