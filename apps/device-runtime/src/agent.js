const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { JOB_TYPES } = require("@rnfleet/contracts");
const { applyTunnelConfig, readBgpSessionState, restartTunnel, collectTunnelDiagnostics } = require("./agents/tunnel");

const CONTROL_PLANE_URL = process.env.CONTROL_PLANE_URL || "http://localhost:4000";
const FLEET_PSK = process.env.FLEET_PSK || "dev-fleet-psk";
const DEVICE_ID = process.env.DEVICE_ID || "device-001";
const SITE_ID = process.env.SITE_ID || "lab-site";
const LOOP_SECONDS = Number(process.env.LOOP_SECONDS || 10);
const WAN_PUBLIC_IP_REFRESH_SECONDS = Number(process.env.WAN_PUBLIC_IP_REFRESH_SECONDS || 300);

const publicIpCache = {
  value: null,
  expiresAtMs: 0
};

const stateDir = path.join(__dirname, "..", "state");
const stateFile = path.join(stateDir, "runtime-state.json");

function ensureState() {
  if (!fs.existsSync(stateDir)) {
    fs.mkdirSync(stateDir, { recursive: true });
  }
  if (!fs.existsSync(stateFile)) {
    fs.writeFileSync(
      stateFile,
      JSON.stringify(
        {
          registered: false,
          lastAppliedConfigVersion: null,
          tunnelStatus: "down",
          lastError: null
        },
        null,
        2
      )
    );
  }
}

function readState() {
  ensureState();
  return JSON.parse(fs.readFileSync(stateFile, "utf-8"));
}

function writeState(next) {
  fs.writeFileSync(stateFile, JSON.stringify(next, null, 2));
}

