#!/usr/bin/env bash
# GENERATED FILE — do not edit here.
# Source:     .claude/hooks/guard-rules.json  (canonical: dotfiles/home/claude/agent-hooks/)
# Regenerate: python3 .claude/hooks/gen-guards.py
# Verified:   python3 .claude/hooks/gen-guards.py --check   (runs in pre-commit)
#
# PreToolUse:Bash — blocks destructive cluster operations that bypass GitOps or
# the sanctioned mise tasks, and asks the owner before a subagent runs a write task
# or a git write. The judging is the python engine below; this wrapper is the fast
# path and the fail-closed handling.

set -uo pipefail

INPUT=$(cat)

# Fast path: skip the python engine when no rule can possibly fire. The command is
# always a part of this raw payload, so a keyword absent here cannot appear in it.
[[ "$INPUT" =~ (kubectl|kubecolor|helm|flux|talosctl|mise|tofu|terraform|(^|[^[:alnum:]_])rm[^[:alnum:]_]|(^|[^[:alnum:]_])mv[^[:alnum:]_]|(^|[^[:alnum:]_])git[^[:alnum:]_]) ]] || exit 0

# agent_id is present in the PreToolUse payload ONLY when the hook fires inside a
# subagent; the engine reads it. agent_type is NOT a substitute: it is also set on a
# main thread launched with --agent. The field ships in the binary's hook schema but
# is not in the public docs, so if a subagent rule ever stops firing, check that this
# field still exists before anything else.
# read -d '' rather than $(cat <<EOF): bash 3.2 mis-parses a heredoc inside $( ).
read -r -d '' GUARD_PY <<'GUARD_PY_EOF' || true
import json, re, sys

