#!/usr/bin/env python3
"""Fail on any YAML comment under clusters/frostlink/kubernetes/ except schema modelines and Renovate directives.

`#` inside block scalars and quoted strings is data, not a comment.
"""
import re
import sys
from pathlib import Path

ALLOWED = re.compile(r"#\s*(yaml-language-server:|renovate:)")
BLOCK = re.compile(r"^(\s*(?:-\s+)*)(?:[^#]*?:\s+|)[|>][+-]?\d*\s*(#.*)?$")


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
            block_indent = len(m.group(1).replace("-", " "))


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "clusters/frostlink/kubernetes")
    bad = 0
    for path in sorted(p for p in root.rglob("*.yaml") if "resources" not in p.parts):
        for n, _, text in comments(path.read_text()):
            print(f"{path}:{n}: {text}")
            bad += 1
    if bad:
        print(f"{bad} YAML comment(s): move rationale to .agents/references/ (frostlink-yaml-conventions.md)")
        sys.exit(1)


if __name__ == "__main__":
    main()