function runCommand(command, args) {
  try {
    return execFileSync(command, args, { encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch (_error) {
    return "";
  }
}

function runCommandResult(command, args) {
  try {
    const stdout = execFileSync(command, args, { encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] });
    return {
      ok: true,
      stdout: (stdout || "").trim(),
      stderr: ""
    };
  } catch (error) {
    return {
      ok: false,
      stdout: error && error.stdout ? String(error.stdout).trim() : "",
      stderr: error && error.stderr ? String(error.stderr).trim() : "",
      error: error && error.message ? error.message : "command_failed"
    };
  }
}

function isValidIpv4(value) {
  if (!value || typeof value !== "string") {
    return false;
  }
  const parts = value.trim().split(".");
  if (parts.length !== 4) {
    return false;
  }
  return parts.every((part) => /^\d+$/.test(part) && Number(part) >= 0 && Number(part) <= 255);
}

function normalizeInterfaceName(name) {
  if (!name) {
    return "";
  }
  return name.split("@")[0];
}

function parseDefaultRouteInterface(routeOutput) {
  if (!routeOutput) {
    return null;
  }
  const defaultLine = routeOutput
    .split("\n")
    .map((value) => value.trim())
    .find((value) => value.startsWith("default "));
  if (!defaultLine) {
    return null;
  }
  const match = defaultLine.match(/\bdev\s+([a-zA-Z0-9._-]+)/);
  return match ? match[1] : null;
}

function ensureInterface(detailsByInterface, name) {
  const key = normalizeInterfaceName(name);
  if (!key) {
    return null;
  }
  if (!detailsByInterface[key]) {
    detailsByInterface[key] = {
      name: key,
      mac: null,
      mtu: null,
      operState: null,
      carrier: null,
      speedMbps: null,
      flags: [],
      ipv4: [],
      ipv6: []
    };
  }
  return detailsByInterface[key];
}

function readSysfsFile(interfaceName, field) {
  try {
    const fullPath = path.join("/sys/class/net", interfaceName, field);
    return fs.readFileSync(fullPath, "utf-8").trim();
  } catch (_error) {
    return "";
  }
}

function collectInterfaceDetails() {
  const detailsByInterface = {};
  const linkOutput = runCommand("ip", ["-o", "link", "show"]);
  const ipv4Output = runCommand("ip", ["-o", "-4", "addr", "show"]);
  const ipv6Output = runCommand("ip", ["-o", "-6", "addr", "show"]);

  for (const line of linkOutput.split("\n").map((value) => value.trim()).filter(Boolean)) {
    const head = line.match(/^\d+:\s+([^:]+):\s+<([^>]*)>/);
    if (!head) {
      continue;
    }
    const iface = ensureInterface(detailsByInterface, head[1]);
    if (!iface) {
      continue;
    }
    iface.flags = head[2] ? head[2].split(",").filter(Boolean) : [];
    const mtuMatch = line.match(/\bmtu\s+(\d+)/);
    if (mtuMatch) {
      iface.mtu = Number(mtuMatch[1]);
    }
    const stateMatch = line.match(/\bstate\s+([A-Z]+)/);
    if (stateMatch) {
      iface.operState = stateMatch[1];
    }
    const macMatch = line.match(/\blink\/\w+\s+([0-9a-f:]{17})\b/i);
    if (macMatch) {
      iface.mac = macMatch[1].toLowerCase();
    }

    const sysOperState = readSysfsFile(iface.name, "operstate");
    if (sysOperState) {
      iface.operState = sysOperState.toLowerCase();
    }
    const carrierRaw = readSysfsFile(iface.name, "carrier");
    if (carrierRaw === "0" || carrierRaw === "1") {
      iface.carrier = carrierRaw === "1";
    }
    const speedRaw = readSysfsFile(iface.name, "speed");
    const speedNum = Number(speedRaw);
    if (Number.isFinite(speedNum) && speedNum > 0) {
      iface.speedMbps = speedNum;
    }
  }

  for (const line of ipv4Output.split("\n").map((value) => value.trim()).filter(Boolean)) {
    const match = line.match(/^\d+:\s+([^\s]+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)\/(\d+)/);
    if (!match) {
      continue;
    }
    const iface = ensureInterface(detailsByInterface, match[1]);
    if (!iface) {
      continue;
    }
    iface.ipv4.push({
      address: match[2],
      prefixLength: Number(match[3])
    });
  }

  for (const line of ipv6Output.split("\n").map((value) => value.trim()).filter(Boolean)) {
    const match = line.match(/^\d+:\s+([^\s]+)\s+inet6\s+([0-9a-f:]+)\/(\d+)/i);
    if (!match) {
      continue;
    }
    const iface = ensureInterface(detailsByInterface, match[1]);
    if (!iface) {
      continue;
    }
    iface.ipv6.push({
      address: match[2].toLowerCase(),
      prefixLength: Number(match[3])
    });
  }

  return Object.values(detailsByInterface).sort((a, b) => a.name.localeCompare(b.name));
}

function firstIpv4ForInterface(interfaces, interfaceName) {
  const target = normalizeInterfaceName(interfaceName);
  if (!target) {
    return null;
  }
  const iface = interfaces.find((item) => item.name === target);
  if (!iface || !Array.isArray(iface.ipv4) || iface.ipv4.length === 0) {
    return null;
  }
  return iface.ipv4[0].address || null;
}

function resolveWanPublicIp() {
  if (Date.now() < publicIpCache.expiresAtMs) {
    return publicIpCache.value;
  }

  const candidates = [
    ["curl", ["-sS", "--max-time", "2", "https://api.ipify.org"]],
    ["curl", ["-sS", "--max-time", "2", "https://ifconfig.me/ip"]]
  ];
  let resolved = null;
  for (const [command, args] of candidates) {
    const output = runCommand(command, args).trim();
    if (isValidIpv4(output)) {
      resolved = output;
      break;
    }
  }

  publicIpCache.value = resolved;
  publicIpCache.expiresAtMs = Date.now() + Math.max(WAN_PUBLIC_IP_REFRESH_SECONDS, 30) * 1000;
  return publicIpCache.value;
}

function parseLanDesiredConfig(config) {
  if (!config || !config.network || !config.network.lan) {
    return null;
  }
  const lan = config.network.lan;
  if (!lan || lan.apply !== true) {
    return null;
  }
  const lanInterface = (lan.interface || config.network.lanInterface || config.network.lanIface || "eth1").trim();
  const ip = (lan.ip || "").trim();
  const prefixLength = Number(lan.prefixLength);
  if (!lanInterface || !ip || !Number.isInteger(prefixLength) || prefixLength < 1 || prefixLength > 32) {
    return null;
  }
  return { lanInterface, ip, prefixLength };
}

function captureInterfaceIpv4(interfaces, interfaceName) {
  const key = normalizeInterfaceName(interfaceName);
  const iface = interfaces.find((item) => item.name === key);
  if (!iface || !Array.isArray(iface.ipv4)) {
    return [];
  }
  return iface.ipv4
    .filter((item) => item && item.address && Number.isInteger(item.prefixLength))
    .map((item) => ({ address: item.address, prefixLength: item.prefixLength }));
}

function restorePreviousLanAddresses(interfaceName, previousIpv4) {
  const flush = runCommandResult("ip", ["-4", "addr", "flush", "dev", interfaceName, "scope", "global"]);
  if (!flush.ok) {
    return {
      ok: false,
      message: `rollback_flush_failed:${flush.error || flush.stderr || flush.stdout}`
    };
  }
  for (const addr of previousIpv4) {
    const add = runCommandResult("ip", ["-4", "addr", "add", `${addr.address}/${addr.prefixLength}`, "dev", interfaceName]);
    if (!add.ok) {
      return {
        ok: false,
        message: `rollback_restore_failed:${add.error || add.stderr || add.stdout}`
      };
    }
  }
  return { ok: true, message: "rollback_complete" };
}

function applyCriticalLanChange(state, desiredLan) {
  const startedAt = new Date().toISOString();
  const beforeState = collectNetworkState({ network: { wanInterface: "eth0", lanInterface: desiredLan.lanInterface } });
  const previousIpv4 = captureInterfaceIpv4(beforeState.interfaces || [], desiredLan.lanInterface);
  const signature = `${desiredLan.lanInterface}:${desiredLan.ip}/${desiredLan.prefixLength}`;

  if (state.criticalChange && state.criticalChange.appliedSignature === signature && state.criticalChange.status === "applied") {
    return state;
  }

  const interfaceExists = (beforeState.interfaces || []).some((iface) => iface.name === normalizeInterfaceName(desiredLan.lanInterface));
  if (!interfaceExists) {
    throw new Error(`critical_lan_prepare_failed:interface_not_found:${desiredLan.lanInterface}`);
  }

  const flush = runCommandResult("ip", ["-4", "addr", "flush", "dev", desiredLan.lanInterface, "scope", "global"]);
  if (!flush.ok) {
    throw new Error(`critical_lan_apply_failed:flush:${flush.error || flush.stderr || flush.stdout}`);
  }

  const add = runCommandResult("ip", ["-4", "addr", "add", `${desiredLan.ip}/${desiredLan.prefixLength}`, "dev", desiredLan.lanInterface]);
  if (!add.ok) {
    const rollback = restorePreviousLanAddresses(desiredLan.lanInterface, previousIpv4);
    const rollbackText = rollback.ok ? "rolled_back" : rollback.message;
    throw new Error(`critical_lan_apply_failed:add:${add.error || add.stderr || add.stdout}:${rollbackText}`);
  }

  const up = runCommandResult("ip", ["link", "set", "dev", desiredLan.lanInterface, "up"]);
  if (!up.ok) {
    const rollback = restorePreviousLanAddresses(desiredLan.lanInterface, previousIpv4);
    const rollbackText = rollback.ok ? "rolled_back" : rollback.message;
    throw new Error(`critical_lan_apply_failed:link_up:${up.error || up.stderr || up.stdout}:${rollbackText}`);
  }

  const afterState = collectNetworkState({ network: { wanInterface: "eth0", lanInterface: desiredLan.lanInterface } });
  const lanIpAfter = firstIpv4ForInterface(afterState.interfaces || [], desiredLan.lanInterface);
  if (lanIpAfter !== desiredLan.ip) {
    const rollback = restorePreviousLanAddresses(desiredLan.lanInterface, previousIpv4);
    const rollbackText = rollback.ok ? "rolled_back" : rollback.message;
    throw new Error(`critical_lan_verify_failed:expected_${desiredLan.ip}_got_${lanIpAfter || "none"}:${rollbackText}`);
  }

  return {
    ...state,
    criticalChange: {
      type: "lan_ip_subnet_update",
      status: "applied",
      appliedSignature: signature,
      interface: desiredLan.lanInterface,
      desiredIp: desiredLan.ip,
      desiredPrefixLength: desiredLan.prefixLength,
      previousIpv4,
      startedAt,
      completedAt: new Date().toISOString()
    }
  };
}

function collectNetworkState(config) {
  const wanInterface = (config && config.network && config.network.wanInterface) || "eth0";
  const lanInterface = (config && config.network && config.network.lanInterface) || "eth1";
  const interfaces = collectInterfaceDetails();
  const routeOutput = runCommand("ip", ["route", "show"]);

  const wanIp = firstIpv4ForInterface(interfaces, wanInterface);
  const lanIp = firstIpv4ForInterface(interfaces, lanInterface);
  const wanPublicIp = resolveWanPublicIp();
  const defaultRouteInterface = parseDefaultRouteInterface(routeOutput);
  const routes = routeOutput
    ? routeOutput
        .split("\n")
        .map((value) => value.trim())
        .filter(Boolean)
        .slice(0, 20)
    : [];

  return {
    collectedAt: new Date().toISOString(),
    wanInterface,
    lanInterface,
    wanIp,
    wanPublicIp,
    lanIp,
    defaultRouteInterface,
    interfaces,
    interfaceCount: interfaces.length,
    routes
  };
}

function applyConfig(state, config) {
  let next = { ...state };

  if (config.tunnel) {
    const result = applyTunnelConfig(config.tunnel);
    next.tunnelStatus = result.ok
      ? (config.tunnel.enabled ? "up" : "down")
      : "error";
    next.bgpSessionState = result.bgpSessionState || "unknown";
    if (!result.ok) {
      next.lastError = result.error || "tunnel_apply_failed";
    } else {
      next.lastError = null;
    }
  } else {
    next.tunnelStatus = "down";
    next.bgpSessionState = "unknown";
    next.lastError = null;
  }

  const desiredLan = parseLanDesiredConfig(config);
  if (desiredLan) {
    next = applyCriticalLanChange(next, desiredLan);
  }

  next.lastAppliedConfigVersion = config.version;
  return next;
}

async function api(pathName, options = {}) {
  const response = await fetch(`${CONTROL_PLANE_URL}${pathName}`, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      "x-fleet-psk": FLEET_PSK,
      ...(options.headers || {})
    }
  });
  if (response.status === 204) {
    return null;
  }
  if (!response.ok) {
    throw new Error(`request_failed:${response.status}:${await response.text()}`);
  }
  return response.json();
}