RULES = json.loads(r"""[
 {
  "id": "kubectl-mutation",
  "pattern": "^(?:kubectl|kubecolor)(?:\\s+-[\\w-]+(?:=\\S*)?(?:\\s+[^-\\s]\\S*)?)*\\s+(?:apply|patch|replace|create|edit|scale|drain|set|label|annotate)\\b",
  "reason": "Direct kubectl writes bypass GitOps",
  "alternative": "Apply through the apply-ks task of the cluster: 'mise run //kube/clusters/<cluster>:apply-ks <ns> <ks>'. cordon, uncordon and rollout are not blocked."
 },
 {
  "id": "kubectl-delete-critical",
  "pattern": "^(?:kubectl|kubecolor)(?:\\s+-[\\w-]+(?:=\\S*)?(?:\\s+[^-\\s]\\S*)?)*\\s+delete\\b(?=.*(?:\\s-[fkR]\\b|\\s--(?:all|filename|kustomize|recursive)(?=[\\s=]|$)|\\s(?:ns|namespaces?|pvcs?|pvs?|persistentvolumes?|persistentvolumeclaims?|nodes?|no|deploy|deployments?|ds|daemonsets?|sts|statefulsets?|secrets?|crds?|customresourcedefinitions?|clusters?|helmreleases?|hr|kustomizations?|ks|ocirepositor(?:y|ies)|gitrepositor(?:y|ies)|gateways?|httproutes?|clusterroles?|all)(?=[\\s,/]|$)))",
  "exempt_env": "I_HAVE_A_KOPIUR_SNAPSHOT",
  "reason": "Deleting a critical Kubernetes resource",
  "alternative": "Confirm with the user before deleting cluster resources. If this is a planned PVC recreation with a verified snapshot, prefix the command with I_HAVE_A_KOPIUR_SNAPSHOT=1 (see .agents/skills/recreate-pvc); on Frostlink use 'mise run //kube/clusters/frostlink:restore-pvc' instead"
 },
 {
  "id": "helm-mutation",
  "pattern": "^helm(?:\\s+-[\\w-]+(?:=\\S*)?(?:\\s+[^-\\s]\\S*)?)*\\s+(?:install|upgrade|uninstall|delete|rollback)\\b",
  "reason": "Direct helm mutations are not allowed \u2014 config lives in HelmRelease manifests",
  "alternative": "Edit the HelmRelease values and apply via Flux"
 },
 {
  "id": "helmfile-mutation",
  "pattern": "^helmfile\\b.*\\s(?:sync|apply|destroy|delete)(?=\\s|$)",
  "reason": "helmfile sync/apply/destroy/delete changes a live cluster outside GitOps",
  "alternative": "Use the bootstrap tasks ('mise run //kube/clusters/frostlink/bootstrap:phase1' and the rebuild order in oci-rebuild.md), with the user watching"
 },
 {
  "id": "flux-destructive",
  "pattern": "^flux(?:\\s+-[\\w-]+(?:=\\S*)?(?:\\s+[^-\\s]\\S*)?)*\\s+(?:delete|uninstall)\\b",
  "reason": "Destructive flux operation",
  "alternative": "Confirm with the user before deleting Flux resources"
 },
 {
  "id": "tofu-mutation",
  "pattern": "^(?:tofu|terraform)(?:\\s+-\\S+)*\\s+(?:apply|destroy|import|state)\\b",
  "reason": "A bare tofu/terraform write skips the repo's task wrapper, which sets the workspace, credentials and the import-first check",
  "alternative": "Use the mise tasks: 'mise run //terraform:plan', and with the user's go-ahead 'mise run --yes //terraform:apply'"
 },
 {
  "id": "talosctl-patch-machineconfig",
  "pattern": "^talosctl\\b.*\\spatch\\s+(?:machineconfig|mc)\\b",
  "reason": "talosctl patch machineconfig duplicates array fields (machine.files etc.) and can brick the node",
  "alternative": "Artemis: 'mise run //kube/clusters/artemis/talos:apply-node <node>' or talosctl apply-config --file for full config replacement. Frostlink: a minimal DELTA patch file, or 'talosctl apply-config --file' \u2014 never pass kube/clusters/frostlink/talos/patches/controlplane.yaml, it is a gen-time patch and will strand the node"
 },
 {
  "id": "talosctl-reset",
  "pattern": "^talosctl\\b.*\\s(?:reset|wipe)\\b",
  "reason": "talosctl reset/wipe is destructive and irreversible",
  "alternative": "Confirm explicitly with the user before proceeding"
 },
 {
  "id": "talosctl-single-node-outage",
  "pattern": "^talosctl\\b.*\\s(?:upgrade|upgrade-k8s|reboot|shutdown)\\b",
  "exempt": "(?:--context[ =]artemis(?:\\s|$)|kube/clusters/artemis/talosconfig)",
  "reason": "Frostlink is a single node \u2014 talosctl upgrade/reboot/shutdown is a FULL cluster outage with nothing to fail over to. This command does not select Artemis, so it may target Frostlink",
  "alternative": "Frostlink: 'mise run //kube/clusters/frostlink/talos:upgrade <version>' (it resolves the schematic first), and only with the user watching. Artemis: 'mise run //kube/clusters/artemis/talos:upgrade-node <node>', or select Artemis in the command (--context artemis or its talosconfig path)"
 },
 {
  "id": "rm-sensitive-path",
  "on": "plain",
  "pattern": "^rm\\b(?=.*\\s(?:-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)(?:\\s|$))(?=.*\\s(?:(?:~|\\$HOME|\\$\\{HOME\\})(?:/\\S*)?|/|/\\*|/(?:etc|var|usr|bin|sbin|lib|lib64|boot|root|opt)(?:/\\S*)?|/home(?:/[^/\\s]+(?:/[^/\\s]+)?)?/?|\\.\\.?/?)(?:\\s|$))",
  "reason": "Recursive delete on a sensitive path",
  "alternative": "Confirm the exact path with the user before deleting. A path below /home/<user>/<dir>, such as a worktree, is not blocked"
 },
 {
  "id": "mv-over-managed-dotfile",
  "on": "plain",
  "pattern": "^mv\\b.*\\s(?:~|\\$HOME|/home/[A-Za-z][\\w.-]*)/(?:\\.claude|\\.config|\\.agents|\\.local/bin)/\\S*$",
  "reason": "mv into ~/.claude, ~/.config, ~/.agents or ~/.local/bin REPLACES a mise-managed symlink with a regular file, silently unlinking it from ~/dotfiles \u2014 edits then stop reaching the repo",
  "alternative": "Use `cp` instead of `mv`, which writes through the symlink and keeps it intact"
 },
 {
  "id": "mise-write-task-subagent",
  "subagent_only": true,
  "decision": "ask",
  "pattern": "^mise\\b(?=.*(?:(?<![\\w/.-])(?:apply-ks|delete-ks|suspend-ks|resume-ks|sync-flux|restore-pvc|release-snapshot|reclaim-pv|reset-hr|unstick-hr|snapshot-pvc|toggle-kopiur|prune-pods|test-ks|land|apply-node|reboot-node|reset-node|shutdown-node|upgrade-node|upgrade-k8s|upgrade|patch-node|phase1|phase2|tailnet|towonel-invite|ucg-authkey)(?![\\w-])|//(?:terraform|ansible):(?:apply|import|run|ucg-authkey)(?![\\w-])|\\s(?:--yes|-y)(?=\\s|$)))",
  "reason": "A subagent is about to run a mise task that writes: it can change a live cluster, a host or the cloud. The safety is the procedure around the task (suspend root and target, watch, wait for confirmation, resume in order), and a subagent skips all of it. The owner has to allow each one.",
  "alternative": "Validate offline instead ('mise run //kube/clusters/<cluster>:render-ks <ns> <ks>'), or read live state with diff-ks. If the write is wanted, approve this prompt."
 },
 {
  "id": "kubectl-write-subagent",
  "subagent_only": true,
  "pattern": "^(?:kubectl|kubecolor)(?:\\s+-[\\w-]+(?:=\\S*)?(?:\\s+[^-\\s]\\S*)?)*\\s+(?:rollout\\s+(?:restart|undo|pause|resume)|exec)\\b",
  "reason": "A subagent is about to change a live cluster with kubectl rollout restart/undo/pause/resume, or with kubectl exec. exec cannot be split into read and write (a shell or psql can write anything), so every kubectl exec is blocked for subagents. rollout status and rollout history are read-only and stay allowed.",
  "alternative": "Read state with kubectl get/describe/logs or the k8s MCP tools. Report the change you want and let the main thread run it, or change the manifest and apply it through the apply-ks task."
 },
 {
  "id": "git-write-subagent",
  "subagent_only": true,
  "decision": "ask",
  "pattern": "^git(?:\\s+-[cC]\\s+\\S+|\\s+--(?:git-dir|work-tree|namespace)(?:=\\S+|\\s+\\S+)|\\s+-\\S+)*\\s+(?:add|commit|push|rebase|merge|reset|checkout|switch|restore|stash(?!\\s+(?:list|show)\\b)|cherry-pick|revert|am|apply|branch\\s+-[dDmM]|tag\\s+(?:-[adfsu]\\S*|[^-\\s]\\S*)|update-ref)\\b",
  "reason": "A subagent is about to write to git history or the working tree (stage, commit, push, rebase, merge, reset, checkout, stash, cherry-pick, branch delete). The owner has to allow each one. This is a PreToolUse hook, so it holds under every permission mode.",
  "alternative": "Leave the working tree dirty and report what you changed, or approve this prompt. Read-only git (status, log, diff, show, worktree) is unaffected."
 }
]""")
ALWAYS_ALLOW = re.compile(r"""^(?:kubectl|kubecolor|helm|helmfile|flux|talosctl|tofu|terraform|git)\b(?=.*\s--dry-run(?:=(?:client|server))?(?:\s|$))""")

