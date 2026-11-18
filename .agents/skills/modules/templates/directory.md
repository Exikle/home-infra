# Module: Directory Structure Template

Every app uses this layout. `<cluster>` is `artemis` or `frostlink`:

```
kube/clusters/<cluster>/apps/<namespace>/<app>/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml
    └── helmrelease.yaml      ← secrets go inline under values.externalSecrets
```

Frostlink uses the same layout. Its differences are in `.agents/instructions/frostlink.md` § Apps,
and that file wins there.

## Verify structure

```bash
find kube/clusters/<cluster>/apps/<namespace>/<app> -type f | sort
```

Expected output:

```
kube/clusters/<cluster>/apps/<namespace>/<app>/app/helmrelease.yaml
kube/clusters/<cluster>/apps/<namespace>/<app>/app/kustomization.yaml
kube/clusters/<cluster>/apps/<namespace>/<app>/app/ocirepository.yaml
kube/clusters/<cluster>/apps/<namespace>/<app>/ks.yaml
```
