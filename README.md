# Frostlink

Single-node Talos Kubernetes cluster on Oracle Cloud Always Free Ampere A1 (ca-toronto-1).  
Managed by FluxCD from this repository. Domain: [frostlink.dev](https://frostlink.dev).

## Structure

- `talos/` — Talos machine config and schematic
- `kubernetes/flux/` — Flux sync entrypoint
- `kubernetes/apps/` — Workloads reconciled by Flux