SENT = "\x00"
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
SHELL_BEFORE = re.compile(r"(?:^|[\s;&|(])(?:bash|sh|zsh|dash|ksh)(?:\s+-\S+)*\s*$")
SHELL_C = re.compile(r"""^(?:bash|sh|zsh|dash|ksh)\b(?:\s+-\S+)*?\s+-[a-zA-Z]*c\s+(?:'([^']*)'|"((?:[^"\\]|\\.)*)"|(\S+))""")
EVAL = re.compile(r"^eval\s+(.+)$", re.S)
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "time", "command", "builtin", "exec", "nohup"}
WRAPPERS = {"sudo": "ugpCDRTU", "env": "uCS", "xargs": "nPLIdEsa", "watch": "nd", "nice": "n", "timeout": "ks"}


def join_continuations(cmd):
    return re.sub(r"\\\n\s*", " ", cmd)


def heredocs(cmd):
    lines = cmd.split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        for m in HEREDOC.finditer(line):
            feeds_shell = SHELL_BEFORE.search(line[: m.start()]) is not None
            body = []
            while i < len(lines) and lines[i].strip() != m.group(2):
                body.append(lines[i])
                i += 1
            if i < len(lines):
                i += 1
            if feeds_shell:
                out.extend(body)
    return "\n".join(out)


