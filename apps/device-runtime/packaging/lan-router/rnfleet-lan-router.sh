#!/usr/bin/env bash
#
# rnfleet-lan-router — make the appliance a LAN default gateway that routes client
# traffic to GSA (split tunnel) and the local WAN.
#
#   LAN client --(default gw = appliance LAN IP)--> Appliance --> ipsec-gsa (GSA)
#                                                              \-> WAN (local internet)
#
# Usage:  rnfleet-lan-router up | down
#
# Driven by /etc/rnfleet/lan-router.conf. Auto-detects the LAN NIC (the wired
# device that is not WAN/tunnel/loopback); if there is no separate LAN NIC (e.g. a
# single-NIC cloud VM) it no-ops cleanly so the unit never fails.
#
# Split tunnel: GSA's BGP-advertised prefixes already resolve via ipsec-gsa in the
# main routing table, so forwarded LAN packets follow longest-prefix-match — GSA
# destinations go through the tunnel, everything else out the WAN. We add NAT
# (masquerade) on BOTH egress paths plus forwarding allow rules, and serve DHCP/DNS
# on the LAN so clients pick up the appliance as their gateway automatically.
set -eu

CONF="${RNFLEET_LAN_ROUTER_CONF:-/etc/rnfleet/lan-router.conf}"
NFT_TABLE="rnfleet_router"
DNSMASQ_CONF="/etc/dnsmasq.d/rnfleet-lan-router.conf"
log() { echo "rnfleet-lan-router: $*"; }

# --- defaults (overridden by CONF) ----------------------------------------
LAN_ROUTER_ENABLED=true
LAN_IFACE=auto
LAN_CIDR=192.168.100.1/24
DHCP_RANGE_START=192.168.100.100
DHCP_RANGE_END=192.168.100.200
DHCP_LEASE=12h
UPSTREAM_DNS=1.1.1.1,8.8.8.8
TUNNEL_IFACE=ipsec-gsa
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

LAN_GW_IP="${LAN_CIDR%%/*}"

detect_wan() { ip route show default 2>/dev/null | awk '/default/{print $5; exit}'; }

detect_lan() {
  local wan="$1" dev
  for dev in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//'); do
    case "$dev" in
      lo|"$wan"|"$TUNNEL_IFACE"|ipsec*|docker*|veth*|virbr*|br-*|tun*|tap*) continue ;;
    esac
    # only real wired NICs
    case "$dev" in en*|eth*|eno*|ens*|enp*) echo "$dev"; return 0 ;; esac
  done
  return 1
}

apply_nftables() {
  local lan="$1" wan="$2"
  nft list table ip "$NFT_TABLE" >/dev/null 2>&1 && nft delete table ip "$NFT_TABLE"
  nft -f - <<EOF
table ip ${NFT_TABLE} {
  chain forward {
    type filter hook forward priority 0; policy accept;
    ct state established,related accept
    iifname "${lan}" accept
    ct state invalid drop
  }
  chain postrouting {
    type nat hook postrouting priority 100; policy accept;
    ip saddr ${LAN_CIDR%%/*}/${LAN_CIDR##*/} oifname "${wan}" masquerade
    ip saddr ${LAN_CIDR%%/*}/${LAN_CIDR##*/} oifname "${TUNNEL_IFACE}" masquerade
  }
}
EOF
}

write_dnsmasq() {
  local lan="$1"
  cat > "$DNSMASQ_CONF" <<EOF
# Managed by rnfleet-lan-router — do not edit by hand.
interface=${lan}
bind-dynamic
except-interface=lo
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE}
# Option 3 = default gateway, Option 6 = DNS server (the appliance itself).
dhcp-option=3,${LAN_GW_IP}
dhcp-option=6,${LAN_GW_IP}
domain-needed
bogus-priv
EOF
  # Upstream resolvers dnsmasq forwards to (one server= line each).
  local IFS=','
  for s in $UPSTREAM_DNS; do echo "server=${s}" >> "$DNSMASQ_CONF"; done
}

up() {
  if [ "${LAN_ROUTER_ENABLED}" != "true" ]; then
    log "disabled (LAN_ROUTER_ENABLED=${LAN_ROUTER_ENABLED}); nothing to do"; exit 0
  fi
  local wan lan
  wan="$(detect_wan || true)"
  [ -z "$wan" ] && { log "no WAN default route yet; deferring"; exit 0; }

  if [ "$LAN_IFACE" = "auto" ]; then
    lan="$(detect_lan "$wan" || true)"
  else
    lan="$LAN_IFACE"
  fi
  if [ -z "${lan:-}" ]; then
    log "no separate LAN interface (WAN=${wan}); single-NIC host, LAN router not applicable"; exit 0
  fi
  if ! ip link show "$lan" >/dev/null 2>&1; then
    log "configured LAN interface '$lan' not present; skipping"; exit 0
  fi

  log "LAN=${lan} (${LAN_CIDR})  WAN=${wan}  tunnel=${TUNNEL_IFACE}"

  # 1. Bring up the LAN interface with the gateway address.
  ip addr replace "$LAN_CIDR" dev "$lan"
  ip link set "$lan" up

  # 2. Enable IPv4 forwarding (also persisted by provisioning).
  sysctl -wq net.ipv4.ip_forward=1

  # 3. NAT + forward rules (split tunnel: GSA prefixes -> ipsec-gsa, rest -> WAN).
  apply_nftables "$lan" "$wan"

  # 4. DHCP + DNS for LAN clients (appliance advertises itself as gw + resolver).
  write_dnsmasq "$lan"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable dnsmasq >/dev/null 2>&1 || true
    systemctl restart dnsmasq || log "warning: dnsmasq restart failed"
  fi
  log "LAN router active: clients on ${lan} use ${LAN_GW_IP} as gateway+DNS"
}

down() {
  nft list table ip "$NFT_TABLE" >/dev/null 2>&1 && nft delete table ip "$NFT_TABLE" || true
  rm -f "$DNSMASQ_CONF"
  command -v systemctl >/dev/null 2>&1 && systemctl restart dnsmasq >/dev/null 2>&1 || true
  log "LAN router rules removed"
}

case "${1:-up}" in
  up)   up ;;
  down) down ;;
  *)    echo "usage: $0 up|down" >&2; exit 2 ;;
esac
