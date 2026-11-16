# Module: Directory Structure Template

Every app uses this canonical layout:

```
kube/clusters/artemis/apps/<namespace>/<app>/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml
    └── helmrelease.yaml      ← secrets go inline under values.externalSecrets
```

After creating the directory, add `- ./<app>/ks.yaml` to `kube/clusters/artemis/apps/<namespace>/kustomization.yaml` resources.

## Verify structure

```bash
find kube/clusters/artemis/apps/<namespace>/<app> -type f | sort
```

Expected output (no ExternalSecret):

```
kube/clusters/artemis/apps/<namespace>/<app>/app/helmrelease.yaml
kube/clusters/artemis/apps/<namespace>/<app>/app/kustomization.yaml
kube/clusters/artemis/apps/<namespace>/<app>/app/ocirepository.yaml
kube/clusters/artemis/apps/<namespace>/<app>/ks.yaml
```
