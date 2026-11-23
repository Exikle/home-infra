#!/usr/bin/env python3
"""Check the namespace menus and app folders under kube/ (issue #3333).

kube/clusters/<c>/apps/<ns>/<app>/ holds every app that a cluster runs with its own folder:
- a folder WITH a ks.yaml is an app that only this cluster runs;
- a folder WITHOUT a ks.yaml holds this cluster's side of a shared app, whose ks.yaml lives in
  kube/base/<ns>/<app>/.
A shared app with no differences has no cluster folder: its ks.yaml points at ./kube/base/... and
reads the whole flux-system OCIRepository.

- Every kube/clusters/<c>/apps/<ns>/ has a kustomization.yaml (else the root would walk into it),
  and it lists every <app>/ks.yaml in that folder.
- Every kube/base/<ns>/<app>/ has a ks.yaml, listed by kube/base/<ns>/kustomization.yaml.
- Every kube/base/<ns>/ menu is listed by kube/base/kustomization.yaml.
- Every menu entry points at a file or folder that exists.
- A cluster menu never lists kube/base. Only the Flux Kustomization `base` in
  kube/clusters/<c>/apps/flux-system/base/ks.yaml applies it, with path ./kube/base.
- Every shared ks.yaml path exists for every cluster, with ${CLUSTER} filled in.
- A cluster folder named like a shared app has no ks.yaml, and a cluster folder without a ks.yaml
  belongs to a shared app whose ks.yaml points into the cluster's apps/.
- No kube/clusters/<c>/overlays/ (merged into apps/ on 2026-11-23).
- Every namespace lives in kube/base/<ns>/namespace.yaml, listed by its base menu. No cluster
  folder holds a namespace.yaml, and every cluster namespace folder has a base namespace.
- No commented-out entries in a menu (delete the line instead).
"""
import re
import sys
from pathlib import Path

from ruamel.yaml import YAML  # type: ignore[import-untyped]

ROOT = Path(__file__).resolve().parent.parent
KUBE = ROOT / "kube"
BASE = KUBE / "base"


def entries(menu: Path, errors: list) -> list:
    text = menu.read_text()
    rel = menu.relative_to(ROOT)
    for n, line in enumerate(text.splitlines(), 1):
        if re.match(r"\s*#\s*-\s", line):
            errors.append(f"{rel}:{n}: commented-out entry, delete it instead: {line.strip()}")
    doc = YAML(typ="safe").load(text) or {}
    found = [str(e) for e in doc.get("resources", []) or []]
    for e in found:
        if not (menu.parent / e).resolve().exists():
            errors.append(f"{rel}: entry does not exist: {e}")
    return found


def require_listed(menu: Path, children, errors: list) -> None:
    listed = entries(menu, errors) if menu.exists() else []
    for child in children:
        entry = "./" + str(child.relative_to(menu.parent))
        if entry not in listed:
            errors.append(f"{menu.relative_to(ROOT)}: {entry} exists but is not listed")


def shared_paths() -> dict:
    """Map each shared app (ns/app) to the spec.path values of its ks.yaml."""
    out = {}
    for ks in sorted(BASE.glob("*/*/ks.yaml")):
        out[ks.parent.relative_to(BASE)] = re.findall(r"^  path: (\S+)$", ks.read_text(), re.M)
    return out


def main() -> int:
    errors: list = []
    shared = {p.relative_to(BASE) for p in BASE.glob("*/*") if p.is_dir()}
    paths = shared_paths()

    for app in sorted(shared):
        if not (BASE / app / "ks.yaml").is_file():
            errors.append(f"kube/base/{app}: a shared app needs its ks.yaml here")
    for ns in sorted({a.parts[0] for a in shared}):
        require_listed(BASE / ns / "kustomization.yaml", sorted((BASE / ns).glob("*/ks.yaml")), errors)
    require_listed(BASE / "kustomization.yaml", sorted(p.parent for p in BASE.glob("*/kustomization.yaml")), errors)
    for ns_file in sorted(BASE.glob("*/namespace.yaml")):
        require_listed(ns_file.parent / "kustomization.yaml", [ns_file], errors)
    for stray in sorted((KUBE / "clusters").glob("*/apps/**/namespace.yaml")):
        errors.append(f"{stray.relative_to(ROOT)}: namespaces live in kube/base/<ns>/namespace.yaml")

    for cluster in sorted(p for p in (KUBE / "clusters").iterdir() if (p / "apps").is_dir()):
        apps = cluster / "apps"
        if (cluster / "overlays").exists():
            errors.append(f"{(cluster / 'overlays').relative_to(ROOT)}: merged into apps/; move it there")
        link = apps / "flux-system" / "base" / "ks.yaml"
        if not link.is_file() or "  path: ./kube/base\n" not in link.read_text():
            errors.append(f"{link.relative_to(ROOT)}: the base Kustomization must exist with path ./kube/base")

        for ns_dir in sorted(p for p in apps.iterdir() if p.is_dir()):
            menu = ns_dir / "kustomization.yaml"
            if not menu.is_file():
                errors.append(f"{ns_dir.relative_to(ROOT)}: no kustomization.yaml; the root would apply its files directly")
                continue
            if not (BASE / ns_dir.name / "namespace.yaml").is_file():
                errors.append(f"{ns_dir.relative_to(ROOT)}: no kube/base/{ns_dir.name}/namespace.yaml")
            for e in entries(menu, errors):
                if (menu.parent / e).resolve().is_relative_to(BASE):
                    errors.append(f"{menu.relative_to(ROOT)}: lists {e}; shared apps reach the cluster through the base Kustomization")
            require_listed(menu, sorted(ns_dir.glob("*/ks.yaml")), errors)

        for app_dir in sorted(p for p in apps.glob("*/*") if p.is_dir()):
            rel = app_dir.relative_to(apps)
            has_ks = (app_dir / "ks.yaml").is_file()
            if rel in shared and has_ks:
                errors.append(f"{app_dir.relative_to(ROOT)}: kube/base/{rel} is shared; its ks.yaml lives in base only")
            if not has_ks and rel != Path("flux-system/base"):
                if rel not in shared:
                    errors.append(f"{app_dir.relative_to(ROOT)}: no ks.yaml and no kube/base/{rel}")
                elif not any("/apps/" in p for p in paths.get(rel, [])):
                    errors.append(f"{app_dir.relative_to(ROOT)}: kube/base/{rel}/ks.yaml points at ./kube/base, so this folder is never read")

        for app, app_paths in paths.items():
            for path in app_paths:
                real = ROOT / path.replace("${CLUSTER}", cluster.name)
                if not real.is_dir():
                    errors.append(f"kube/base/{app}/ks.yaml: path {path} does not exist for {cluster.name}")

    for e in errors:
        print(e)
    if errors:
        print(f"{len(errors)} menu problem(s)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
