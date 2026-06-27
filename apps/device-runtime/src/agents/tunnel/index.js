const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

// swanctl/vici config. We use the modern swanctl interface (charon-systemd)
// instead of the legacy ipsec.conf starter, because only swanctl/vici reliably
// honors if_id_in/if_id_out — the basis of route-based XFRM-interface isolation.
const SWANCTL_CONF_PATH = process.env.SWANCTL_CONF_PATH || "/etc/swanctl/swanctl.conf";
const FRR_CONF_PATH = process.env.FRR_CONF_PATH || "/etc/frr/frr.conf";
// strongSwan connection name (used for swanctl --initiate/--terminate).
const CONN_NAME = "rnfleet-gsa";
// strongSwan drop-in to disable automatic route installation. In XFRM-interface
// (route-based) mode we manage routing ourselves via ipsec-gsa, so charon must
// not install catch-all routes that could blackhole management traffic.
const STRONGSWAN_DROPIN_PATH = process.env.STRONGSWAN_DROPIN_PATH || "/etc/strongswan.d/rnfleet-routes.conf";
// IPSec pre-shared key for the GSA tunnel. Kept independent from FLEET_PSK
// (the control-plane auth secret) so the tunnel key can differ from the
// control-plane credential. Falls back to FLEET_PSK for backward compatibility.
const TUNNEL_PSK = process.env.TUNNEL_PSK || process.env.FLEET_PSK || "dev-fleet-psk";
const DRY_RUN = process.env.TUNNEL_DRY_RUN === "true";

// XFRM interface used for route-based GSA tunnelling. Only traffic routed to
// this interface is encrypted, so management traffic (SSH, Azure guest agent)
// is never captured by the tunnel. The SA is bound to the interface via if_id.
const XFRM_IFACE = process.env.TUNNEL_XFRM_IFACE || "ipsec-gsa";
const IF_ID = Number(process.env.TUNNEL_IF_ID) > 0 ? Number(process.env.TUNNEL_IF_ID) : 42;

function runSilent(command, args) {
  try {
    execFileSync(command, args, { stdio: "ignore" });
    return { ok: true };
  } catch (error) {
    return { ok: false, error: error.message };
  }
}

function runCapture(command, args, timeout = 5000) {
  try {
    const out = execFileSync(command, args, {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout
    });
    return { ok: true, output: out || "" };
  } catch (error) {
    return {
      ok: false,
      error: error.message,
      output: (error.stdout && error.stdout.toString()) || ""
    };
  }
}

function writeFileSafe(filePath, content) {
  try {
    const dir = path.dirname(filePath);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }
    fs.writeFileSync(filePath, content, { encoding: "utf-8", mode: 0o600 });
    return { ok: true };
  } catch (error) {
    return { ok: false, error: error.message };
  }
}

// Maps Azure GSA IPSec/IKE policy names to strongSwan proposal tokens.
const AZURE_ENCRYPTION = {
  aes128: "aes128",
  aes192: "aes192",
  aes256: "aes256",
  gcmaes128: "aes128gcm16",
  gcmaes192: "aes192gcm16",
  gcmaes256: "aes256gcm16"
};
const AZURE_INTEGRITY = {
  sha256: "sha256",
  sha384: "sha384",
  sha1: "sha1",
  // GCM ciphers are AEAD and carry their own integrity.
  gcmaes128: "",
  gcmaes192: "",
  gcmaes256: ""
};
const AZURE_DH_GROUP = {
  none: "",
  dhgroup1: "modp768",
  dhgroup2: "modp1024",
  dhgroup14: "modp2048",
  dhgroup24: "modp2048s256",
  ecp256: "ecp256",
  ecp384: "ecp384",
  pfs2048: "modp2048",
  pfsmm: "modp2048",
  pfs1: "modp768",
  pfs2: "modp1024",
  pfs14: "modp2048",
  pfs24: "modp2048s256"
};

function mapToken(table, value, fallback) {
  if (!value) return fallback;
  const key = String(value).toLowerCase();
  return Object.prototype.hasOwnProperty.call(table, key) ? table[key] : value;
}

