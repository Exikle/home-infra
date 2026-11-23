#!/usr/bin/env python3
"""Check the namespace menus under kube/ (issue #3333).

Shared apps live once in kube/base/<ns>/<app>/ with their ks.yaml. A cluster's differences for a
shared app live in kube/clusters/<c>/overlays/<ns>/<app>/. Apps that one cluster runs live in
kube/clusters/<c>/apps/<ns>/<app>/.

- Every kube/clusters/<c>/apps/<ns>/<app>/ks.yaml is listed by its menu.
- Every kube/base/<ns>/<app>/ has a ks.yaml, listed by kube/base/<ns>/kustomization.yaml.
- Every kube/base/<ns>/ menu is listed by kube/base/kustomization.yaml.
- Every menu entry points at a file or folder that exists.
- A cluster menu never lists kube/base. Only the Flux Kustomization `base` in
  kube/clusters/<c>/apps/base/ks.yaml applies it (path ./kube/base), and that menu lists only ./ks.yaml.
- Every shared ks.yaml path points at a folder that exists for every cluster, with ${CLUSTER} filled in.
- A shared app has no kube/clusters/<c>/apps/<ns>/<app>/: both would publish the same artifact.
- Every kube/clusters/<c>/overlays/<ns>/<app>/ belongs to a shared app.
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
LINK = ["./ks.yaml"]


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


def main() -> int:
    errors: list = []
    shared = {p.relative_to(BASE) for p in BASE.glob("*/*") if p.is_dir()}

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
    for ns_dir in sorted((KUBE / "clusters").glob("*/apps/*/")):
        if ns_dir.name != "base" and not (BASE / ns_dir.name / "namespace.yaml").is_file():
            errors.append(f"{ns_dir.relative_to(ROOT)}: no kube/base/{ns_dir.name}/namespace.yaml")

    for cluster in sorted(p for p in (KUBE / "clusters").iterdir() if (p / "apps").is_dir()):
        link = cluster / "apps" / "base" / "kustomization.yaml"
        if not link.is_file():
            errors.append(f"{link.relative_to(ROOT)}: missing; it links the cluster to kube/base")
        elif entries(link, errors) != LINK:
            errors.append(f"{link.relative_to(ROOT)}: resources must be exactly {LINK}")
        link_ks = link.parent / "ks.yaml"
        if link_ks.is_file() and "  path: ./kube/base\n" not in link_ks.read_text():
            errors.append(f"{link_ks.relative_to(ROOT)}: the base Kustomization must have path ./kube/base")
        for ks in sorted(BASE.glob("*/*/ks.yaml")):
            for path in re.findall(r"^  path: (\S+)$", ks.read_text(), re.M):
                real = ROOT / path.replace("${CLUSTER}", cluster.name)
                if not real.is_dir():
                    errors.append(f"{ks.relative_to(ROOT)}: path {path} does not exist for {cluster.name}")

        for menu in sorted((cluster / "apps").glob("*/kustomization.yaml")):
            if menu == link:
                continue
            for e in entries(menu, errors):
                if (menu.parent / e).resolve().is_relative_to(BASE):
                    errors.append(f"{menu.relative_to(ROOT)}: lists {e}; shared apps reach the cluster through apps/base/")
            require_listed(menu, sorted(menu.parent.glob("*/ks.yaml")), errors)

        for app in sorted(shared):
            if (cluster / "apps" / app).exists():
                errors.append(f"{(cluster / 'apps' / app).relative_to(ROOT)}: kube/base/{app} is shared; put this cluster's differences in overlays/{app}/")
        for overlay in sorted(p for p in (cluster / "overlays").glob("*/*") if p.is_dir()):
            if overlay.relative_to(cluster / "overlays") not in shared:
                errors.append(f"{overlay.relative_to(ROOT)}: no kube/base app of that name; a cluster-only app goes in apps/")

    for e in errors:
        print(e)
    if errors:
        print(f"{len(errors)} menu problem(s)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
