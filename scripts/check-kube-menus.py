#!/usr/bin/env python3
"""Check the namespace menus under kube/ (issue #3333).

- Every kube/base/<ns>/<app> is listed by at least one cluster menu.
- Every kube/clusters/<c>/apps/<ns>/<app>/ks.yaml and .../extras/ks.yaml is listed by its menu.
- Every menu entry points at a file or folder that exists.
- A cluster that lists a base app whose ks.yaml waits for <app>-extras also lists ./<app>/extras/ks.yaml.
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
    listed_base = set()

    for cluster, menu in menus():
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
                listed_base.add(target)
                ks = target / "ks.yaml"
                if ks.exists():
                    app = target.name
                    if f"name: {app}-extras" in ks.read_text() and f"./{app}/extras/ks.yaml" not in entries:
                        errors.append(f"{rel}: lists base {app} but not ./{app}/extras/ks.yaml (its base ks.yaml waits for {app}-extras)")
        # every app ks.yaml under this namespace is listed
        for ks in sorted(menu.parent.glob("*/ks.yaml")) + sorted(menu.parent.glob("*/extras/ks.yaml")):
            entry = "./" + str(ks.relative_to(menu.parent))
            if entry not in entries:
                errors.append(f"{rel}: {entry} exists but is not listed")

    for app in sorted(p for p in KUBE.glob("base/*/*") if p.is_dir()):
        if app.resolve() not in listed_base:
            errors.append(f"{app.relative_to(ROOT)}: no cluster menu lists it")

    for e in errors:
        print(e)
    if errors:
        print(f"{len(errors)} menu problem(s)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
