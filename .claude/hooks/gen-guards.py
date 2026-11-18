#!/usr/bin/env python3
"""Generate the destructive-command guards from guard-rules.json.

One rule table, two runtimes. The Claude Code hook (bash + an embedded python engine)
and the opencode plugin (JavaScript) are both generated from guard-rules.json, so they
cannot drift apart, and --check re-generates them, compares them with what is on disk,
and runs guard-cases.json against the generated guards. Pre-commit runs --check, so a
hand-edit, a half-applied change or a rule that stopped doing its job fails the commit.

How a command is judged (identical in both runtimes):
  1. Join backslash-newline continuations.
  2. Heredocs: the body is data and is dropped, unless the heredoc feeds bash/sh/zsh,
     where the body is a script that runs and is kept.
  3. Split into simple commands at ; && || | & ( ) newline, backticks and $( ), blanking
     the inside of '...' and "..." (the quotes stay) and dropping # comments.
     Command substitutions inside double quotes are still split out and checked.
  4. Strip leading VAR=val assignments and wrapper words (sudo, env, exec, xargs, time,
     watch, ...). The next word is the command; rules match from there with ^.
  5. bash|sh|zsh -c '...' and eval '...' re-check their quoted body.
A guarded word therefore counts only in command position: grep 'kubectl apply' and a
file called notes-on-kubectl-apply.md are not commands.

This file and guard-rules.json (and guard-cases.json) are vendored into each repo under
.claude/hooks/, so generation and verification work with no dotfiles checkout present.
The canonical copies live in dotfiles/home/claude/agent-hooks/ and are pushed out by
sync-hooks.sh.

Usage:
    gen-guards.py [--repo-root DIR] [--check]
"""

from __future__ import annotations

import argparse
import concurrent.futures
import difflib
import json
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BANNER = """# GENERATED FILE — do not edit here.
# Source:     .claude/hooks/guard-rules.json  (canonical: dotfiles/home/claude/agent-hooks/)
# Regenerate: python3 .claude/hooks/gen-guards.py
# Verified:   python3 .claude/hooks/gen-guards.py --check   (runs in pre-commit)"""

# The judging engine, Python flavour. Rules are injected as JSON. Keep it in step with
# ENGINE_JS below: --check runs the same cases against both.
# Exit codes: 0 allow (stdout may carry a PreToolUse "ask" decision), 2 block.
ENGINE_PY = r'''
import json, re, sys

RULES = json.loads(r"""__RULES__""")
ALWAYS_ALLOW = re.compile(r"""__ALWAYS_ALLOW__""")

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
'''