def scan(cmd):
    n = len(cmd)
    b = []
    o = list(cmd)
    stack = ["n"]
    i = 0
    while i < n:
        c = cmd[i]
        ctx = stack[-1]
        if ctx == "d":
            if c == "\\":
                b.append("_")
                if i + 1 < n:
                    b.append("_")
                i += 2
            elif c == '"':
                stack.pop()
                b.append(c)
                i += 1
            elif c == "$" and cmd[i + 1 : i + 2] == "(":
                stack.append("p")
                b.append(SENT)
                b.append(SENT)
                i += 2
            elif c == "`":
                stack.append("bt")
                b.append(SENT)
                i += 1
            else:
                b.append("_")
                i += 1
            continue
        if c == "\\":
            b.append(c)
            if i + 1 < n:
                b.append(cmd[i + 1])
            i += 2
        elif c == "'":
            ansi = i > 0 and cmd[i - 1] == "$"
            j = i + 1
            while j < n:
                if ansi and cmd[j] == "\\":
                    j += 2
                    continue
                if cmd[j] == "'":
                    break
                j += 1
            if j >= n:
                b.append("'")
                b.extend("_" * (n - i - 1))
                i = n
            else:
                b.append("'")
                b.extend("_" * (j - i - 1))
                b.append("'")
                i = j + 1
        elif c == '"':
            stack.append("d")
            b.append(c)
            i += 1
        elif c == "#" and (i == 0 or cmd[i - 1] in " \t\n;&|("):
            j = cmd.find("\n", i)
            if j < 0:
                j = n
            b.extend(" " * (j - i))
            for k in range(i, j):
                o[k] = " "
            i = j
        elif c == "$" and cmd[i + 1 : i + 2] == "(":
            stack.append("p")
            b.append(SENT)
            b.append(SENT)
            i += 2
        elif c == ")":
            if ctx == "p":
                stack.pop()
            b.append(SENT)
            i += 1
        elif c == "`":
            if ctx == "bt":
                stack.pop()
            b.append(SENT)
            i += 1
        elif c in ";|(\n":
            b.append(SENT)
            i += 1
        elif c == "&":
            if (i > 0 and cmd[i - 1] in "<>") or cmd[i + 1 : i + 2] == ">":
                b.append(c)
            else:
                b.append(SENT)
            i += 1
        else:
            b.append(c)
            i += 1
    return "".join(b), "".join(o)


def segments(cmd):
    bs, os_ = scan(cmd)
    out, start = [], 0
    for i, ch in enumerate(bs + SENT):
        if ch == SENT:
            if i > start:
                out.append((bs[start:i], os_[start:i]))
            start = i + 1
    return out


def plain_word(w):
    return re.sub(r"[\\'\"]", "", w)


def base(w):
    return w.rsplit("/", 1)[-1] if "/" in w else w


