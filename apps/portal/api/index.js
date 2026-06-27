// Vercel serverless entrypoint for the RNFleet portal.
//
// Vercel treats every file under /api as a serverless function. We import the
// Express app (which exports itself without calling listen() under Vercel) and
// let Express serve the static UI plus the dynamic /runtime-config.js.
// vercel.json rewrites every incoming path to this function.
//
// Configure CONTROL_PLANE_PUBLIC_URL (and PORTAL_DEFAULT_PSK) in the Vercel
// project so the browser talks to the deployed control-plane.
module.exports = require("../src/server.js");