async function registerDevice() {
  await api("/api/v1/devices/register", {
    method: "POST",
    body: JSON.stringify({
      deviceId: DEVICE_ID,
      siteId: SITE_ID,
      capabilities: ["2-nic", "ipsec", "bgp"]
    })
  });
}

async function executeJob(job, state) {
  let jobResult = { tunnelStatus: state.tunnelStatus };

  if (job.type === JOB_TYPES.RESTART_TUNNEL) {
    const payload = await api(`/api/v1/devices/${encodeURIComponent(DEVICE_ID)}/config`);
    const tunnel = payload && payload.config && payload.config.tunnel;
    state.tunnelStatus = "restarting";
    const result = restartTunnel(tunnel);
    state.tunnelStatus = result.ok ? (tunnel && tunnel.enabled === false ? "down" : "up") : "error";
    state.bgpSessionState = result.bgpSessionState || state.bgpSessionState || "unknown";
    state.lastError = result.ok ? null : (result.error || "tunnel_restart_failed");
    jobResult = { tunnelStatus: state.tunnelStatus, bgpSessionState: state.bgpSessionState };
  } else if (job.type === JOB_TYPES.RUN_DIAGNOSTICS) {
    const payload = await api(`/api/v1/devices/${encodeURIComponent(DEVICE_ID)}/config`);
    const tunnel = payload && payload.config && payload.config.tunnel;
    const gsaBgpAddress = tunnel && tunnel.gsa && tunnel.gsa.bgpAddress;
    const diagnostics = collectTunnelDiagnostics(gsaBgpAddress);
    state.tunnelStatus = diagnostics.tunnelStatus;
    state.bgpSessionState = diagnostics.bgpSessionState;
    state.lastError = null;
    jobResult = {
      tunnelStatus: state.tunnelStatus,
      bgpSessionState: state.bgpSessionState,
      diagnostics
    };
  } else if (job.type === JOB_TYPES.APPLY_CONFIG) {
    const payload = await api(`/api/v1/devices/${encodeURIComponent(DEVICE_ID)}/config`);
    if (payload && payload.config) {
      state = applyConfig(state, payload.config);
    }
    jobResult = { tunnelStatus: state.tunnelStatus, bgpSessionState: state.bgpSessionState };
  }

  await api(`/api/v1/jobs/${encodeURIComponent(job.jobId)}/ack`, {
    method: "POST",
    body: JSON.stringify({
      deviceId: DEVICE_ID,
      status: "completed",
      result: jobResult
    })
  });

  return state;
}