# JavaScript flavour of the same engine. opencode has no "ask" and no agent_id, so only
# the rules that are not subagent_only are emitted and every verdict is a block.
ENGINE_JS = r'''
const SENT = "\x00"
const ASSIGN = /^[A-Za-z_][A-Za-z0-9_]*\+?=/
const HEREDOC = /(?<!<)<<(?!<)-?[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1/g
const SHELL_BEFORE = /(?:^|[\s;&|(])(?:bash|sh|zsh|dash|ksh)(?:\s+-\S+)*\s*$/
const SHELL_C = /^(?:bash|sh|zsh|dash|ksh)\b(?:\s+-\S+)*?\s+-[a-zA-Z]*c\s+(?:'([^']*)'|"((?:[^"\\]|\\.)*)"|(\S+))/
const EVAL = /^eval\s+([\s\S]+)$/
const KEYWORDS = new Set(["if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "time", "command", "builtin", "exec", "nohup"])
const WRAPPERS = { sudo: "ugpCDRTU", env: "uCS", xargs: "nPLIdEsa", watch: "nd", nice: "n", timeout: "ks" }

const joinContinuations = (cmd) => cmd.replace(/\\\n\s*/g, " ")

function heredocs(cmd) {
  const lines = cmd.split("\n")
  const out = []
  let i = 0
  while (i < lines.length) {
    const line = lines[i]
    out.push(line)
    i += 1
    for (const m of line.matchAll(HEREDOC)) {
      const feedsShell = SHELL_BEFORE.test(line.slice(0, m.index))
      const body = []
      while (i < lines.length && lines[i].trim() !== m[2]) {
        body.push(lines[i])
        i += 1
      }
      if (i < lines.length) i += 1
      if (feedsShell) out.push(...body)
    }
  }
  return out.join("\n")
}

function scan(cmd) {
  const n = cmd.length
  const b = []
  const o = cmd.split("")
  const stack = ["n"]
  let i = 0
  while (i < n) {
    const c = cmd[i]
    const ctx = stack[stack.length - 1]
    if (ctx === "d") {
      if (c === "\\") {
        b.push("_")
        if (i + 1 < n) b.push("_")
        i += 2
      } else if (c === '"') {
        stack.pop()
        b.push(c)
        i += 1
      } else if (c === "$" && cmd[i + 1] === "(") {
        stack.push("p")
        b.push(SENT, SENT)
        i += 2
      } else if (c === "`") {
        stack.push("bt")
        b.push(SENT)
        i += 1
      } else {
        b.push("_")
        i += 1
      }
      continue
    }
    if (c === "\\") {
      b.push(c)
      if (i + 1 < n) b.push(cmd[i + 1])
      i += 2
    } else if (c === "'") {
      const ansi = i > 0 && cmd[i - 1] === "$"
      let j = i + 1
      while (j < n) {
        if (ansi && cmd[j] === "\\") {
          j += 2
          continue
        }
        if (cmd[j] === "'") break
        j += 1
      }
      if (j >= n) {
        b.push("'")
        for (let k = 0; k < n - i - 1; k++) b.push("_")
        i = n
      } else {
        b.push("'")
        for (let k = 0; k < j - i - 1; k++) b.push("_")
        b.push("'")
        i = j + 1
      }
    } else if (c === '"') {
      stack.push("d")
      b.push(c)
      i += 1
    } else if (c === "#" && (i === 0 || " \t\n;&|(".includes(cmd[i - 1]))) {
      let j = cmd.indexOf("\n", i)
      if (j < 0) j = n
      for (let k = i; k < j; k++) {
        b.push(" ")
        o[k] = " "
      }
      i = j
    } else if (c === "$" && cmd[i + 1] === "(") {
      stack.push("p")
      b.push(SENT, SENT)
      i += 2
    } else if (c === ")") {
      if (ctx === "p") stack.pop()
      b.push(SENT)
      i += 1
    } else if (c === "`") {
      if (ctx === "bt") stack.pop()
      b.push(SENT)
      i += 1
    } else if (";|(\n".includes(c)) {
      b.push(SENT)
      i += 1
    } else if (c === "&") {
      if ((i > 0 && "<>".includes(cmd[i - 1])) || cmd[i + 1] === ">") b.push(c)
      else b.push(SENT)
      i += 1
    } else {
      b.push(c)
      i += 1
    }
  }
  return [b.join(""), o.join("")]
}

function segments(cmd) {
  const [bs, os] = scan(cmd)
  const out = []
  let start = 0
  const padded = bs + SENT
  for (let i = 0; i < padded.length; i++) {
    if (padded[i] === SENT) {
      if (i > start) out.push([bs.slice(start, i), os.slice(start, i)])
      start = i + 1
    }
  }
  return out
}

const plainWord = (w) => w.replace(/[\\'"]/g, "")
const base = (w) => (w.includes("/") ? w.slice(w.lastIndexOf("/") + 1) : w)

function prepare(bseg, oseg) {
  const toks = [...bseg.matchAll(/\S+/g)].map((m) => [m.index, m.index + m[0].length])
  const assigns = []
  let k = 0
  while (k < toks.length) {
    const [s, e] = toks[k]
    if (ASSIGN.test(bseg.slice(s, e))) {
      assigns.push(plainWord(oseg.slice(s, e)))
      k += 1
      continue
    }
    const w = base(plainWord(oseg.slice(s, e)))
    if (KEYWORDS.has(w)) {
      k += 1
      continue
    }
    if (Object.prototype.hasOwnProperty.call(WRAPPERS, w)) {
      const takes = WRAPPERS[w]
      k += 1
      while (k < toks.length) {
        const t = plainWord(oseg.slice(toks[k][0], toks[k][1]))
        if (t === "--") {
          k += 1
          break
        }
        if (!t.startsWith("-")) break
        k += 1
        if (t.length === 2 && takes.includes(t[1]) && k < toks.length) k += 1
      }
      if (w === "timeout" && k < toks.length) k += 1
      continue
    }
    break
  }
  if (k >= toks.length) return null
  const e = toks[k][1]
  const word = base(plainWord(oseg.slice(toks[k][0], e)))
  const cmdB = (word + bseg.slice(e)).trim()
  const cmdO = (word + oseg.slice(e)).trim()
  return [cmdB, cmdO, cmdO.replace(/['"]/g, ""), assigns]
}

function shellBodies(cmdO) {
  let m = SHELL_C.exec(cmdO)
  if (m) {
    if (m[1] !== undefined) return [m[1]]
    if (m[2] !== undefined) return [m[2].replaceAll('\\"', '"')]
    return [m[3]]
  }
  m = EVAL.exec(cmdO)
  if (m) {
    let body = m[1].trim()
    if (body.length >= 2 && body[0] === body[body.length - 1] && "'\"".includes(body[0])) body = body.slice(1, -1)
    return [body]
  }
  return []
}

function judge(cmd, depth = 0) {
  for (const [bseg, oseg] of segments(heredocs(joinContinuations(cmd)))) {
    const prep = prepare(bseg, oseg)
    if (!prep) continue
    const [cmdB, cmdO, plain, assigns] = prep
    if (depth < 3) {
      for (const body of shellBodies(cmdO)) {
        const v = judge(body, depth + 1)
        if (v) return v
      }
    }
    if (ALWAYS_ALLOW.test(cmdB)) continue
    for (const rule of RULES) {
      if (!rule.pattern.test(rule.on === "plain" ? plain : cmdB)) continue
      if (rule.exempt && rule.exempt.test(plain)) continue
      if (rule.exemptEnv && assigns.includes(rule.exemptEnv + "=1")) continue
      return rule
    }
  }
  return null
}

export const GuardDestructive = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return
      const rule = judge(output.args?.command ?? "")
      if (rule) throw new Error(`BLOCKED: ${rule.reason}\nAlternative: ${rule.alternative}`)
    },
  }
}
'''


