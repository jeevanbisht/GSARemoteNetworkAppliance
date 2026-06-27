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
    linkName: "",
    gsa: {
      endpoint: "",
      asn: 65476,
      bgpAddress: "192.168.10.1",
      region: ""
    },
    peer: {
      endpoint: "",
      asn: 65001,
      bgpAddress: "192.168.10.2",
      localNetworks: []
    }
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

function validateTunnelConfig(tunnel) {
  if (tunnel == null) return { ok: true };
  if (typeof tunnel !== "object") return { ok: false, error: "invalid_tunnel" };
  if (tunnel.enabled !== undefined && typeof tunnel.enabled !== "boolean") {
    return { ok: false, error: "invalid_tunnel_enabled" };
  }
  if (tunnel.gsa != null) {
    const { gsa } = tunnel;
    if (gsa.asn !== undefined && (!Number.isInteger(gsa.asn) || gsa.asn <= 0)) {
      return { ok: false, error: "invalid_gsa_asn" };
    }
    if (gsa.endpoint !== undefined && typeof gsa.endpoint !== "string") {
      return { ok: false, error: "invalid_gsa_endpoint" };
    }
    if (gsa.bgpAddress !== undefined && typeof gsa.bgpAddress !== "string") {
      return { ok: false, error: "invalid_gsa_bgp_address" };
    }
  }
  if (tunnel.peer != null) {
    const { peer } = tunnel;
    if (peer.asn !== undefined && (!Number.isInteger(peer.asn) || peer.asn <= 0)) {
      return { ok: false, error: "invalid_peer_asn" };
    }
    if (peer.endpoint !== undefined && typeof peer.endpoint !== "string") {
      return { ok: false, error: "invalid_peer_endpoint" };
    }
    if (peer.bgpAddress !== undefined && typeof peer.bgpAddress !== "string") {
      return { ok: false, error: "invalid_peer_bgp_address" };
    }
    if (peer.localNetworks !== undefined && !Array.isArray(peer.localNetworks)) {
      return { ok: false, error: "invalid_peer_local_networks" };
    }
  }
  if (tunnel.psk !== undefined && typeof tunnel.psk !== "string") {
    return { ok: false, error: "invalid_tunnel_psk" };
  }
  if (tunnel.ipsecPolicy !== undefined && tunnel.ipsecPolicy !== null && typeof tunnel.ipsecPolicy !== "object") {
    return { ok: false, error: "invalid_ipsec_policy" };
  }
  return { ok: true };
}

function validateJobType(type) {
  return Object.values(JOB_TYPES).includes(type);
}

module.exports = {
  DEFAULT_DEVICE_CONFIG,
  JOB_TYPES,
  validateDeviceRegistration,
  validateHeartbeat,
  validateTunnelConfig,
  validateJobType
};
