# Azure Deployment Tree

Azure-first assets for RNFleetManager live here to prevent mixing with core product code.

## Target Resource Group

- **Subscription ID**: `bf9a0b19-cd7b-4515-ba71-0495728d691c`
- **Resource Group**: `RNFleet`

## Structure

- `environments/`: per-environment overlays and parameters
- `bootstrap/`: initial Azure bootstrapping assets (foundational resources + Packer marketplace-based appliance image builder)
- `appliance-image/`: publish the **validated golden appliance image** (same bits as bare-metal/Hyper-V) to Azure as a Gen2 VHD image — build → convert to fixed VHD → upload/create image → test VM. Preferred over the Packer build for byte-identical, provider-agnostic appliances.
- `pipelines/`: CI/CD definitions for Azure deployments

## Conventions

- Keep all Azure resource names and IDs in this tree.
- Keep reusable logic generic in `infra/cloud/shared` when possible.
- Never place Azure-specific assumptions in `apps/*` or `packages/*`.