// Builds strongSwan ike= (phase 1) and esp= (phase 2) proposal strings from the
// desired IPSec/IKE policy. Defaults match the GSA combination proven against the
// live GSA gateway (Combination 7 IKE: AES256/SHA384/DHGroup14; Combination 1
// IPSec: GCMAES256/PFS None) so a policy-less push still negotiates with GSA.
function buildProposals(policy) {
  const p = policy || {};
  const ikeEnc = mapToken(AZURE_ENCRYPTION, p.ikeEncryption, "aes256");
  const ikeInt = mapToken(AZURE_INTEGRITY, p.ikeIntegrity, "sha384");
  const ikeDh = mapToken(AZURE_DH_GROUP, p.dhGroup, "modp2048");
  const ike = [ikeEnc, ikeInt, ikeDh].filter(Boolean).join("-");

  const espEnc = mapToken(AZURE_ENCRYPTION, p.ipsecEncryption, "aes256gcm16");
  const espInt = mapToken(AZURE_INTEGRITY, p.ipsecIntegrity, "");
  const espPfs = mapToken(AZURE_DH_GROUP, p.pfsGroup, "");
  const esp = [espEnc, espInt, espPfs].filter(Boolean).join("-");

  return {
    ike: ike,
    esp: esp,
    saLifetimeSeconds: Number(p.saLifetimeSeconds) > 0 ? Number(p.saLifetimeSeconds) : 3600
  };
}

function buildSwanctlConf(tunnel, opts) {
  const gsa = (tunnel && tunnel.gsa) || {};
  const peer = (tunnel && tunnel.peer) || {};
  const proposals = buildProposals(tunnel && tunnel.ipsecPolicy);
  const disabled = opts && opts.disabled;
  // start = auto-initiate the child SA on load; "none" leaves it loaded but idle
  // (used when the watchdog reverts a tunnel that broke management connectivity).
  const startAction = disabled ? "none" : "start";
  const localId = peer.endpoint || "%any";
  const remoteId = gsa.endpoint || "%any";
  const ikeRekey = Math.max(proposals.saLifetimeSeconds * 4, 3600);
  // PSK precedence: per-device config (pushed from the portal) wins, then the
  // TUNNEL_PSK/FLEET_PSK env fallback. Lets an admin rotate the tunnel key from
  // the UI without SSHing into the device to edit the env file.
  const psk = (tunnel && typeof tunnel.psk === "string" && tunnel.psk.length > 0) ? tunnel.psk : TUNNEL_PSK;

  // Route-based (XFRM interface) mode via swanctl/vici. Azure GSA is a
  // route-based gateway: it negotiates a single any-to-any traffic selector
  // (0.0.0.0/0 === 0.0.0.0/0) and exchanges prefixes over BGP. Binding the child
  // SA to the ipsec-gsa XFRM interface with if_id_in/if_id_out means the kernel
  // policies ONLY match traffic routed to that interface — management traffic
  // (SSH, cloud guest agent) is never hijacked into the tunnel. Unlike the legacy
  // ipsec.conf starter, swanctl/vici honors if_id reliably.
  return [
    "connections {",
    `  ${CONN_NAME} {`,
    "    version = 2",
    "    local_addrs = %any",
    `    remote_addrs = ${gsa.endpoint || "%any"}`,
    "    local {",
    "      auth = psk",
    `      id = ${localId}`,
    "    }",
    "    remote {",
    "      auth = psk",
    `      id = ${remoteId}`,
    "    }",
    "    children {",
    `      ${CONN_NAME} {`,
    "        local_ts = 0.0.0.0/0",
    "        remote_ts = 0.0.0.0/0",
    `        esp_proposals = ${proposals.esp}`,
    `        if_id_in = ${IF_ID}`,
    `        if_id_out = ${IF_ID}`,
    `        start_action = ${startAction}`,
    "        dpd_action = restart",
    `        rekey_time = ${proposals.saLifetimeSeconds}s`,
    "      }",
    "    }",
    `    proposals = ${proposals.ike}`,
    `    rekey_time = ${ikeRekey}s`,
    "    dpd_delay = 30s",
    "  }",
    "}",
    "",
    "secrets {",
    "  ike-rnfleet-gsa {",
    `    id-local = ${localId}`,
    `    id-remote = ${remoteId}`,
    `    secret = "${psk}"`,
    "  }",
    "}",
    ""
  ].join("\n");
}

