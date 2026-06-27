const express = require("express");
const cors = require("cors");
const {
  DEFAULT_DEVICE_CONFIG,
  validateDeviceRegistration,
  validateHeartbeat,
  validateTunnelConfig,
  validateJobType
} = require("./contracts");
const { pskAuth } = require("./auth");
const { readStore, mutateStore, driver: storeDriver } = require("./store");

const app = express();
const port = Number(process.env.PORT || 4000);

app.use(cors());
app.use(express.json());

app.get("/", (_req, res) => {
  res.status(200).send("ok");
});

function pushAudit(data, action, detail) {
  data.audit.unshift({
    timestamp: new Date().toISOString(),
    action,
    detail
  });
  data.audit = data.audit.slice(0, 200);
}

function isValidIpv4(value) {
  if (typeof value !== "string") {
    return false;
  }
  const parts = value.split(".");
  if (parts.length !== 4) {
    return false;
  }
  return parts.every((part) => {
    if (!/^\d+$/.test(part)) {
      return false;
    }
    const n = Number(part);
    return n >= 0 && n <= 255;
  });
}

function validateCriticalLanChange(body) {
  if (!body || !body.network || !body.network.lan) {
    return { ok: true };
  }
  const lan = body.network.lan;
  if (lan.apply !== true) {
    return { ok: true };
  }
  if (typeof lan.interface !== "string" || !lan.interface.trim()) {
    return { ok: false, error: "invalid_lan_interface" };
  }
  if (!isValidIpv4(lan.ip)) {
    return { ok: false, error: "invalid_lan_ip" };
  }
  if (!Number.isInteger(lan.prefixLength) || lan.prefixLength < 1 || lan.prefixLength > 32) {
    return { ok: false, error: "invalid_lan_prefix" };
  }
  return { ok: true };
}

app.get("/health", (_req, res) => {
  res.json({ ok: true, service: "control-plane" });
});

app.use(pskAuth);

app.post("/api/v1/devices/register", (req, res) => {
  const input = req.body || {};
  if (!validateDeviceRegistration(input)) {
    return res.status(400).json({ error: "invalid_device_registration" });
  }

  mutateStore((data) => {
    const existing = data.devices[input.deviceId] || {};
    data.devices[input.deviceId] = {
      ...existing,
      deviceId: input.deviceId,
      siteId: input.siteId || existing.siteId || "default-site",
      capabilities: Array.isArray(input.capabilities) ? input.capabilities : existing.capabilities || [],
      registeredAt: existing.registeredAt || new Date().toISOString(),
      lastSeenAt: new Date().toISOString(),
      status: "online",
      tunnelStatus: existing.tunnelStatus || "down",
      lastAppliedConfigVersion: existing.lastAppliedConfigVersion || null,
      lastError: existing.lastError || null
    };
    pushAudit(data, "device_registered", { deviceId: input.deviceId });
  });

  return res.json({ registered: true, deviceId: input.deviceId });
});

app.get("/api/v1/devices/:deviceId/config", (req, res) => {
  const { deviceId } = req.params;
  const data = readStore();
  if (!data.devices[deviceId]) {
    return res.status(404).json({ error: "device_not_registered" });
  }

  const deviceConfig = data.configs.byDevice[deviceId];
  const config = deviceConfig || { ...DEFAULT_DEVICE_CONFIG, ...data.configs.baseline };
  return res.json({ config });
});

app.post("/api/v1/devices/:deviceId/heartbeat", (req, res) => {
  const { deviceId } = req.params;
  const input = req.body || {};
  if (!validateHeartbeat(input)) {
    return res.status(400).json({ error: "invalid_heartbeat" });
  }

  mutateStore((data) => {
    if (!data.devices[deviceId]) {
      data.devices[deviceId] = {
        deviceId,
        registeredAt: new Date().toISOString()
      };
    }

    const prevTunnelStatus = data.devices[deviceId].tunnelStatus || "unknown";
    const prevBgpSessionState = data.devices[deviceId].bgpSessionState || "unknown";
    const nextTunnelStatus = input.tunnelStatus || "unknown";
    const nextBgpSessionState =
      input.bgpSessionState || data.devices[deviceId].bgpSessionState || "unknown";

    if (nextTunnelStatus !== prevTunnelStatus) {
      if (nextTunnelStatus === "up") {
        pushAudit(data, "tunnel_up", {
          deviceId,
          from: prevTunnelStatus,
          to: nextTunnelStatus
        });
      } else if (prevTunnelStatus === "up") {
        pushAudit(data, "tunnel_down", {
          deviceId,
          from: prevTunnelStatus,
          to: nextTunnelStatus,
          reason: input.lastError || null
        });
      }
    }

    if (nextBgpSessionState !== prevBgpSessionState) {
      if (nextBgpSessionState === "established") {
        pushAudit(data, "bgp_established", {
          deviceId,
          from: prevBgpSessionState,
          to: nextBgpSessionState
        });
      } else if (prevBgpSessionState === "established") {
        pushAudit(data, "bgp_down", {
          deviceId,
          from: prevBgpSessionState,
          to: nextBgpSessionState
        });
      }
    }

    data.devices[deviceId] = {
      ...data.devices[deviceId],
      status: input.status,
      tunnelStatus: nextTunnelStatus,
      bgpSessionState: nextBgpSessionState,
      ipWan: input.ipWan || (input.networkState && input.networkState.wanIp) || null,
      wanPublicIp: input.wanPublicIp || (input.networkState && input.networkState.wanPublicIp) || data.devices[deviceId].wanPublicIp || null,
      ipLan: input.ipLan || (input.networkState && input.networkState.lanIp) || null,
      networkState: input.networkState || data.devices[deviceId].networkState || null,
      criticalChange: input.criticalChange || data.devices[deviceId].criticalChange || null,
      lastError: input.lastError || null,
      lastAppliedConfigVersion: input.lastAppliedConfigVersion || data.devices[deviceId].lastAppliedConfigVersion || null,
      lastSeenAt: new Date().toISOString()
    };
  });

  return res.json({ ok: true });
});

