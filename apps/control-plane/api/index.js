// Vercel serverless entrypoint for the RNFleet control-plane.
//
// Vercel treats every file under /api as a serverless function. We import the
// Express app (which exports itself without calling listen() under Vercel) and
// let Express handle all routing. vercel.json rewrites every incoming path to
// this function.
//
// Storage note: on Vercel the store defaults to the in-memory driver
// (process.env.VERCEL is set), so state is ephemeral — it resets on cold start
// and is not shared across scaled-out instances. Configure a durable backend
// before using with a real device fleet.
module.exports = require("../src/server.js");
