#!/usr/bin/env bash
#
# rnfleet-setup — RNFleet appliance first-boot enrollment wizard.
#
# Installed to /usr/local/sbin/rnfleet-setup. Asks the operator for the MINIMUM
# configuration needed to join an appliance to a control-plane, writes
# /etc/rnfleet/device-runtime.env, then enables and starts the device runtime.
#
# Modes:
#   rnfleet-setup                 interactive wizard (run by the operator)
#   sudo rnfleet-setup --force    re-enroll an already-configured appliance
#   rnfleet-setup --firstboot     called by rnfleet-firstboot.service on the
#                                 console at boot; runs unattended if a preseed
#                                 is present, otherwise prompts on the console,
#                                 and never blocks boot when there is no TTY.
#                                 Set FIRSTBOOT_INTERACTIVE=true in the preseed to
#                                 force the wizard to appear with all fields (incl.
#                                 the PSK) pre-filled as defaults.
#   rnfleet-setup --unattended    no prompts; use preseed/env only (fail if a
#                                 required value is missing).
#
# Pre-seed (for unattended/cloud enrolment) — first match wins per field:
#   1. environment variables (CONTROL_PLANE_URL, FLEET_PSK, DEVICE_ID, ...)
#   2. /etc/rnfleet/enrollment.conf  (KEY=VALUE lines)
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Vendor defaults baked into the image. Override CONTROL_PLANE_URL here when you
# build a branded appliance image for a specific control-plane.
# ----------------------------------------------------------------------------
BAKED_CONTROL_PLANE_URL="${RNFLEET_BAKED_CP_URL:-https://rn-fleet-manager-control-plane.vercel.app}"
DEFAULT_SITE_ID="default-site"

ENV_FILE="/etc/rnfleet/device-runtime.env"
PRESEED_FILE="/etc/rnfleet/enrollment.conf"
SENTINEL="/var/lib/rnfleet/.configured"
RUNTIME_SVC="rnfleet-device-runtime.service"

FORCE=0
UNATTENDED=0
FIRSTBOOT=0
for arg in "$@"; do
  case "$arg" in
    --force)      FORCE=1 ;;
    --unattended) UNATTENDED=1 ;;
    --firstboot)  FIRSTBOOT=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed '1d'
      exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "rnfleet-setup must run as root (try: sudo rnfleet-setup)" >&2
  exit 1
fi

# Already enrolled? In firstboot mode just make sure the runtime is running and
# exit quietly; otherwise require --force to re-enroll.
if [ -f "$SENTINEL" ] && [ "$FORCE" -ne 1 ]; then
  if [ "$FIRSTBOOT" -eq 1 ]; then
    systemctl is-active --quiet "$RUNTIME_SVC" || systemctl start "$RUNTIME_SVC" || true
    exit 0
  fi
  echo "This appliance is already enrolled ($ENV_FILE)."
  echo "Re-run with --force to reconfigure it."
  exit 0
fi

# ----------------------------------------------------------------------------
# Gather pre-seed values (env first, then enrollment.conf).
# ----------------------------------------------------------------------------
PS_CP=""; PS_PSK=""; PS_TPSK=""; PS_DID=""; PS_SID=""; PS_FBI=""
if [ -f "$PRESEED_FILE" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      CONTROL_PLANE_URL)    PS_CP="$v" ;;
      FLEET_PSK)            PS_PSK="$v" ;;
      TUNNEL_PSK)           PS_TPSK="$v" ;;
      DEVICE_ID)            PS_DID="$v" ;;
      SITE_ID)              PS_SID="$v" ;;
      FIRSTBOOT_INTERACTIVE) PS_FBI="$v" ;;
    esac
  done < <(grep -E '^[A-Z_]+=' "$PRESEED_FILE" || true)
