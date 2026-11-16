# Module: Image Pinning

Never use a bare tag; pin `tag: <version>@sha256:<digest>`.

```bash
crane ls <registry>/<image>
crane digest <registry>/<image>:<tag>
```

```yaml
image:
    repository: ghcr.io/home-operations/sonarr
    tag: 4.0.14@sha256:c751c3a0ed38a8a18b647ae7897b57c793f52a6501a75be2fe4b72d1c27b60ea
```

- Cross-check the tag against the project's releases page; registries hold orphaned pre-release tags.
- Prefer `ghcr.io/home-operations/<app>` images where they exist (correct UIDs).
- If the image does not run as UID 1000, align `runAsUser`/`runAsGroup` in `defaultPodOptions`.
