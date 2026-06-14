# Frostlink

Single-node Talos Kubernetes cluster on Oracle Cloud Always Free Ampere A1 (ca-toronto-1).  
Managed by FluxCD from this repository. Domain: [frostlink.dev](https://frostlink.dev).

## Cluster

| | |
| --- | --- |
| **Node** | VM.Standard.A1.Flex — 4 OCPU / 24 GB RAM (ARM64) |
| **OS** | Talos Linux v1.13.4 |
| **Kubernetes** | v1.36.1 |
| **CNI** | Cilium 1.17.4 |
| **GitOps** | Flux CD v2.8.8 via flux-operator |
| **Secrets** | 1Password ExternalSecret (no SOPS) |

## Structure

- `talos/` — Talos schematic and machine config patches
- `bootstrap/` — One-time helmfile bootstrap (secrets + Flux install)
- `kubernetes/flux/` — Flux sync entrypoint
- `kubernetes/apps/` — Workloads reconciled by Flux