function buildStrongSwanDropIn() {
  // Route-based mode: we install routes onto ipsec-gsa ourselves, so prevent
  // charon from installing catch-all routes (defense-in-depth against the
  // 0.0.0.0/0 selector blackholing SSH / cloud guest-agent traffic).
  return "charon {\n  install_routes = no\n}\n";
}

function buildFrrConf(tunnel) {
  const gsa = tunnel.gsa || {};
  const peer = tunnel.peer || {};
  const localNets = Array.isArray(peer.localNetworks) ? peer.localNetworks : [];
  const networkLines = localNets.map((n) => `    network ${n}`).join("\n");
  const gsaBgp = gsa.bgpAddress || "0.0.0.0";
  const localBgp = peer.bgpAddress || "0.0.0.0";

  return [
    "frr version 9.0",
    "frr defaults traditional",
    "hostname rnfleet-appliance",
    "!",
    `router bgp ${peer.asn || 65001}`,
    `  bgp router-id ${localBgp}`,
    // GSA BGP peers across the IPSec tunnel. The peer's BGP /32 is routed onto
    // the ipsec-gsa XFRM interface (see ensureXfrmInterface), making it a
    // single-hop directly-connected neighbour. Source updates from the local
    // BGP /32 (which lives on ipsec-gsa) and disable the default eBGP policy
    // requirement so routes are exchanged without explicit route-maps.
    "  no bgp ebgp-requires-policy",
    `  neighbor ${gsaBgp} remote-as ${gsa.asn || 65476}`,
    `  neighbor ${gsaBgp} description GSA-Gateway`,
    `  neighbor ${gsaBgp} update-source ${localBgp}`,
    `  neighbor ${gsaBgp} ebgp-multihop 2`,
    "  !",
    "  address-family ipv4 unicast",
    `    neighbor ${gsaBgp} activate`,
    networkLines,
    "  exit-address-family",
    "!",
    "line vty",
    "!"
  ].join("\n");
}

// Detect the WAN/default-route device that carries the encrypted ESP packets.
function detectWanDevice() {
  const r = runCapture("ip", ["route", "show", "default"]);
  const m = /default\s+via\s+\S+\s+dev\s+(\S+)/.exec(r.output || "");
  return (m && m[1]) || "eth0";
}

// Detect the WAN gateway (default-route next-hop) used to reach the underlay.
// Returns null for on-link/point-to-point WANs that have no explicit gateway.
function detectWanGateway() {
  const r = runCapture("ip", ["route", "show", "default"]);
  const m = /default\s+via\s+(\S+)/.exec(r.output || "");
  return (m && m[1]) || null;
}

// Pin the GSA tunnel endpoint (the ESP destination) to the WAN underlay with a
// /32 host route. GSA advertises broad prefixes over BGP that can cover the
// endpoint's public IP; without this pin the kernel prefers the more-specific
// BGP route (next-hop ipsec-gsa) and sends the encrypted ESP packets back into
// the tunnel, causing recursive routing that tears the SA down — the tunnel and
// BGP session then flap continuously. A /32 is the longest possible prefix, so
// it always wins longest-prefix-match over any broader BGP-advertised route,
// keeping ESP on the underlay. Portable across any device/provider.
function pinTunnelEndpointRoute(tunnel, wanDev) {
  const endpoint = tunnel && tunnel.gsa && tunnel.gsa.endpoint;
  if (!endpoint) return;
  const dev = wanDev || detectWanDevice();
  const gw = detectWanGateway();
  const args = gw
    ? ["route", "replace", `${endpoint}/32`, "via", gw, "dev", dev]
    : ["route", "replace", `${endpoint}/32`, "dev", dev];
  runSilent("ip", args);
}

// Remove the /32 underlay pin for the GSA tunnel endpoint (best-effort).
function unpinTunnelEndpointRoute(tunnel) {
  const endpoint = tunnel && tunnel.gsa && tunnel.gsa.endpoint;
  if (!endpoint) return;
  runSilent("ip", ["route", "del", `${endpoint}/32`]);
}

