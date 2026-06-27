# ADR-0001: Monorepo with Strict Domain Boundaries

- **Status**: Accepted
- **Date**: 2026-06-19

## Context

The platform must support edge-device runtime, centralized management, and operator UX while scaling teams and deployments independently.

## Decision

Use a monorepo organized by domain:

- `apps/` for deployable systems
- `packages/` for shared contracts and logic
- `infra/` for platform provisioning and deployments
- `operations/` for runbooks and compliance

Require all cross-service interfaces to be modeled in `packages/contracts`.

## Consequences

### Positive

- Faster coordinated changes across device + backend + portal
- Shared validation and policy logic reuse
- Clear architecture discoverability for new contributors

### Trade-offs

- Requires strong ownership and dependency discipline
- CI must support selective builds/tests by changed paths
