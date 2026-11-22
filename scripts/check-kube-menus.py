#!/usr/bin/env python3
"""Check the namespace menus under kube/ (issue #3333).

- Every kube/clusters/<c>/apps/<ns>/<app>/ks.yaml is listed by its menu.
- Every menu entry points at a file or folder that exists.
- No menu lists anything under kube/base: Flux Kustomizations live only in the cluster tree.
- kube/base holds no ks.yaml.
- Every kube/base/<ns>/<app> is used by at least one cluster app (a ks.yaml path or an app kustomization).
- No commented-out entries in a menu (delete the line instead).
"""
import re
import sys
from pathlib import Path

from ruamel.yaml import YAML  # type: ignore[import-untyped]

ROOT = Path(__file__).resolve().parent.parent
KUBE = ROOT / "kube"


def menus():
    for menu in sorted(KUBE.glob("clusters/*/apps/*/kustomization.yaml")):
        yield menu.parent.parent.parent.name, menu


def main() -> int:
    errors = []

    for _cluster, menu in menus():
        text = menu.read_text()
        rel = menu.relative_to(ROOT)
        for n, line in enumerate(text.splitlines(), 1):
            if re.match(r"\s*#\s*-\s", line):
                errors.append(f"{rel}:{n}: commented-out entry, delete it instead: {line.strip()}")
        doc = YAML(typ="safe").load(text) or {}
        entries = [str(e) for e in doc.get("resources", []) or []]
        for e in entries:
            target = (menu.parent / e).resolve()
            if not target.exists():
                errors.append(f"{rel}: entry does not exist: {e}")
                continue
            if target.is_relative_to(KUBE / "base"):
                errors.append(f"{rel}: lists {e}; give the app a ./<app>/ks.yaml in this cluster instead")
        for ks in sorted(menu.parent.glob("*/ks.yaml")):
            entry = "./" + str(ks.relative_to(menu.parent))
            if entry not in entries:
                errors.append(f"{rel}: {entry} exists but is not listed")

    for ks in sorted(KUBE.glob("base/**/ks.yaml")):
        errors.append(f"{ks.relative_to(ROOT)}: kube/base holds no Flux Kustomizations; move it to each cluster's apps/<ns>/<app>/")

    users = "\n".join(p.read_text() for p in KUBE.glob("clusters/*/apps/**/*.yaml"))
    for app in sorted(p for p in KUBE.glob("base/*/*") if p.is_dir()):
        key = f"base/{app.parent.name}/{app.name}/"
        if key not in users:
            errors.append(f"{app.relative_to(ROOT)}: no cluster app uses it")

    for e in errors:
        print(e)
    if errors:
        print(f"{len(errors)} menu problem(s)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