def expand(spec: dict, text: str) -> str:
    for name, body in spec.get("macros", {}).items():
        text = text.replace(f"<<{name}>>", body)
    return text


def rules_for(spec: dict, repo_key: str) -> list[dict]:
    out = []
    for rule in spec["rules"]:
        repos = rule.get("repos")
        if repos is None or repo_key in repos:
            rule = dict(rule, pattern=expand(spec, rule["pattern"]))
            if rule.get("exempt"):
                rule["exempt"] = expand(spec, rule["exempt"])
            out.append(rule)
    return out


def fast_path_regex(spec: dict) -> str:
    parts = list(spec["fast_path_keywords"])
    parts += [f"(^|[^[:alnum:]_]){w}[^[:alnum:]_]" for w in spec["fast_path_words"]]
    return "(" + "|".join(parts) + ")"


def engine_py(spec: dict, repo_key: str) -> str:
    rules = [
        {k: v for k, v in r.items() if k not in ("//", "repos", "exempt_reason")}
        for r in rules_for(spec, repo_key)
    ]
    return (
        ENGINE_PY.replace("__RULES__", json.dumps(rules, indent=1))
        .replace("__ALWAYS_ALLOW__", expand(spec, spec["always_allow"]["pattern"]))
        .strip("\n")
    )


def render_bash(spec: dict, repo_key: str) -> str:
    lines = [
        "#!/usr/bin/env bash",
        BANNER,
        "#",
        "# PreToolUse:Bash — blocks destructive cluster operations that bypass GitOps or",
        "# the sanctioned mise tasks, and asks the owner before a subagent runs a write task",
        "# or a git write. The judging is the python engine below; this wrapper is the fast",
        "# path and the fail-closed handling.",
        "",
        "set -uo pipefail",
        "",
        "INPUT=$(cat)",
        "",
        "# Fast path: skip the python engine when no rule can possibly fire. The command is",
        "# always a part of this raw payload, so a keyword absent here cannot appear in it.",
        f'[[ "$INPUT" =~ {fast_path_regex(spec)} ]] || exit 0',
        "",
        "# agent_id is present in the PreToolUse payload ONLY when the hook fires inside a",
        "# subagent; the engine reads it. agent_type is NOT a substitute: it is also set on a",
        "# main thread launched with --agent. The field ships in the binary's hook schema but",
        "# is not in the public docs, so if a subagent rule ever stops firing, check that this",
        "# field still exists before anything else.",
        "# read -d '' rather than $(cat <<EOF): bash 3.2 mis-parses a heredoc inside $( ).",
        "read -r -d '' GUARD_PY <<'GUARD_PY_EOF' || true",
        engine_py(spec, repo_key),
        "GUARD_PY_EOF",
        "",
        "# Fail closed: the fast path matched, so a missing python3, a crash or an unparseable",
        "# payload must not wave the call through. rc 0 allows (stdout may carry an ask",
        "# decision), rc 2 blocks with the engine's own stderr; anything else blocks here.",
        'printf \'%s\' "$INPUT" | python3 -c "$GUARD_PY"',
        "rc=$?",
        'if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then',
        '    exit "$rc"',
        "fi",
        'echo "BLOCKED: the guard could not evaluate this command (python3 exited $rc)" >&2',
        'echo "Alternative: retry; if it keeps failing, python3 or the guard itself needs fixing" >&2',
        "exit 2",
        "",
    ]
    return "\n".join(lines)