app.get("/api/v1/devices/:deviceId/jobs/next", (req, res) => {
  const { deviceId } = req.params;
  const data = readStore();
  const nextJob = data.jobs.find((job) => job.deviceId === deviceId && job.status === "queued");
  if (!nextJob) {
    return res.status(204).send();
  }
  return res.json({ job: nextJob });
});

app.post("/api/v1/jobs/:jobId/ack", (req, res) => {
  const { jobId } = req.params;
  const body = req.body || {};
  mutateStore((data) => {
    const index = data.jobs.findIndex((job) => job.jobId === jobId);
    if (index < 0) {
      return data;
    }
    data.jobs[index] = {
      ...data.jobs[index],
      status: body.status || "completed",
      result: body.result || null,
      completedAt: new Date().toISOString()
    };
    pushAudit(data, "job_acknowledged", { jobId, status: data.jobs[index].status });
    return data;
  });

  return res.json({ ok: true });
});

app.get("/api/v1/portal/devices", (_req, res) => {
  const data = readStore();
  const devices = Object.values(data.devices)
    .sort((a, b) => (b.lastSeenAt || "").localeCompare(a.lastSeenAt || ""))
    .map((device) => {
      const cfg =
        data.configs.byDevice[device.deviceId] || data.configs.baseline || DEFAULT_DEVICE_CONFIG;
      return {
        ...device,
        tunnelConfig: (cfg && cfg.tunnel) || null,
        desiredConfigVersion: (cfg && cfg.version) || null
      };
    });
  return res.json({ devices });
});

app.delete("/api/v1/portal/devices/:deviceId", (req, res) => {
  const { deviceId } = req.params;
  let existed = false;
  mutateStore((data) => {
    if (data.devices[deviceId]) {
      existed = true;
      delete data.devices[deviceId];
    }
    if (data.configs.byDevice[deviceId]) {
      delete data.configs.byDevice[deviceId];
    }
    const before = data.jobs.length;
    data.jobs = data.jobs.filter((job) => job.deviceId !== deviceId);
    if (existed || before !== data.jobs.length) {
      pushAudit(data, "device_deleted", { deviceId });
    }
    return data;
  });
  if (!existed) {
    return res.status(404).json({ error: "device_not_found", deviceId });
  }
  return res.json({ ok: true, deviceId });
});

app.get("/api/v1/portal/jobs", (req, res) => {
  const data = readStore();
  const { deviceId } = req.query;
  const jobs = deviceId ? data.jobs.filter((job) => job.deviceId === deviceId) : data.jobs;
  return res.json({ jobs });
});

app.get("/api/v1/portal/audit", (_req, res) => {
  const data = readStore();
  return res.json({ audit: data.audit });
});

app.post("/api/v1/portal/configs/:deviceId", (req, res) => {
  const { deviceId } = req.params;
  const body = req.body || {};
  const validation = validateCriticalLanChange(body);
  if (!validation.ok) {
    return res.status(400).json({ error: validation.error });
  }
  const tunnelValidation = validateTunnelConfig(body.tunnel);
  if (!tunnelValidation.ok) {
    return res.status(400).json({ error: tunnelValidation.error });
  }
  mutateStore((data) => {
    const prev = data.configs.byDevice[deviceId] || data.configs.baseline || DEFAULT_DEVICE_CONFIG;
    const nextVersion = Number(data.counters.configVersion || prev.version || 1) + 1;
    data.counters.configVersion = nextVersion;

    const prevTunnel = prev.tunnel || {};
    const bodyTunnel = body.tunnel || {};
    const mergedTunnel = {
      ...prevTunnel,
      ...bodyTunnel,
      gsa: { ...(prevTunnel.gsa || {}), ...(bodyTunnel.gsa || {}) },
      peer: { ...(prevTunnel.peer || {}), ...(bodyTunnel.peer || {}) }
    };

    data.configs.byDevice[deviceId] = {
      ...prev,
      ...body,
      network: {
        ...(prev.network || {}),
        ...((body && body.network) || {})
      },
      tunnel: mergedTunnel,
      version: nextVersion
    };
    pushAudit(data, "config_updated", { deviceId, version: nextVersion });
  });

  return res.json({ ok: true, deviceId });
});

app.post("/api/v1/portal/jobs", (req, res) => {
  const body = req.body || {};
  if (!body.deviceId || !validateJobType(body.type)) {
    return res.status(400).json({ error: "invalid_job_request" });
  }

  const next = mutateStore((data) => {
    const jobId = `job-${String(data.counters.job++).padStart(6, "0")}`;
    const job = {
      jobId,
      deviceId: body.deviceId,
      type: body.type,
      payload: body.payload || {},
      status: "queued",
      createdAt: new Date().toISOString()
    };
    data.jobs.unshift(job);
    pushAudit(data, "job_created", { jobId, deviceId: body.deviceId, type: body.type });
    return data;
  });

  return res.status(201).json({ ok: true, jobId: next.jobs[0].jobId });
});

// Only start an HTTP listener when run directly (local dev, Azure App Service,
// bare metal). On serverless hosts (Vercel) the app is imported and invoked by
// the platform, so we must NOT call listen() there.
if (require.main === module) {
  app.listen(port, () => {
    console.log(`control-plane listening on http://localhost:${port} (store=${storeDriver})`);
  });
}

module.exports = app;
