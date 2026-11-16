# Bootstrap — Order of Operations

How to bring up a fresh cluster. This text moved out of `AGENTS.md` on 2026-09-02, because you
need it only when you bootstrap, not on every session.

---

## Order

`mise run //clusters/artemis/bootstrap:cluster` does the whole thing. It chains
`nodes → k8s → kubeconfig → base → apps → kubeconfig`, and `base` waits on `api-ready` and
`nodes-ready` first. `base` applies `clusters/artemis/bootstrap/helmfile.d/00-crds.yaml`. Every release there is
rendered and filtered down to `kind: CustomResourceDefinition`, and none is installed. See
`observability.md` § Where the `monitoring.coreos.com` CRDs come from for the reason that this
matters. `apps` syncs `clusters/artemis/bootstrap/helmfile.d/01-apps.yaml`, in order: Cilium → CoreDNS → Spegel →
cert-manager → external-secrets → onepassword-connect → flux-operator → flux-instance.

You no longer need to apply node configs by hand first. That step was here because the `nodes`
stage was broken. It took its list from `talosctl config info`, whose `.nodes` is one hand-set
IP, and fed IPs to `mise run //clusters/artemis/talos:apply-node`, which is keyed on hostname. The list now comes from
`clusters/artemis/talos/nodes/*.yaml.j2`, control planes first (fixed 2026-09-10).

The task is `mise run //clusters/artemis/bootstrap:cluster`. A confirm prompt gates the task.

There are two lists, and they are not interchangeable. The fleet is `clusters/artemis/talos/nodes/*.yaml.j2`
(7 nodes, hostnames, `mise run //clusters/artemis/bootstrap:node-list`). The control planes are `talosctl config info`
`.endpoints` (3 IPs). `api-ready` polls `:6443/readyz` and must use the second list. Upstream
onedr0p runs control planes only, so it iterates over every node there, and a straight copy of
that loop waits forever on a worker.

`clusters/artemis/mise.toml` pins `KUBECONFIG` to the file of the cluster and every `kubectl` and `helmfile` call
to `--context artemis` (override with `KUBE_CONTEXT`), including the hooks inside
`helmfile.d/01-apps.yaml`. Without that, `mise run //clusters/artemis/bootstrap:base` with `frostlink` selected applies
Artemis namespaces, CRDs and 1Password secrets into frostlink with no prompt.

Node configs are Jinja2 templates (`clusters/artemis/talos/cluster.yaml.j2`, `clusters/artemis/talos/controlplane.yaml.j2`,
`clusters/artemis/talos/worker.yaml.j2`, `clusters/artemis/talos/nodes/<node>.yaml.j2`). `talosctl apply-config --file` cannot
read a `.j2`. Always go through `mise run //clusters/artemis/talos:render-config`. See `.agents/references/talos.md`.
