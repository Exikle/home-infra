#!/usr/bin/env bash
# VENDORED FILE — canonical copy: dotfiles/home/claude/agent-hooks/validate-manifest.sh
# Edit there and run sync-hooks.sh; pre-commit fails if this drifts.
#
# PostToolUse:Edit|Write|MultiEdit — format check on YAML under kube/ after edits.
# Exit 2 is how the model sees the warning: PostToolUse feeds stderr back to Claude on
# exit 2 and cannot revert the edit. Any other non-zero exit is shown to the user only.
set -euo pipefail

INPUT=$(cat)

# Fast path: only YAML under kube/ is ever checked, so skip the interpreter
# entirely unless the payload could name such a file.
[[ "$INPUT" == */kube/* ]] || exit 0
[[ "$INPUT" == *.yaml* || "$INPUT" == *.yml* ]] || exit 0

FILE=$(printf '%s' "$INPUT" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" \
    2>/dev/null || echo "")

[[ "$FILE" =~ \.ya?ml$ ]] || exit 0
[[ "$FILE" =~ /kube/ ]] || exit 0

# Resolve a tool without installing one. `mise exec` would INSTALL a missing tool
# mid-hook — it has been observed pulling down a whole toolchain from a lint hook —
# so fall back to `mise which`, which only reports.
resolve() {
    command -v "$1" 2>/dev/null || mise which "$1" 2>/dev/null || true
}

ERRORS=()

# `--check`, not `check`: oxfmt takes paths positionally, so the bare word was parsed
# as a filename and the check silently never ran.
OXFMT=$(resolve oxfmt)
if [[ -n "$OXFMT" ]]; then
    if ! OXFMT_OUT=$("$OXFMT" --check "$FILE" 2>&1); then
        ERRORS+=("oxfmt: $OXFMT_OUT")
    fi
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "Validation warnings for $FILE:" >&2
    for err in "${ERRORS[@]}"; do
        echo "  $err" >&2
    done
    exit 2
fi

exit 0
