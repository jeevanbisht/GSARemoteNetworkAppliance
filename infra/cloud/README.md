# Cloud Provider Layout

This directory isolates provider-specific deployment assets from core platform code.

## Structure

- `shared/`: cloud-agnostic conventions, templates, and standards
- `azure/`: Azure-specific resources, environment overlays, and pipelines

## Rule

Do not place product logic in this directory.  
Anything here should be replaceable if another cloud provider is added later.