// Create/refresh the XFRM interface that carries GSA tunnel traffic. The SA is
// bound to this interface via if_id, so ONLY traffic routed to ipsec-gsa is
// encrypted — management connectivity (SSH, Azure guest agent) is untouched.
// The local BGP /32 lives on the interface and the GSA peer /32 is routed
// through it so the eBGP session is single-hop and reachable.
function ensureXfrmInterface(tunnel) {
  const gsa = tunnel.gsa || {};
  const peer = tunnel.peer || {};
  const localBgp = peer.bgpAddress;
  const gsaBgp = gsa.bgpAddress;
  const dev = detectWanDevice();

  // 'link add' fails (non-zero, swallowed) if the interface already exists.
  runSilent("ip", ["link", "add", XFRM_IFACE, "type", "xfrm", "dev", dev, "if_id", String(IF_ID)]);
  runSilent("ip", ["link", "set", XFRM_IFACE, "up"]);

  if (localBgp) {
    // 'addr add' is not idempotent; a duplicate returns non-zero (swallowed).
    runSilent("ip", ["addr", "add", `${localBgp}/32`, "dev", XFRM_IFACE]);
  }
  if (gsaBgp) {
    runSilent("ip", ["route", "replace", `${gsaBgp}/32`, "dev", XFRM_IFACE]);
  }
  // Keep ESP to the GSA endpoint on the WAN underlay so BGP-advertised prefixes
  // can never recurse the encrypted transport into the tunnel (flap protection).
  pinTunnelEndpointRoute(tunnel, dev);
  return { ok: true, dev };
}

// Remove the XFRM interface and its addresses/routes when the tunnel is disabled.
function teardownXfrmInterface(tunnel) {
  unpinTunnelEndpointRoute(tunnel);
  runSilent("ip", ["link", "del", XFRM_IFACE]);
  return { ok: true };
}

function reloadStrongSwan() {
  // swanctl --load-all re-reads connections AND secrets from swanctl.conf, so a
  // changed PSK is always picked up (no separate rereadsecrets needed). The child
  // SA auto-initiates via start_action=start; we also terminate any stale SA
  // first so config/crypto changes take effect cleanly.
  const terminate = runSilent("swanctl", ["--terminate", "--ike", CONN_NAME]);
  const load = runSilent("swanctl", ["--load-all"]);
  const initiate = runSilent("swanctl", ["--initiate", "--child", CONN_NAME]);
  return { terminate, load, initiate };
}

function reloadFrr() {
  return runSilent("systemctl", ["reload", "frr"]);
}

// Snapshot of the current default route. The tunnel must NEVER change this; if it
// does (e.g. a regression reintroduces a catch-all policy), management traffic is
// being hijacked and the watchdog reverts. Portable across any Linux device.
function captureDefaultRoute() {
  const r = runCapture("ip", ["route", "show", "default"]);
  return (r.output || "").trim();
}

// Portable management-connectivity check used as a self-heal watchdog after the
// tunnel is applied. Returns true if the box still looks reachable:
//   1. the default route is unchanged (tunnel didn't hijack egress), and
//   2. an active probe to an EXPLICITLY configured `tunnel.healthCheckHost` works
//      (skipped when none is set — we never ping the default gateway, see below).
// No cloud APIs are used, so this works identically on any device.
function managementHealthy(beforeDefaultRoute, tunnel) {
  const now = captureDefaultRoute();
  // Primary guarantee: the route-based tunnel must never change the management
  // default route. If it did, the tunnel is hijacking management traffic.
  if (beforeDefaultRoute && now && beforeDefaultRoute !== now) return false;
  // Optionally verify reachability of an EXPLICITLY configured health-check host.
  // We deliberately do NOT fall back to pinging the default gateway: many cloud
  // and enterprise gateways (e.g. Azure's VNet gateway at x.x.x.1) never answer
  // ICMP, so a gateway ping produces false negatives and would wrongly revert a
  // perfectly healthy tunnel. Portable across any device/provider.
  const target = tunnel && tunnel.healthCheckHost;
  if (target) {
    const ping = runCapture("ping", ["-c", "1", "-W", "2", target], 4000);
    if (!ping.ok) return false;
  }
  return true;
}

