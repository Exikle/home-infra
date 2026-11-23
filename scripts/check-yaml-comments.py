#!/usr/bin/env python3
"""Fail on any YAML comment in the given files or folders (default: both clusters' apps and components, kube/base, kube/components) except schema modelines, Renovate directives and anchor markers.

`#` inside block scalars and quoted strings is data, not a comment.
"""
import re
import sys
from pathlib import Path

ALLOWED = re.compile(r"#\s*(yaml-language-server:|renovate:|[&*][A-Za-z0-9_-]+\b)")
BLOCK = re.compile(r"^(\s*(?:-\s+)*)([^#]*?:\s+|)[|>][+-]?\d*\s*(#.*)?$")


def comments(text):
    block_indent = None
    for n, line in enumerate(text.splitlines(), 1):
        if block_indent is not None:
            if not line.strip() or len(line) - len(line.lstrip()) > block_indent:
                continue
            block_indent = None
        quote = None
        for i, ch in enumerate(line):
            if quote:
                if ch == quote:
                    quote = None
            elif ch in "'\"" and (i == 0 or line[i - 1] in " \t[{,:-"):
                quote = ch
            elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
                if not ALLOWED.match(line[i:]):
                    yield n, i, line.strip()
                line = line[:i]
                break
        m = BLOCK.match(line)
        if m:
            bare_item = "-" in m.group(1) and not m.group(2)
            block_indent = len(m.group(1).rstrip()) - 1 if bare_item else len(m.group(1).replace("-", " "))


def main():
    roots = [Path(a) for a in sys.argv[1:]] or [Path("kube/base"), Path("kube/components"), *Path("kube/clusters").glob("*/apps"), *Path("kube/clusters").glob("*/components"), *Path("kube/clusters").glob("*/overlays")]
    found = {p for root in roots for p in ([root] if root.is_file() else root.rglob("*.yaml")) if p.suffix == ".yaml" and "resources" not in p.parts}
    bad = 0
    for path in sorted(found):
        for n, _, text in comments(path.read_text()):
            print(f"{path}:{n}: {text}")
            bad += 1
    if bad:
        print(f"{bad} YAML comment(s): move rationale to .agents/references/ (.agents/instructions/yaml-conventions.md § No Comments in Manifests)")
        sys.exit(1)


if __name__ == "__main__":
    main()
