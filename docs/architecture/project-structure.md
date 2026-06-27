# Project Structure Guide

This structure keeps product code, shared logic, and operations concerns separated and easy to scale.

```text
apps/
  control-plane/
    src/
      api/            # External and internal APIs
      auth/           # Device and operator authn/authz
      registry/       # Device inventory and metadata
      config/         # Desired-state config service
      jobs/           # Rollout and operation orchestration
      telemetry/      # Health and metrics ingestion
      audit/          # Immutable operator/device actions
    tests/
    deploy/

  device-runtime/
    src/
      bootstrap/      # First-boot provisioning and claim flow
      agents/
        management/   # Pull jobs, send status, execute actions
        network/      # Interface role assignment and routing
        tunnel/       # IPSec/WireGuard lifecycle management
        watchdog/     # Self-healing and service supervision
      platform/       # OS integrations (systemd, nftables, etc.)
      safety/         # Last-known-good state and rollback
    tests/
    packaging/

  portal/
    src/
      pages/          # Fleet, device, config, rollout pages
      components/     # Reusable UI modules
      services/       # API integration layer
      state/          # Store/query cache setup
      auth/           # Portal auth and RBAC hooks
    tests/
    deploy/

packages/
  contracts/          # API + device config schemas (versioned)
  device-sdk/         # Shared client for control-plane communication
  policy-engine/      # Config merge, validation, targeting rules
  shared/             # Logging, error model, utility libs

infra/
  cloud/
    shared/            # Provider-agnostic cloud standards and templates
    azure/             # Azure-only assets and environment overlays
  terraform/
    modules/          # Reusable infra modules
    envs/
      dev/
      staging/
      prod/
  kubernetes/         # App deployment manifests/charts
  observability/      # Dashboards, alert rules, SLO configs

operations/
  runbooks/           # Operational procedures
  incident-management/# Incident process and templates
  compliance/         # Security/compliance evidence artifacts

scripts/              # Local dev and CI helper scripts
```

## Naming and Ownership

- Keep modules aligned to domain boundaries, not technology layers.
- Each top-level app/package should have clear owners and release cadence.
- Keep cross-domain dependencies flowing through `packages/contracts` and `packages/shared`.
- Keep cloud-specific files isolated under `infra/cloud/<provider>` to avoid coupling core code to one cloud.