def js_regex(pattern: str) -> str:
    return f"new RegExp({json.dumps(pattern)})"


def render_js(spec: dict, repo_key: str) -> str:
    entries = []
    for rule in rules_for(spec, repo_key):
        # subagent_only rules are deliberately NOT emitted here. They depend on the
        # PreToolUse agent_id field, which is Claude Code's; opencode's tool.execute.before
        # has no equivalent, so emitting them would block every call including hermes'
        # own — the opposite of the intent. They are "ask" decisions, which opencode's
        # plugin API cannot express either (a hook can only throw, which is a block).
        if rule.get("subagent_only"):
            continue
        entries.append(
            "  {\n"
            + f"    id: {json.dumps(rule['id'])},\n"
            + f"    pattern: {js_regex(rule['pattern'])},\n"
            + (f"    on: {json.dumps(rule['on'])},\n" if rule.get("on") else "")
            + (f"    exempt: {js_regex(rule['exempt'])},\n" if rule.get("exempt") else "")
            + (f"    exemptEnv: {json.dumps(rule['exempt_env'])},\n" if rule.get("exempt_env") else "")
            + f"    reason: {json.dumps(rule['reason'])},\n"
            + f"    alternative: {json.dumps(rule['alternative'])},\n"
            + "  },"
        )

    return f"""// {BANNER.replace(chr(10) + "# ", chr(10) + "// ").lstrip("# ")}
//
// opencode counterpart to .claude/hooks/guard-destructive.sh. Both are generated from
// the same rule table and run the same cases, so the two cannot drift apart.

const RULES = [
{chr(10).join(entries)}
]

const ALWAYS_ALLOW = {js_regex(expand(spec, spec["always_allow"]["pattern"]))}
{ENGINE_JS}"""


def run_bash_case(guard: Path, cmd: str, sub: bool) -> str:
    payload = {"tool_name": "Bash", "tool_input": {"command": cmd}}
    if sub:
        payload["agent_id"] = "case-agent"
    p = subprocess.run(["bash", str(guard)], input=json.dumps(payload), capture_output=True, text=True)
    if p.returncode == 2:
        return "block"
    if p.returncode == 0:
        if p.stdout.strip():
            out = json.loads(p.stdout)
            return out["hookSpecificOutput"]["permissionDecision"]
        return "allow"
    return f"rc={p.returncode}"


JS_RUNNER = """
import { readFileSync } from "node:fs"
const [plugin, casesFile] = process.argv.slice(2)
const { GuardDestructive } = await import(plugin)
const hooks = await GuardDestructive()
const cases = JSON.parse(readFileSync(casesFile, "utf8"))
const out = []
for (const c of cases) {
  try {
    await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: c.command } })
    out.push("allow")
  } catch (e) {
    out.push("block")
  }
}
console.log(JSON.stringify(out))
"""