fi
# Environment variables win over the file.
PS_CP="${CONTROL_PLANE_URL:-$PS_CP}"
PS_PSK="${FLEET_PSK:-$PS_PSK}"
PS_TPSK="${TUNNEL_PSK:-$PS_TPSK}"
PS_DID="${DEVICE_ID:-$PS_DID}"
PS_SID="${SITE_ID:-$PS_SID}"
PS_FBI="${FIRSTBOOT_INTERACTIVE:-$PS_FBI}"
# Normalise the interactive-firstboot flag to 1/0.
case "${PS_FBI,,}" in 1|true|yes|on) PS_FBI=1 ;; *) PS_FBI=0 ;; esac

# Stable, unique default Device ID derived from the machine-id (each generalized
# image clone gets a fresh machine-id, so appliances do not collide).
gen_device_id() {
  local mid=""
  [ -r /etc/machine-id ] && mid="$(tr -dc 'a-f0-9' < /etc/machine-id | head -c 10)"
  if [ -n "$mid" ]; then echo "rnfleet-$mid"; else echo "rnfleet-$(hostname -s 2>/dev/null || echo device)"; fi
}

# Decide whether we can prompt. firstboot with no TTY + no preseed must not block.
# In firstboot mode a valid pre-seed (FLEET_PSK present) normally means fully
# UNATTENDED enrollment — never prompt, even when a console TTY is attached
# (otherwise a headless appliance would hang waiting for Enter). Setting
# FIRSTBOOT_INTERACTIVE=true in the pre-seed opts out: the wizard is shown on the
# console with every field (including the PSK) pre-filled as a default, so the
# operator just presses Enter to accept or types an override.
if [ "$FIRSTBOOT" -eq 1 ] && [ -n "$PS_PSK" ] && [ "$PS_FBI" -ne 1 ]; then UNATTENDED=1; fi
INTERACTIVE=0
if [ "$UNATTENDED" -ne 1 ] && [ -t 0 ]; then INTERACTIVE=1; fi

if [ "$INTERACTIVE" -ne 1 ] && [ -z "$PS_PSK" ]; then
  # No way to ask and nothing pre-seeded — leave the appliance unenrolled and
  # tell the operator how to finish. Do not fail (so boot completes cleanly).
  cat <<EOF

  ====================================================================
   RNFleet appliance is NOT yet enrolled.
   Log in and run:   sudo rnfleet-setup
   (or drop a pre-seed file at $PRESEED_FILE and reboot)
  ====================================================================

EOF
  exit 0
fi

# ----------------------------------------------------------------------------
# Resolve each value (prompt when interactive, else use preseed/default).
# ----------------------------------------------------------------------------
ask_secret() { # ask_secret <prompt> <default> -> echoes answer (input hidden)
  local prompt="$1" def="$2" ans=""
  if [ "$INTERACTIVE" -eq 1 ]; then
    read -r -s -p "$prompt: " ans; echo "" >&2
    echo "${ans:-$def}"
  else
    echo "$def"
  fi
}
ask_required() { # ask_required <prompt> <default> -> echoes a NON-EMPTY answer (loops)
  local prompt="$1" def="$2" ans=""
  if [ "$INTERACTIVE" -ne 1 ]; then echo "$def"; return; fi
  while : ; do
    if [ -n "$def" ]; then read -r -p "$prompt [$def]: " ans; else read -r -p "$prompt: " ans; fi
    ans="${ans:-$def}"
    [ -n "$ans" ] && { echo "$ans"; return; }
    echo "  This value is required, please enter it." >&2
  done
}
ask_confirmed() { # ask_confirmed <prompt> <default> -> ask, then Y/n confirm; loops
  local prompt="$1" def="$2" ans="" yn=""
  if [ "$INTERACTIVE" -ne 1 ]; then echo "$def"; return; fi
  while : ; do
    ans="$(ask_required "$prompt" "$def")"
    read -r -p "  Use \"$ans\"? [Y/n]: " yn
    case "${yn,,}" in
      ""|y|yes) echo "$ans"; return ;;
      *) def="$ans" ;;   # re-ask, keeping their last answer as the default
    esac
  done
}

