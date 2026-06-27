#!/usr/bin/env bash
#
# azure-configure.sh — Azure-readiness layer for the RNFleet appliance image.
#
# This is an EXTRA_CONFIGURE hook for build-min-appliance.sh. It runs INSIDE the
# target chroot, after the appliance has been provisioned and before the
# bootloader is installed. It assumes the Azure provisioning packages were added
# to the rootfs via EXTRA_INCLUDE (cloud-init, waagent — the latter ships
# /etc/waagent.conf and walinuxagent.service); see build-azure-appliance.ps1
# which wires both together.
#
# Goal: make the SAME validated appliance image provision cleanly on Azure
# (Gen2 / Hyper-V) without changing how it boots on bare-metal or other
# hypervisors. Everything here is Azure-only at runtime and inert elsewhere:
#   - walinuxagent + cloud-init report provisioning-complete to the platform so
#     the VM does not time out in "Creating".
#   - cloud-init reads Azure custom-data, enabling the unattended enrollment
#     pre-seed (drop /etc/rnfleet/enrollment.conf) with no console interaction.
#   - Hyper-V (hv_*) modules are forced into the initramfs so Gen2 boot finds the
#     SCSI/NIC on the VMBus.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "azure-configure: starting"

# --- 1. Hyper-V drivers in the initramfs (Azure Gen2 boots on VMBus) ----------
# linux-image-amd64 ships these as modules; force-include them so storvsc/netvsc
# are present in early boot regardless of the autodetect policy.
for m in hv_vmbus hv_storvsc hv_netvsc hv_utils hid_hyperv; do
  grep -qxF "$m" /etc/initramfs-tools/modules 2>/dev/null || echo "$m" >> /etc/initramfs-tools/modules
done

# --- 2. cloud-init: Azure datasource, keep OUR networking authoritative -------
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/90-azure-datasource.cfg <<'EOF'
# RNFleet: only look for the Azure datasource (plus NoCloud for local seeding).
datasource_list: [ Azure, NoCloud, None ]
EOF
# Do NOT let cloud-init rewrite the network config — the appliance manages eth0
# (WAN/DHCP) and eth1 (LAN router) via /etc/network/interfaces. cloud-init only
# handles provisioning + custom-data here.
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF

# --- 3. walinuxagent: provisioning only, no resource-disk/swap, no autoupdate -
if [ -f /etc/waagent.conf ]; then
  sed -i \
    -e 's/^Provisioning.Agent=.*/Provisioning.Agent=cloud-init/' \
    -e 's/^Provisioning.UseCloudInit=.*/Provisioning.UseCloudInit=y/' \
    -e 's/^ResourceDisk.Format=.*/ResourceDisk.Format=n/' \
    -e 's/^ResourceDisk.EnableSwap=.*/ResourceDisk.EnableSwap=n/' \
    -e 's/^AutoUpdate.Enabled=.*/AutoUpdate.Enabled=n/' \
    /etc/waagent.conf
  grep -q '^Provisioning.Agent=' /etc/waagent.conf || echo 'Provisioning.Agent=cloud-init' >> /etc/waagent.conf
  grep -q '^Provisioning.UseCloudInit=' /etc/waagent.conf || echo 'Provisioning.UseCloudInit=y' >> /etc/waagent.conf
fi

# --- 4. Enable the agent unit offline (chroot has no running systemd) ----------
mkdir -p /etc/systemd/system/multi-user.target.wants
if [ -f /lib/systemd/system/walinuxagent.service ]; then
  ln -sf /lib/systemd/system/walinuxagent.service \
    /etc/systemd/system/multi-user.target.wants/walinuxagent.service
fi
# cloud-init enables itself via its systemd generator when a datasource is found;
# no manual *.wants symlinks needed.

# --- 5. Rebuild the initramfs so the hv_* modules take effect -----------------
KVER="$(ls /lib/modules 2>/dev/null | head -n1 || true)"
if [ -n "$KVER" ]; then
  update-initramfs -u -k "$KVER" || update-initramfs -u || true
else
  update-initramfs -u || true
fi

echo "azure-configure: done"
echo "  cloud-init datasource : Azure (network mgmt disabled)"
echo "  walinuxagent          : enabled, Provisioning.Agent=cloud-init"
ls -l /etc/systemd/system/multi-user.target.wants/walinuxagent.service 2>/dev/null || \
  echo "  NOTE walinuxagent.service not enabled (waagent package absent) — cloud-init handles provisioning agentlessly"
