const express = require("express");
const path = require("path");

const app = express();
const port = Number(process.env.PORT || 4100);
const controlPlaneUrl = process.env.CONTROL_PLANE_PUBLIC_URL || "http://localhost:4000";
const defaultPsk = process.env.PORTAL_DEFAULT_PSK || "dev-fleet-psk";

app.use(express.static(path.join(__dirname, "web")));

app.get("/runtime-config.js", (_req, res) => {
  res.type("application/javascript").send(
    `window.__RNFLEET_RUNTIME_CONFIG__ = ${JSON.stringify({
      controlPlaneUrl,
      defaultPsk
    })};`
  );
});

app.get("/health", (_req, res) => {
  res.json({ ok: true, service: "portal" });
});

// Only start an HTTP listener when run directly (local dev, Azure App Service,
// bare metal). On serverless hosts (Vercel) the app is imported and invoked by
// the platform, so we must NOT call listen() there.
if (require.main === module) {
  app.listen(port, () => {
    console.log(`portal listening on http://localhost:${port}`);
  });
}

module.exports = app;