async function runLoop() {
  let state = readState();
  try {
    if (!state.registered) {
      await registerDevice();
      state.registered = true;
    }

    const configResponse = await api(`/api/v1/devices/${encodeURIComponent(DEVICE_ID)}/config`);
    if (configResponse && configResponse.config && configResponse.config.version !== state.lastAppliedConfigVersion) {
      state = applyConfig(state, configResponse.config);
    }
    const networkState = collectNetworkState(configResponse && configResponse.config);
    state.networkState = networkState;

    // Refresh live tunnel/BGP status every loop so the heartbeat reflects the
    // current SA/BGP state rather than the snapshot captured at the last config
    // apply. A tunnel can establish moments after applyTunnelConfig() returns,
    // which would otherwise leave the heartbeat reporting a stale error/down.
    const liveTunnel = configResponse && configResponse.config && configResponse.config.tunnel;
    if (liveTunnel && liveTunnel.enabled) {
      const live = collectTunnelDiagnostics(liveTunnel.gsa && liveTunnel.gsa.bgpAddress);
      if (live && live.tunnelStatus !== "dry_run") {
        state.tunnelStatus = live.tunnelStatus;
        state.bgpSessionState = live.bgpSessionState;
      }
    }

    const jobResponse = await api(`/api/v1/devices/${encodeURIComponent(DEVICE_ID)}/jobs/next`);
    if (jobResponse && jobResponse.job) {
      state = await executeJob(jobResponse.job, state);
    }
    state.lastError = null;

    await api(`/api/v1/devices/${encodeURIComponent(DEVICE_ID)}/heartbeat`, {
      method: "POST",
      body: JSON.stringify({
        status: "online",
        tunnelStatus: state.tunnelStatus,
        bgpSessionState: state.bgpSessionState || "unknown",
        lastAppliedConfigVersion: state.lastAppliedConfigVersion,
        ipWan: networkState.wanIp,
        wanPublicIp: networkState.wanPublicIp,
        ipLan: networkState.lanIp,
        networkState,
        criticalChange: state.criticalChange || null,
        lastError: state.lastError
      })
    });
  } catch (error) {
    state.lastError = error.message;
    try {
      await api(`/api/v1/devices/${encodeURIComponent(DEVICE_ID)}/heartbeat`, {
        method: "POST",
        body: JSON.stringify({
          status: "degraded",
          tunnelStatus: state.tunnelStatus || "down",
          bgpSessionState: state.bgpSessionState || "unknown",
          lastAppliedConfigVersion: state.lastAppliedConfigVersion,
          ipWan: state.networkState && state.networkState.wanIp,
          wanPublicIp: state.networkState && state.networkState.wanPublicIp,
          ipLan: state.networkState && state.networkState.lanIp,
          networkState: state.networkState || null,
          criticalChange: state.criticalChange || null,
          lastError: state.lastError
        })
      });
    } catch (_ignored) {
    }
  }
  writeState(state);
}

async function main() {
  console.log(`device-runtime started for ${DEVICE_ID}; control-plane=${CONTROL_PLANE_URL}`);
  await runLoop();
  setInterval(runLoop, LOOP_SECONDS * 1000);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
