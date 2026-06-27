function pskAuth(req, res, next) {
  const expected = process.env.FLEET_PSK || "dev-fleet-psk";
  const provided = req.header("x-fleet-psk");
  if (!provided || provided !== expected) {
    return res.status(401).json({ error: "unauthorized" });
  }
  return next();
}

module.exports = { pskAuth };