// Tear the tunnel down and load an idle (start_action=none) config so it cannot
// re-establish on its own. Used by the watchdog when management connectivity is
// lost after applying a tunnel.
function revertTunnel(tunnel) {
  runSilent("swanctl", ["--terminate", "--ike", CONN_NAME]);
  teardownXfrmInterface(tunnel);
  writeFileSafe(SWANCTL_CONF_PATH, buildSwanctlConf(tunnel || {}, { disabled: true }));
  runSilent("swanctl", ["--load-all"]);
  return { ok: true };
}

/**
 * Derive the eBGP session state for the GSA peer from `vtysh show bgp summary`.
 * Returns one of: "established" | "active" | "idle" | "connecting" | "unknown".
 *
 * Note: FRR prints non-established peers with a literal state word
 * (Active/Idle/Connect/...), but an ESTABLISHED peer is shown with a NUMERIC
 * prefix count (PfxRcd) in the State/PfxRcd column rather than the word
 * "Established" — so a numeric value in that column is treated as established.
 */
function readBgpSessionState(gsaBgpAddress) {
  if (!gsaBgpAddress) return "unknown";
  try {
    const out = execFileSync("vtysh", ["-c", "show bgp summary"], {
      encoding: "utf-8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 3000
    });
    if (!out) return "unknown";
    const lines = out.split("\n");
    for (const line of lines) {
      if (line.includes(gsaBgpAddress)) {
        // Non-established states are printed as literal words in the
        // State/PfxRcd column.
        if (/\bEstablished\b/i.test(line)) return "established";
        if (/\bActive\b/i.test(line)) return "active";
        if (/\bIdle\b/i.test(line)) return "idle";
        if (/\b(Connect|OpenSent|OpenConfirm)\b/i.test(line)) return "connecting";
        // FRR's `show bgp summary` represents an ESTABLISHED session with a
        // numeric prefix count (PfxRcd) in the State column plus an Up/Down
        // timer; it never prints the literal word "Established". Treat a
        // numeric State/PfxRcd column as an established session.
        const cols = line.trim().split(/\s+/);
        if (cols.length >= 10 && /^\d+$/.test(cols[9])) return "established";
        return "connecting";
      }
    }
    return "idle";
  } catch (_err) {
    return "unknown";
  }
}

/**
 * Apply tunnel & BGP config from desired-state config.
 * Writes swanctl + FRR config, brings up the route-based tunnel, then runs a
 * portable management-connectivity watchdog that auto-reverts on failure.
 * Returns { ok, bgpSessionState, error? }
 */
function applyTunnelConfig(tunnel) {
  if (!tunnel || !tunnel.enabled) {
    runSilent("swanctl", ["--terminate", "--ike", CONN_NAME]);
    teardownXfrmInterface(tunnel);
    return { ok: true, bgpSessionState: "down" };
  }

  const swanctlConf = buildSwanctlConf(tunnel);
  const frrConf = buildFrrConf(tunnel);

  if (DRY_RUN) {
    console.log("[tunnel-agent] DRY_RUN – swanctl.conf:\n" + swanctlConf);
    console.log("[tunnel-agent] DRY_RUN – FRR config:\n" + frrConf);
    return { ok: true, bgpSessionState: "dry_run" };
  }

  const w1 = writeFileSafe(SWANCTL_CONF_PATH, swanctlConf);
  if (!w1.ok) return { ok: false, error: `swanctl_conf_write_failed:${w1.error}`, bgpSessionState: "unknown" };

  const w3 = writeFileSafe(FRR_CONF_PATH, frrConf);
  if (!w3.ok) return { ok: false, error: `frr_conf_write_failed:${w3.error}`, bgpSessionState: "unknown" };

  // Defense-in-depth: ensure charon never installs catch-all routes.
  writeFileSafe(STRONGSWAN_DROPIN_PATH, buildStrongSwanDropIn());

  const beforeRoute = captureDefaultRoute();
  ensureXfrmInterface(tunnel);
  reloadStrongSwan();
  reloadFrr();

  // Watchdog: if applying the tunnel cost us management connectivity, revert so
  // the device never bricks itself — works on any device, no out-of-band rescue.
  if (!managementHealthy(beforeRoute, tunnel)) {
    revertTunnel(tunnel);
    return { ok: false, error: "reverted_management_unreachable", bgpSessionState: "down" };
  }

  const bgpSessionState = readBgpSessionState((tunnel.gsa || {}).bgpAddress);
  return { ok: true, bgpSessionState };
}

