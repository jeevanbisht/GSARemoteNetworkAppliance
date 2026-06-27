# RNFleet Ubuntu Appliance Image (Azure)

This folder contains the first image-build scaffold for RNFleet appliance runtime.

## What it builds

- Ubuntu LTS managed image in Azure (`RNFleet` resource group by default)
- Preinstalled Node.js 22
- Preinstalled RNFleet device runtime code (`apps/device-runtime` + `packages/contracts`)
- Preinstalled tunnel stack: **strongSwan (swanctl/vici)** + **FRR** (BGP daemon
  enabled), IP forwarding on. The `strongswan` (charon-systemd) service is enabled;
  the legacy `strongswan-starter` is disabled because the tunnel agent drives
  `swanctl`/vici (route-based XFRM via `if_id`).
- **First-boot enrollment wizard** (`rnfleet-setup`): the device runtime is shipped
  **disabled** with no baked-in identity, so every appliance cloned from the image
  prompts the operator for the minimum config on first boot, then enables itself.
- Systemd services: `rnfleet-firstboot.service` (enabled — runs the wizard until
  the appliance is enrolled) and `rnfleet-device-runtime.service` (disabled until
  enrollment completes).
- Environment file path: `/etc/rnfleet/device-runtime.env` (written by the wizard)

## Files

- `ubuntu-appliance.pkr.hcl`: Packer template (Azure ARM builder)
- `variables.pkrvars.hcl.example`: sample input variables
- `build-image.ps1`: helper script to run `packer init` and `packer build`
- Appliance enrollment assets (from `apps/device-runtime/packaging/`):
  - `firstboot/rnfleet-setup.sh` -> `/usr/local/sbin/rnfleet-setup` (the wizard)
  - `systemd/rnfleet-firstboot.service` -> runs the wizard on the console at boot
  - `firstboot/30-rnfleet` -> `/etc/update-motd.d/30-rnfleet` (login status banner)
  - `firstboot/enrollment.conf.example` -> `/etc/rnfleet/enrollment.conf.example`
    (copy to `enrollment.conf` for unattended/cloud enrollment)

## Build steps

1. Install prerequisites:
   - Azure CLI (`az`) and sign in
   - Packer
2. Copy and edit vars:
   - `Copy-Item .\\variables.pkrvars.hcl.example .\\variables.pkrvars.hcl`
3. Run build:
   - `.\build-image.ps1`

The build generalizes the image (clears `machine-id`, runs `waagent -deprovision`)
so each VM created from it gets a fresh machine-id. The wizard derives the default
Device ID from the machine-id, so appliances do not collide.

## Post-build on first VM boot

Every VM created from this image is an **unenrolled appliance**. Choose one of:

**A. Interactive (default customer experience)**

1. The wizard runs automatically on the console at first boot and prompts for the
   minimum config (Control-plane URL, Device ID, Site ID, Enrollment key / fleet
   PSK, optional tunnel PSK). If the console is non-interactive, log in and run:
   - `sudo rnfleet-setup`
2. On completion the wizard writes `/etc/rnfleet/device-runtime.env`, drops the
   sentinel `/var/lib/rnfleet/.configured`, and enables + starts the runtime.
3. Re-enroll any time with `sudo rnfleet-setup --force`.

**B. Unattended / cloud (no prompts)**

1. Provide a pre-seed before first boot — either:
   - drop `/etc/rnfleet/enrollment.conf` (see `enrollment.conf.example`, e.g. via
     cloud-init `write_files`), or
   - set `CONTROL_PLANE_URL` / `FLEET_PSK` / `DEVICE_ID` / `SITE_ID` / `TUNNEL_PSK`
     in the firstboot service environment.
2. On first boot the wizard enrolls silently and starts the runtime. Only
   `FLEET_PSK` is strictly required; a blank `DEVICE_ID` is auto-generated.

Verify after enrollment:
   - `systemctl status rnfleet-device-runtime`
   - `journalctl -u rnfleet-device-runtime -f`
   - The login banner (MOTD) shows ENROLLED + the Device ID and control-plane.

## Notes

- This is a PSK-first bootstrap for end-to-end validation.
- Replace shared PSK with per-device identity in production.
- Tunnel PSK / IKE-IPSec policy can also be pushed later from the portal, so the
  operator can skip the tunnel PSK prompt at enrollment time.