def prepare(bseg, oseg):
    toks = [(m.start(), m.end()) for m in re.finditer(r"\S+", bseg)]
    assigns = []
    k = 0
    while k < len(toks):
        s, e = toks[k]
        if ASSIGN.match(bseg[s:e]):
            assigns.append(plain_word(oseg[s:e]))
            k += 1
            continue
        w = base(plain_word(oseg[s:e]))
        if w in KEYWORDS:
            k += 1
            continue
        if w in WRAPPERS:
            takes = WRAPPERS[w]
            k += 1
            while k < len(toks):
                t = plain_word(oseg[toks[k][0] : toks[k][1]])
                if t == "--":
                    k += 1
                    break
                if not t.startswith("-"):
                    break
                k += 1
                if len(t) == 2 and t[1] in takes and k < len(toks):
                    k += 1
            if w == "timeout" and k < len(toks):
                k += 1
            continue
        break
    if k >= len(toks):
        return None
    s, e = toks[k]
    word = base(plain_word(oseg[s:e]))
    cmd_b = (word + bseg[e:]).strip()
    cmd_o = (word + oseg[e:]).strip()
    return cmd_b, cmd_o, re.sub(r"['\"]", "", cmd_o), assigns


def shell_bodies(cmd_o):
    m = SHELL_C.match(cmd_o)
    if m:
        if m.group(1) is not None:
            return [m.group(1)]
        if m.group(2) is not None:
            return [m.group(2).replace('\\"', '"')]
        return [m.group(3)]
    m = EVAL.match(cmd_o)
    if m:
        body = m.group(1).strip()
        if len(body) >= 2 and body[0] == body[-1] and body[0] in "'\"":
            body = body[1:-1]
        return [body]
    return []


def judge(cmd, sub, depth=0):
    """Return None (allow), ("ask", rule) or ("block", rule). A block outranks an ask."""
    verdict = None
    for bseg, oseg in segments(heredocs(join_continuations(cmd))):
        prep = prepare(bseg, oseg)
        if prep is None:
            continue
        cmd_b, cmd_o, plain, assigns = prep
        if depth < 3:
            for body in shell_bodies(cmd_o):
                v = judge(body, sub, depth + 1)
                if v and (verdict is None or v[0] == "block"):
                    verdict = v
                if verdict and verdict[0] == "block":
                    return verdict
        if ALWAYS_ALLOW.search(cmd_b):
            continue
        for r in RULES:
            if r.get("subagent_only") and not sub:
                continue
            if not re.search(r["pattern"], plain if r.get("on") == "plain" else cmd_b):
                continue
            if r.get("exempt") and re.search(r["exempt"], plain):
                continue
            if r.get("exempt_env") and (r["exempt_env"] + "=1") in assigns:
                continue
            kind = r.get("decision", "block")
            if kind == "block":
                return ("block", r)
            if verdict is None:
                verdict = ("ask", r)
    return verdict


def main():
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise ValueError("payload is not an object")
    except Exception as e:
        sys.stderr.write("BLOCKED: the guard could not parse the hook payload (%s)\n" % type(e).__name__)
        sys.stderr.write("Alternative: retry the call; if it keeps failing, the guard itself needs fixing\n")
        return 2
    tool_input = payload.get("tool_input")
    cmd = tool_input.get("command", "") if isinstance(tool_input, dict) else ""
    if not isinstance(cmd, str) or not cmd:
        return 0
    v = judge(cmd, bool(payload.get("agent_id")))
    if v is None:
        return 0
    kind, r = v
    if kind == "block":
        sys.stderr.write("BLOCKED: %s\nAlternative: %s\n" % (r["reason"], r["alternative"]))
        return 2
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": "%s Alternative: %s" % (r["reason"], r["alternative"]),
    }}))
    return 0


sys.exit(main())
GUARD_PY_EOF

# Fail closed: the fast path matched, so a missing python3, a crash or an unparseable
# payload must not wave the call through. rc 0 allows (stdout may carry an ask
# decision), rc 2 blocks with the engine's own stderr; anything else blocks here.
printf '%s' "$INPUT" | python3 -c "$GUARD_PY"
rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
    exit "$rc"
fi
echo "BLOCKED: the guard could not evaluate this command (python3 exited $rc)" >&2
echo "Alternative: retry; if it keeps failing, python3 or the guard itself needs fixing" >&2
exit 2
