# Module: Directory Structure Template

Every app uses this canonical layout. `<cluster>` is `artemis` or `frostlink`:

```
kube/clusters/<cluster>/apps/<namespace>/<app>/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml
    └── helmrelease.yaml      ← secrets go inline under values.externalSecrets
```

Frostlink uses the same layout. Its differences are in `.agents/instructions/frostlink.md` § Apps,
which wins there.

After you create the directory, add `- ./<app>/ks.yaml` to the resources in
`kube/clusters/<cluster>/apps/<namespace>/kustomization.yaml`.

## Verify structure

```bash
find kube/clusters/<cluster>/apps/<namespace>/<app> -type f | sort
```

Expected output (no ExternalSecret):

```
kube/clusters/<cluster>/apps/<namespace>/<app>/app/helmrelease.yaml
kube/clusters/<cluster>/apps/<namespace>/<app>/app/kustomization.yaml
kube/clusters/<cluster>/apps/<namespace>/<app>/app/ocirepository.yaml
kube/clusters/<cluster>/apps/<namespace>/<app>/ks.yaml
```
