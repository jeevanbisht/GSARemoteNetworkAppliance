# Infrastructure

Infrastructure and deployment assets for all environments.

## Layout

- `cloud/shared`: provider-agnostic cloud conventions and patterns
- `cloud/azure`: Azure-specific infrastructure and deployment assets
- `terraform/modules`: reusable infrastructure primitives
- `terraform/envs`: environment-specific stacks (`dev`, `staging`, `prod`)
- `kubernetes`: runtime deployment manifests/charts
- `observability`: dashboards, alerts, and SLO configs

## Boundary Rule

Keep product behavior out of `infra/*`.  
`apps/*` and `packages/*` define product logic; `infra/*` defines where and how it is deployed.
