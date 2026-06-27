const CONFIG_VERSION = "v1";

const DEFAULT_DEVICE_CONFIG = {
  version: 1,
  siteId: "default-site",
  network: {
    wanInterface: "eth0",
    lanInterface: "eth1",
    lanCidr: "192.168.50.0/24"
  },
  tunnel: {
    type: "ipsec",
    enabled: true,
    remoteEndpoint: "gsa-endpoint-placeholder",
    localBgpAddress: "10.2.0.4",
    peerBgpAddress: "192.168.1.2",
    asn: 65533
  }
};

const JOB_TYPES = Object.freeze({
  RESTART_TUNNEL: "restart_tunnel",
  RUN_DIAGNOSTICS: "run_diagnostics",
  APPLY_CONFIG: "apply_config"
});

function validateDeviceRegistration(input) {
  return Boolean(input && typeof input.deviceId === "string" && input.deviceId.trim().length > 0);
}

function validateHeartbeat(input) {
  if (!input || typeof input.status !== "string") {
    return false;
  }
  if (input.networkState == null) {
    return true;
  }
  if (typeof input.networkState !== "object") {
    return false;
  }
  const { wanIp, wanPublicIp, lanIp, routes } = input.networkState;
  if (wanIp != null && typeof wanIp !== "string") {
    return false;
  }
  if (wanPublicIp != null && typeof wanPublicIp !== "string") {
    return false;
  }
  if (lanIp != null && typeof lanIp !== "string") {
    return false;
  }
  if (routes != null && !Array.isArray(routes)) {
    return false;
  }
  if (input.networkState.interfaces != null) {
    if (!Array.isArray(input.networkState.interfaces)) {
      return false;
    }
    for (const iface of input.networkState.interfaces) {
      if (!iface || typeof iface !== "object") {
        return false;
      }
      if (iface.name != null && typeof iface.name !== "string") {
        return false;
      }
      if (iface.mac != null && typeof iface.mac !== "string") {
        return false;
      }
      if (iface.ipv4 != null && !Array.isArray(iface.ipv4)) {
        return false;
      }
      if (iface.ipv6 != null && !Array.isArray(iface.ipv6)) {
        return false;
      }
    }
  }
  return true;
}

function validateJobType(type) {
  return Object.values(JOB_TYPES).includes(type);
}

module.exports = {
  CONFIG_VERSION,
  DEFAULT_DEVICE_CONFIG,
  JOB_TYPES,
  validateDeviceRegistration,
  validateHeartbeat,
  validateJobType
};
