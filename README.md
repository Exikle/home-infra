# Frostlink

Single-node Talos Kubernetes cluster on Oracle Cloud Always Free Ampere A1 (ca-toronto-1).  
Managed by FluxCD from this repository. Domain: [frostlink.dev](https://frostlink.dev).

<div align="center">

[![Talos](https://kromgo.frostlink.dev/badges/talos_version)](https://talos.dev)&nbsp;&nbsp;
[![Kubernetes](https://kromgo.frostlink.dev/badges/kubernetes_version)](https://kubernetes.io)&nbsp;&nbsp;
[![Flux](https://kromgo.frostlink.dev/badges/flux_version)](https://fluxcd.io)

[![Status Page](https://kromgo.frostlink.dev/badges/core_status_page)](https://status.dcunha.io)

[![Age](https://kromgo.frostlink.dev/badges/cluster_birth_age)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Pods](https://kromgo.frostlink.dev/badges/cluster_pod_count)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![CPU](https://kromgo.frostlink.dev/badges/cluster_cpu_usage)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Memory](https://kromgo.frostlink.dev/badges/cluster_memory_usage)](https://github.com/home-operations/kromgo)

</div>

## Cluster

|                |                                                                                          |
| -------------- | ---------------------------------------------------------------------------------------- |
| **Node**       | VM.Standard.A1.Flex — 4 OCPU / 24 GB RAM (ARM64)                                         |
| **OS**         | Talos Linux — version: `kubernetes/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml` |
| **Kubernetes** | version: `kubernetes/apps/system-upgrade/tuppr/upgrades/kubernetesupgrade.yaml`          |
| **CNI**        | Cilium — version: `kubernetes/apps/kube-system/cilium/app/ocirepository.yaml`            |
| **GitOps**     | Flux CD v2.8.8 via flux-operator                                                         |
| **Secrets**    | 1Password ExternalSecret (no SOPS)                                                       |
| **Ingress**    | Cloudflare tunnel (apps) + towonel edge on 80+443/tcp, 51820/udp (tunnelled origins)     |

## Structure

- `talos/` — Talos schematic and machine config patches
- `bootstrap/` — One-time helmfile bootstrap (secrets + Flux install)
- `kubernetes/flux/` — Flux sync entrypoint
- `kubernetes/apps/` — Workloads reconciled by Flux
- `kubernetes/components/` — Reusable Flux Components (kopiur backups, postgres certs, anubis, alerts)

## Tunnel

Frostlink runs the [towonel](https://codeberg.org/towonel/towonel) hub and edge, so
machines behind NAT/CGNAT can publish through this VPS without opening ports of their
own. Agents dial out over iroh QUIC; the edge routes by SNI and passes TLS straight
through, so origins keep their own certificates.