def run_cases(spec: dict, repo_key: str, cases_doc: dict) -> int:
    """Run guard-cases.json against the generated bash guard and, if node exists, the JS."""
    if repo_key not in cases_doc.get("repos", [repo_key]):
        return 0
    cases = cases_doc["cases"]
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        guard = Path(tmp) / "guard-destructive.sh"
        guard.write_text(render_bash(spec, repo_key))
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            got = list(pool.map(lambda c: run_bash_case(guard, c["command"], c.get("subagent", False)), cases))
        for c, g in zip(cases, got):
            if g != c["expect"]:
                failures.append(f"bash guard: expected {c['expect']}, got {g}: {c['command']!r} (subagent={c.get('subagent', False)})")

        # Fail closed: a payload that does not parse, or a missing python3, must block
        # when the fast path matched, not wave the call through.
        garbage = subprocess.run(["bash", str(guard)], input="kubectl {not json", capture_output=True, text=True)
        if garbage.returncode != 2:
            failures.append(f"bash guard: an unparseable payload must block (rc 2), got rc {garbage.returncode}")
        bindir = Path(tmp) / "bin"
        bindir.mkdir()
        (bindir / "cat").symlink_to(shutil.which("cat"))
        nopy = subprocess.run(
            [shutil.which("bash"), str(guard)],
            input=json.dumps({"tool_input": {"command": "kubectl get pods"}}),
            capture_output=True,
            text=True,
            env={"PATH": str(bindir)},
        )
        if nopy.returncode != 2:
            failures.append(f"bash guard: a missing python3 must block (rc 2), got rc {nopy.returncode}")

        node = shutil.which("node")
        js_n = 0
        if node:
            plugin = Path(tmp) / "guard-destructive.mjs"
            plugin.write_text(render_js(spec, repo_key))
            runner = Path(tmp) / "runner.mjs"
            runner.write_text(JS_RUNNER)
            # opencode has no ask and no agent_id, so cases that expect an ask are skipped there.
            js_cases = [c for c in cases if c["expect"] != "ask"]
            cfile = Path(tmp) / "cases.json"
            cfile.write_text(json.dumps(js_cases))
            p = subprocess.run([node, str(runner), str(plugin), str(cfile)], capture_output=True, text=True)
            if p.returncode != 0:
                failures.append(f"js guard: node failed: {p.stderr.strip()[:300]}")
            else:
                for c, g in zip(js_cases, json.loads(p.stdout)):
                    if g != c["expect"]:
                        failures.append(f"js guard: expected {c['expect']}, got {g}: {c['command']!r}")
                js_n = len(js_cases)
        else:
            print("note: node not found, the opencode guard was not run against the cases", file=sys.stderr)

    if failures:
        print(f"guard-cases.json: {len(failures)} failure(s)", file=sys.stderr)
        for f in failures:
            print("  " + f, file=sys.stderr)
        return 1
    print(f"guard-cases.json: {len(cases)} cases pass on the bash guard" + (f", {js_n} on the JS guard" if node else ""))
    return 0


def emit(path: Path, content: str, check: bool, executable: bool) -> bool:
    """Write content, or in check mode report whether it already matches. True == drift."""
    existing = path.read_text() if path.exists() else None
    if existing == content:
        return False
    if check:
        rel = path
        print(f"DRIFT: {rel} does not match guard-rules.json", file=sys.stderr)
        for line in difflib.unified_diff(
            (existing or "").splitlines(keepends=True),
            content.splitlines(keepends=True),
            fromfile=f"{rel} (on disk)",
            tofile=f"{rel} (generated)",
        ):
            sys.stderr.write(line)
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    if executable:
        path.chmod(0o755)
    print(f"wrote {path}")
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo-root", default=None, help="repo root (default: parent of .claude/hooks)")
    ap.add_argument("--check", action="store_true", help="fail on drift instead of rewriting, and run guard-cases.json")
    args = ap.parse_args()

    here = Path(__file__).resolve().parent
    root = Path(args.repo_root).resolve() if args.repo_root else here.parent.parent

    spec = json.loads((here / "guard-rules.json").read_text())

    key_file = here / "guard-repo"
    if not key_file.exists():
        print(f"error: {key_file} is missing — it names which repo's rules to emit", file=sys.stderr)
        return 2
    repo_key = key_file.read_text().strip()

    known = {r for rule in spec["rules"] for r in rule.get("repos", [])}
    if known and repo_key not in known:
        print(f"error: unknown repo key {repo_key!r}; guard-rules.json knows {sorted(known)}", file=sys.stderr)
        return 2

    drift = emit(root / ".claude/hooks/guard-destructive.sh", render_bash(spec, repo_key), args.check, True)

    opencode = root / ".opencode/plugins"
    if opencode.is_dir():
        drift |= emit(opencode / "guard-destructive.js", render_js(spec, repo_key), args.check, False)

    if drift:
        print(
            "\nThe guards are generated. Edit .claude/hooks/guard-rules.json, then run:\n"
            "    python3 .claude/hooks/gen-guards.py",
            file=sys.stderr,
        )
        return 1

    cases_file = here / "guard-cases.json"
    if args.check and cases_file.exists():
        return run_cases(spec, repo_key, json.loads(cases_file.read_text()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
