# RNFleet Appliance Image for Azure (from the validated golden image)

This builds an **Azure Gen2 VM image** from the **same** minimal appliance bits
that are validated on bare-metal and Hyper-V — not a separate cloud-only build.
The flow is: build the appliance qcow2 (with a thin Azure provisioning layer) →
convert to a **fixed VHD** → upload + create a Gen2 image (and optionally an
Azure Compute Gallery version) → boot a test VM.

> Why this over the Packer build in `../bootstrap/image`? The Packer template
> provisions a VM from an Ubuntu **marketplace** base, so its bits differ from the
> appliance we ship to bare-metal/Hyper-V. This path keeps the appliance
> **byte-identical across all targets** (provider-agnostic), with Azure as just a
> test/deploy environment. Both paths can coexist.

## What the Azure layer adds (and why it's inert elsewhere)

The bare-metal builder (`infra/bare-metal/golden-image/build-min-appliance.sh`)
exposes two provider-neutral hooks; this tree uses them:

- `EXTRA_INCLUDE=cloud-init,waagent` — added to the rootfs (Debian bookworm ships
  the Azure Linux Agent as `waagent`, which provides `/etc/waagent.conf` +
  `walinuxagent.service`).
- `EXTRA_CONFIGURE=azure-configure.sh` — runs in the chroot to:
  - force the **Hyper-V (`hv_*`) modules into the initramfs** (Gen2 VMBus boot),
  - point **cloud-init at the Azure datasource** while **disabling cloud-init
    network management** (the appliance keeps managing eth0/eth1 via
    `/etc/network/interfaces`),
  - configure **walinuxagent** for provisioning only
    (`Provisioning.Agent=cloud-init`, no resource-disk/swap, no auto-update),
  - rebuild the initramfs.

`cloud-init`/`walinuxagent` only activate on Azure (they find no datasource on
bare-metal/Hyper-V), so the image still boots identically off-Azure. The default
bare-metal/Hyper-V build is unaffected — it sets neither hook.

## Files

| File | Purpose |
| --- | --- |
| `build-azure-appliance.ps1` | Build the Azure-flavored qcow2 + convert to fixed VHD (Docker). |
| `azure-configure.sh` | Chroot hook: cloud-init/walinuxagent/initramfs (Azure-readiness). |
| `convert-to-azure-vhd.sh` | qcow2 → **fixed** VHD, virtual size rounded to a whole MiB. |
| `publish-azure-image.ps1` | Upload page blob + create Gen2 managed image (+ optional gallery). |
| `create-azure-vm.ps1` | Boot a Gen2 test VM with serial console + optional pre-seed. |
| `enrollment.conf.example` | Unattended-enrollment pre-seed for `-EnrollmentConf`. |

## Prerequisites

- **Docker Desktop** (Linux containers) — for the build + VHD conversion. No
  Azure credentials needed for the build.
- **Azure CLI** (`az`) signed in (`az login`) — only for publish + VM steps.

## Build → publish → boot

```powershell
cd infra\cloud\azure\appliance-image

# 1) Build the Azure-flavored image and convert to a fixed VHD
#    (output: <repo>\dist\golden-azure\rnfleet-appliance-azure.vhd)
.\build-azure-appliance.ps1
#    Re-convert only (reuse an existing qcow2):
#    .\build-azure-appliance.ps1 -SkipBuild

# 2) Upload + create a Gen2 managed image in RG "RN1"
.\publish-azure-image.ps1 `
  -VhdPath ..\..\..\..\dist\golden-azure\rnfleet-appliance-azure.vhd `
  -Subscription 3b328940-6e2a-4b01-bcff-d2c8cfa0da1d -ResourceGroup RN1 -Location eastus2
#    Add Compute Gallery publishing:
#    .\publish-azure-image.ps1 -VhdPath ...\rnfleet-appliance-azure.vhd -Gallery rnfleetGallery -ImageVersion 1.0.0

# 3) Boot a test VM (serial console enabled)
.\create-azure-vm.ps1 -ImageId "<image id printed by step 2>" -ResourceGroup RN1 -Location eastus2
#    Unattended enrollment instead of the console wizard:
#    copy enrollment.conf.example -> enrollment.conf, edit, then:
#    .\create-azure-vm.ps1 -ImageId <id> -EnrollmentConf .\enrollment.conf
```

## First boot on Azure

- **Interactive (default):** open the Azure Serial Console
  (`az serial-console connect -n <vm> -g RN1`); the first-boot wizard runs on
  `ttyS0`, prints the **network-interfaces panel** (NIC IP/subnet/gateway/DNS),
  then prompts for Control-plane URL, Device ID, Site ID, and enrollment key.
- **Unattended:** pass `-EnrollmentConf` — cloud-init writes
  `/etc/rnfleet/enrollment.conf` and the appliance enrolls silently, then starts
  the device runtime.

Verify after enrollment:

```powershell
az serial-console connect -n <vm> -g RN1   # MOTD shows ENROLLED + Device ID
# on the appliance:  systemctl status rnfleet-device-runtime
```

## Notes / caveats

- Azure requires a **fixed VHD** whose virtual size is an exact multiple of
  **1 MiB**; `convert-to-azure-vhd.sh` enforces both (raw resize + `vpc`
  `subformat=fixed,force_size`). qcow2/VHDX are **not** accepted by Azure.
- The image is created with `--hyper-v-generation V2` (UEFI). It is published as
  a **Generalized** image, so each VM gets a fresh machine-id (the wizard derives
  the default Device ID from it, so appliances don't collide).
- Outbound to the control-plane uses ports 80/443. In subscriptions that block
  inbound (a separate constraint elsewhere), the appliance still enrolls because
  check-in is **outbound-only**; use the Serial Console instead of SSH.
- This is a PSK-first bootstrap for end-to-end validation; replace the shared
  PSK with per-device identity for production.