/**
 * Restart the IPSec tunnel connection (used by the restart_tunnel job).
 * Returns { ok, bgpSessionState, error? }.
 */
function restartTunnel(tunnel) {
  if (DRY_RUN) {
    return { ok: true, bgpSessionState: "dry_run" };
  }
  if (tunnel && tunnel.enabled === false) {
    const down = runSilent("swanctl", ["--terminate", "--ike", CONN_NAME]);
    teardownXfrmInterface(tunnel);
    return { ok: down.ok, bgpSessionState: "down", error: down.ok ? undefined : down.error };
  }
  const beforeRoute = captureDefaultRoute();
  runSilent("swanctl", ["--terminate", "--ike", CONN_NAME]);
  ensureXfrmInterface(tunnel || {});
  runSilent("swanctl", ["--load-all"]);
  const up = runSilent("swanctl", ["--initiate", "--child", CONN_NAME]);
  if (tunnel && !managementHealthy(beforeRoute, tunnel)) {
    revertTunnel(tunnel);
    return { ok: false, bgpSessionState: "down", error: "reverted_management_unreachable" };
  }
  const bgpSessionState = readBgpSessionState((tunnel && tunnel.gsa && tunnel.gsa.bgpAddress) || null);
  return { ok: up.ok, bgpSessionState, error: up.ok ? undefined : up.error };
}

/**
 * Collect live IPSec + BGP diagnostics for the run_diagnostics job.
 * Runs `ipsec statusall`, `vtysh show bgp summary`, and `vtysh show ip route bgp`,
 * then derives tunnelStatus + bgpSessionState. Returns a structured snapshot.
 */
function collectTunnelDiagnostics(gsaBgpAddress) {
  const timestamp = new Date().toISOString();

  if (DRY_RUN) {
    return {
      timestamp,
      dryRun: true,
      tunnelStatus: "dry_run",
      bgpSessionState: "dry_run",
      ipsec: { ok: true, connectionUp: false, raw: "" },
      bgp: { sessionState: "dry_run", summary: "", routes: "" }
    };
  }

  const status = runCapture("swanctl", ["--list-sas", "--ike", CONN_NAME]);
  const ipsecRaw = status.output || "";
  // swanctl --list-sas prints e.g. "rnfleet-gsa: #1, ESTABLISHED, IKEv2 ..." and
  // child SAs as "rnfleet-gsa: #N, INSTALLED, ..." when the tunnel is up.
  const connectionUp =
    /\bESTABLISHED\b/i.test(ipsecRaw) ||
    /\bINSTALLED\b/i.test(ipsecRaw);

  const summary = runCapture("vtysh", ["-c", "show bgp summary"]);
  const routes = runCapture("vtysh", ["-c", "show ip route bgp"]);
  const bgpSessionState = readBgpSessionState(gsaBgpAddress);

  let tunnelStatus = "down";
  if (!status.ok && !status.output) {
    tunnelStatus = "error";
  } else if (connectionUp) {
    tunnelStatus = "up";
  }

  return {
    timestamp,
    tunnelStatus,
    bgpSessionState,
    ipsec: { ok: status.ok, connectionUp, raw: ipsecRaw.slice(0, 4000) },
    bgp: {
      sessionState: bgpSessionState,
      summary: (summary.output || "").slice(0, 4000),
      routes: (routes.output || "").slice(0, 4000)
    }
  };
}

module.exports = {
  applyTunnelConfig,
  readBgpSessionState,
  restartTunnel,
  collectTunnelDiagnostics,
  // exported for testing / dry-run validation
  buildSwanctlConf,
  buildFrrConf,
  buildProposals,
  managementHealthy
};
