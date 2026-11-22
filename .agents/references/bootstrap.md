# Bootstrap — Artemis

This file tells you how to bring up a fresh Artemis cluster. The bootstrap task below is for
Artemis only. To rebuild Frostlink, read `oci-rebuild.md`.

---

## Order

`mise run //kube/clusters/artemis/bootstrap:cluster` does the full bootstrap. It asks for
confirmation before it starts, so a script must pass `--yes`. It chains
`nodes → k8s → kubeconfig → base → apps → kubeconfig`. Before `base` starts, it waits on
`api-ready` and `nodes-ready`.

`base` applies `kube/clusters/artemis/bootstrap/helmfile.d/00-crds.yaml`. It renders every release
in that file and keeps only the `kind: CustomResourceDefinition` objects. It installs no release.
`observability.md` § Where the `monitoring.coreos.com` CRDs come from gives the reason that this
is important.

`apps` syncs `kube/clusters/artemis/bootstrap/helmfile.d/01-apps.yaml`, in this order: Cilium →
CoreDNS → Spegel → cert-manager → external-secrets → onepassword-connect → flux-operator →
flux-instance.

Each release reads its chart, version and values from the app that Flux runs. The helmfile
templates look in `kube/clusters/<cluster>/apps/<ns>/<app>/app/` first, then in
`kube/base/<ns>/<app>/app/`. For a shared app they also merge
`kube/clusters/<cluster>/apps/<ns>/<app>/app/values.yaml`, if it exists. The base values win, in
the same order as Flux. So a rebuild installs the versions and values that Flux runs. The `cni`
task of Frostlink does the same for Cilium, CoreDNS and cert-manager.

The `nodes` stage takes its node list from `kube/clusters/artemis/talos/nodes/*.yaml.j2`, control
planes first. You do not apply the node configurations by hand before you run the task.

There are two node lists, and you cannot use one in place of the other:

- The fleet is `kube/clusters/artemis/talos/nodes/*.yaml.j2`, by hostname. Run
  `mise run //kube/clusters/artemis/bootstrap:node-list` to print it.
- The control planes are `.endpoints` in `talosctl config info`, by IP.

`api-ready` polls `:6443/readyz` and must use the second list. Upstream onedr0p runs control
planes only, so its loop goes over every node. A direct copy of that loop waits forever on a
worker.

`kube/clusters/artemis/mise.toml` sets `KUBECONFIG` to the file of the cluster. It also pins every
`kubectl` and `helmfile` call to `--context artemis`, including the hooks inside
`helmfile.d/01-apps.yaml`. To override the context, set `KUBE_CONTEXT`. Without that pin,
`mise run //kube/clusters/artemis/bootstrap:base` with `frostlink` selected applies the Artemis
namespaces, CRDs and 1Password secrets into frostlink, with no prompt.

The node configurations are Jinja2 templates: `kube/clusters/artemis/talos/cluster.yaml.j2`,
`kube/clusters/artemis/talos/controlplane.yaml.j2`, `kube/clusters/artemis/talos/worker.yaml.j2`
and `kube/clusters/artemis/talos/nodes/<node>.yaml.j2`. `talosctl apply-config --file` cannot
read a `.j2`. Always use `mise run //kube/clusters/artemis/talos:render-config`. See
`.agents/references/talos.md`.