# Print a summary of the appliance's network interfaces: link state, IPv4
# address/subnet (CIDR), MAC, plus the default gateway and DNS servers. Helps the
# operator confirm the WAN/LAN got the expected addressing before enrolling.
show_network_summary() {
  command -v ip >/dev/null 2>&1 || return 0
  local gw gwdev dns
  gw="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')" || gw=""
  gwdev="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')" || gwdev=""
  dns=""
  [ -r /etc/resolv.conf ] && dns="$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)"
  echo "  +------------------------------------------------------------+"
  echo "  |  Network interfaces                                         |"
  echo "  +------------------------------------------------------------+"
  printf '    %-8s %-5s %-20s %s\n' "IFACE" "LINK" "IPv4 (addr/mask)" "MAC"
  local ifname state mac cidr ifpath
  for ifpath in /sys/class/net/*; do
    ifname="$(basename "$ifpath")"
    [ "$ifname" = "lo" ] && continue
    state="$(cat "/sys/class/net/$ifname/operstate" 2>/dev/null || echo '?')"
    mac="$(cat "/sys/class/net/$ifname/address" 2>/dev/null || echo '?')"
    cidr="$(ip -o -4 addr show dev "$ifname" 2>/dev/null | awk '{print $4}' | paste -sd, - 2>/dev/null)"
    [ -z "$cidr" ] && cidr="(no IPv4)"
    printf '    %-8s %-5s %-20s %s\n' "$ifname" "$state" "$cidr" "$mac"
  done
  echo ""
  if [ -n "$gw" ]; then
    printf '    Default gateway : %s%s\n' "$gw" "${gwdev:+  (via $gwdev)}"
  else
    echo "    Default gateway : (none — no default route yet)"
  fi
  [ -n "$dns" ] && printf '    DNS servers     : %s\n' "$dns"
  echo ""
}

if [ "$INTERACTIVE" -eq 1 ]; then
  [ -f /etc/rnfleet/logo.txt ] && cat /etc/rnfleet/logo.txt
  cat <<'EOF'

  +------------------------------------------------------------+
  |            RNFleet Appliance - First-Boot Setup            |
  |  Enter the details to connect this appliance to your fleet. |
  +------------------------------------------------------------+

EOF
  show_network_summary || true
fi

# Seed the working defaults (preseed/baked) for the first pass. On a "no" at the
# confirmation prompt the operator's own answers become the defaults next pass.
CP_URL="${PS_CP:-$BAKED_CONTROL_PLANE_URL}"
DEV_ID="${PS_DID:-$(gen_device_id)}"
SITE_ID_V="${PS_SID:-$DEFAULT_SITE_ID}"
FLEET_PSK_V="$PS_PSK"
TUNNEL_PSK_V="${PS_TPSK:-}"

if [ "$INTERACTIVE" -eq 1 ]; then
  while : ; do
    # Required text fields — ask, then Y/n confirm each before moving on.
    CP_URL="$(ask_confirmed 'Control-plane URL' "$CP_URL")"
    DEV_ID="$(ask_confirmed 'Device ID (unique name)' "$DEV_ID")"
    SITE_ID_V="$(ask_confirmed 'Site ID' "$SITE_ID_V")"

    # Enrollment key (fleet PSK) — required; Enter keeps the current value; confirm.
    while : ; do
      if [ -n "$FLEET_PSK_V" ]; then
        ANS="$(ask_secret 'Enrollment key (fleet PSK) (Enter to keep current)' "$FLEET_PSK_V")"
      else
        ANS="$(ask_secret 'Enrollment key (fleet PSK)' '')"
      fi
      [ -z "$ANS" ] && { echo "  Enrollment key is required, please enter it."; continue; }
      read -r -p "  Use this enrollment key? [Y/n]: " YN
      case "${YN,,}" in ""|y|yes) FLEET_PSK_V="$ANS"; break ;; esac
    done

    # Tunnel PSK — optional; confirm the choice (set vs. reuse enrollment key).
    while : ; do
      ANS="$(ask_secret 'IPSec tunnel PSK (optional, Enter to skip)' "$TUNNEL_PSK_V")"
      if [ -n "$ANS" ]; then
        read -r -p "  Use this tunnel PSK? [Y/n]: " YN
      else
        read -r -p "  Skip tunnel PSK (reuse enrollment key)? [Y/n]: " YN
      fi
      case "${YN,,}" in ""|y|yes) TUNNEL_PSK_V="$ANS"; break ;; esac
    done

    CP_URL="${CP_URL%/}"

    # ------------------------------------------------------------------------
    # Confirmation summary — nothing is written until the operator confirms.
    # ------------------------------------------------------------------------
    echo ""
    echo "  Please confirm this configuration:"
    echo "    Control-plane URL : $CP_URL"
    echo "    Device ID         : $DEV_ID"
    echo "    Site ID           : $SITE_ID_V"
    echo "    Enrollment key    : (set)"
    if [ -n "$TUNNEL_PSK_V" ]; then
      echo "    IPSec tunnel PSK  : (set)"
    else
      echo "    IPSec tunnel PSK  : (none — will reuse the enrollment key)"
    fi
    echo ""
    read -r -p "  Apply this configuration? [Y/n]: " CONFIRM
    case "${CONFIRM,,}" in
      ""|y|yes) break ;;
      *) echo ""; echo "  No problem — let's go through it again."; echo "" ;;
    esac
  done
fi

# Final normalisation + non-interactive validation.
CP_URL="${CP_URL%/}"
[ -z "$TUNNEL_PSK_V" ] && TUNNEL_PSK_V="$FLEET_PSK_V"
if [ -z "$FLEET_PSK_V" ]; then
  echo "rnfleet-setup: enrollment key (FLEET_PSK) is required" >&2
  exit 1
fi
if [ -z "$CP_URL" ] || [ -z "$DEV_ID" ] || [ -z "$SITE_ID_V" ]; then
  echo "rnfleet-setup: control-plane URL, device ID and site ID are all required" >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# Optional connectivity check (advisory only).
# ----------------------------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  if curl -fsS --max-time 8 "$CP_URL/health" >/dev/null 2>&1; then
    echo "  [ok] Control-plane reachable at $CP_URL"
  else
    echo "  [!] Warning: could not reach $CP_URL/health (continuing anyway)."
    echo "      Ensure outbound HTTPS (443) to the control-plane is allowed."
  fi
fi

# ----------------------------------------------------------------------------
# Write the runtime env and enable the service.
# ----------------------------------------------------------------------------
# Guard against a parallel enrollment from the OTHER console: the wizard is shown
# on both the video console and the serial port, so the first one to finish
# creates the sentinel. If that happened while we were still prompting here, do
# NOT re-enroll — just make sure the runtime is up and drop to the login prompt.
if [ "$FIRSTBOOT" -eq 1 ] && [ -f "$SENTINEL" ] && [ "$FORCE" -ne 1 ]; then
  echo ""
  echo "  This appliance was just enrolled from another console — nothing to do."
  systemctl is-active --quiet "$RUNTIME_SVC" || systemctl start "$RUNTIME_SVC" || true
  exit 0
fi
install -d -m 0755 /etc/rnfleet
umask 077
cat > "$ENV_FILE" <<EOF
# Generated by rnfleet-setup on $(date -u +%Y-%m-%dT%H:%M:%SZ)
CONTROL_PLANE_URL=$CP_URL
FLEET_PSK=$FLEET_PSK_V
TUNNEL_PSK=$TUNNEL_PSK_V
DEVICE_ID=$DEV_ID
SITE_ID=$SITE_ID_V
LOOP_SECONDS=10
EOF
chmod 0600 "$ENV_FILE"

install -d -m 0750 -o rnfleet -g rnfleet /var/lib/rnfleet 2>/dev/null || install -d -m 0750 /var/lib/rnfleet
date -u +%Y-%m-%dT%H:%M:%SZ > "$SENTINEL"

systemctl enable "$RUNTIME_SVC" >/dev/null 2>&1 || true
systemctl restart "$RUNTIME_SVC"

cat <<EOF

  [ok] Appliance enrolled.
      Device ID : $DEV_ID
      Site      : $SITE_ID_V
      Control-plane: $CP_URL

  The device runtime is starting. Check status with:
      systemctl status $RUNTIME_SVC
      journalctl -u $RUNTIME_SVC -f

EOF
exit 0
