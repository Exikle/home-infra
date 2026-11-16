# Bootstrap — Order of Operations

How to bring up a fresh cluster. This text moved out of `AGENTS.md` on 2026-09-02, because you
need it only when you bootstrap, not on every session.

---

## Order

`mise run //kube/clusters/artemis/bootstrap:cluster` does the whole thing. It chains
`nodes → k8s → kubeconfig → base → apps → kubeconfig`, and `base` waits on `api-ready` and
`nodes-ready` first. `base` applies `kube/clusters/artemis/bootstrap/helmfile.d/00-crds.yaml`. Every release there is
rendered and filtered down to `kind: CustomResourceDefinition`, and none is installed. See
`observability.md` § Where the `monitoring.coreos.com` CRDs come from for the reason that this
matters. `apps` syncs `kube/clusters/artemis/bootstrap/helmfile.d/01-apps.yaml`, in order: Cilium → CoreDNS → Spegel →
cert-manager → external-secrets → onepassword-connect → flux-operator → flux-instance.

Each release reads its chart, version and values from the app that Flux runs. The helmfile
templates look in `kube/clusters/<cluster>/apps/<ns>/<app>/app/` first, then in
`kube/base/<ns>/<app>/app/`. For a shared app they also merge
`kube/clusters/<cluster>/apps/<ns>/<app>/extras/values.yaml`, with the base values winning, the
same order as Flux. So a rebuild installs the versions and values that Flux runs. Frostlink's
`cni` task does the same for Cilium, CoreDNS and cert-manager.

You no longer need to apply node configs by hand first. That step was here because the `nodes`
stage was broken. It took its list from `talosctl config info`, whose `.nodes` is one hand-set
IP, and fed IPs to `mise run //kube/clusters/artemis/talos:apply-node`, which is keyed on hostname. The list now comes from
`kube/clusters/artemis/talos/nodes/*.yaml.j2`, control planes first (fixed 2026-09-10).

The task is `mise run //kube/clusters/artemis/bootstrap:cluster`. A confirm prompt gates the task.

There are two lists, and they are not interchangeable. The fleet is `kube/clusters/artemis/talos/nodes/*.yaml.j2`
(7 nodes, hostnames, `mise run //kube/clusters/artemis/bootstrap:node-list`). The control planes are `talosctl config info`
`.endpoints` (3 IPs). `api-ready` polls `:6443/readyz` and must use the second list. Upstream
onedr0p runs control planes only, so it iterates over every node there, and a straight copy of
that loop waits forever on a worker.

`kube/clusters/artemis/mise.toml` pins `KUBECONFIG` to the file of the cluster and every `kubectl` and `helmfile` call
to `--context artemis` (override with `KUBE_CONTEXT`), including the hooks inside
`helmfile.d/01-apps.yaml`. Without that, `mise run //kube/clusters/artemis/bootstrap:base` with `frostlink` selected applies
Artemis namespaces, CRDs and 1Password secrets into frostlink with no prompt.

Node configs are Jinja2 templates (`kube/clusters/artemis/talos/cluster.yaml.j2`, `kube/clusters/artemis/talos/controlplane.yaml.j2`,
`kube/clusters/artemis/talos/worker.yaml.j2`, `kube/clusters/artemis/talos/nodes/<node>.yaml.j2`). `talosctl apply-config --file` cannot
read a `.j2`. Always go through `mise run //kube/clusters/artemis/talos:render-config`. See `.agents/references/talos.md`.
