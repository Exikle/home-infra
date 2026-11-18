// GENERATED FILE — do not edit here.
// Source:     .claude/hooks/guard-rules.json  (canonical: dotfiles/home/claude/agent-hooks/)
// Regenerate: python3 .claude/hooks/gen-guards.py
// Verified:   python3 .claude/hooks/gen-guards.py --check   (runs in pre-commit)
//
// opencode counterpart to .claude/hooks/guard-destructive.sh. Both are generated from
// the same rule table and run the same cases, so the two cannot drift apart.

const RULES = [
  {
    id: "kubectl-mutation",
    pattern: new RegExp("^(?:kubectl|kubecolor)(?:\\s+-[\\w-]+(?:=\\S*)?(?:\\s+[^-\\s]\\S*)?)*\\s+(?:apply|patch|replace|create|edit|scale|drain|set|label|annotate)\\b"),
    reason: "Direct kubectl writes bypass GitOps",
    alternative: "Apply through the apply-ks task of the cluster: 'mise run //kube/clusters/<cluster>:apply-ks <ns> <ks>'. cordon, uncordon and rollout are not blocked.",
  },
  {
    id: "kubectl-delete-critical",
    pattern: new RegExp("^(?:kubectl|kubecolor)(?:\\s+-[\\w-]+(?:=\\S*)?(?:\\s+[^-\\s]\\S*)?)*\\s+delete\\b(?=.*(?:\\s-[fkR]\\b|\\s--(?:all|filename|kustomize|recursive)(?=[\\s=]|$)|\\s(?:ns|namespaces?|pvcs?|pvs?|persistentvolumes?|persistentvolumeclaims?|nodes?|no|deploy|deployments?|ds|daemonsets?|sts|statefulsets?|secrets?|crds?|customresourcedefinitions?|clusters?|helmreleases?|hr|kustomizations?|ks|ocirepositor(?:y|ies)|gitrepositor(?:y|ies)|gateways?|httproutes?|clusterroles?|all)(?=[\\s,/]|$)))"),
    exemptEnv: "I_HAVE_A_KOPIUR_SNAPSHOT",
    reason: "Deleting a critical Kubernetes resource",
    alternative: "Confirm with the user before deleting cluster resources. If this is a planned PVC recreation with a verified snapshot, prefix the command with I_HAVE_A_KOPIUR_SNAPSHOT=1 (see .agents/skills/recreate-pvc); on Frostlink use 'mise run //kube/clusters/frostlink:restore-pvc' instead",
  },
  {
    id: "helm-mutation",
    pattern: new RegExp("^helm(?:\\s+-[\\w-]+(?:=\\S*)?(?:\\s+[^-\\s]\\S*)?)*\\s+(?:install|upgrade|uninstall|delete|rollback)\\b"),
    reason: "Direct helm mutations are not allowed \u2014 config lives in HelmRelease manifests",
    alternative: "Edit the HelmRelease values and apply via Flux",
  },
  {
    id: "helmfile-mutation",
    pattern: new RegExp("^helmfile\\b.*\\s(?:sync|apply|destroy|delete)(?=\\s|$)"),
    reason: "helmfile sync/apply/destroy/delete changes a live cluster outside GitOps",
    alternative: "Use the bootstrap tasks ('mise run //kube/clusters/frostlink/bootstrap:phase1' and the rebuild order in oci-rebuild.md), with the user watching",
  },
  {
    id: "flux-destructive",
    pattern: new RegExp("^flux(?:\\s+-[\\w-]+(?:=\\S*)?(?:\\s+[^-\\s]\\S*)?)*\\s+(?:delete|uninstall)\\b"),
    reason: "Destructive flux operation",
    alternative: "Confirm with the user before deleting Flux resources",
  },
  {
    id: "tofu-mutation",
    pattern: new RegExp("^(?:tofu|terraform)(?:\\s+-\\S+)*\\s+(?:apply|destroy|import|state)\\b"),
    reason: "A bare tofu/terraform write skips the repo's task wrapper, which sets the workspace, credentials and the import-first check",
    alternative: "Use the mise tasks: 'mise run //terraform:plan', and with the user's go-ahead 'mise run --yes //terraform:apply'",
  },
  {
    id: "talosctl-patch-machineconfig",
    pattern: new RegExp("^talosctl\\b.*\\spatch\\s+(?:machineconfig|mc)\\b"),
    reason: "talosctl patch machineconfig duplicates array fields (machine.files etc.) and can brick the node",
    alternative: "Artemis: 'mise run //kube/clusters/artemis/talos:apply-node <node>' or talosctl apply-config --file for full config replacement. Frostlink: a minimal DELTA patch file, or 'talosctl apply-config --file' \u2014 never pass kube/clusters/frostlink/talos/patches/controlplane.yaml, it is a gen-time patch and will strand the node",
  },
  {
    id: "talosctl-reset",
    pattern: new RegExp("^talosctl\\b.*\\s(?:reset|wipe)\\b"),
    reason: "talosctl reset/wipe is destructive and irreversible",
    alternative: "Confirm explicitly with the user before proceeding",
  },
  {
    id: "talosctl-single-node-outage",
    pattern: new RegExp("^talosctl\\b.*\\s(?:upgrade|upgrade-k8s|reboot|shutdown)\\b"),
    exempt: new RegExp("(?:--context[ =]artemis(?:\\s|$)|kube/clusters/artemis/talosconfig)"),
    reason: "Frostlink is a single node \u2014 talosctl upgrade/reboot/shutdown is a FULL cluster outage with nothing to fail over to. This command does not select Artemis, so it may target Frostlink",
    alternative: "Frostlink: 'mise run //kube/clusters/frostlink/talos:upgrade <version>' (it resolves the schematic first), and only with the user watching. Artemis: 'mise run //kube/clusters/artemis/talos:upgrade-node <node>', or select Artemis in the command (--context artemis or its talosconfig path)",
  },
  {
    id: "rm-sensitive-path",
    pattern: new RegExp("^rm\\b(?=.*\\s(?:-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)(?:\\s|$))(?=.*\\s(?:(?:~|\\$HOME|\\$\\{HOME\\})(?:/\\S*)?|/|/\\*|/(?:etc|var|usr|bin|sbin|lib|lib64|boot|root|opt)(?:/\\S*)?|/home(?:/[^/\\s]+(?:/[^/\\s]+)?)?/?|\\.\\.?/?)(?:\\s|$))"),
    on: "plain",
    reason: "Recursive delete on a sensitive path",
    alternative: "Confirm the exact path with the user before deleting. A path below /home/<user>/<dir>, such as a worktree, is not blocked",
  },
  {
    id: "mv-over-managed-dotfile",
    pattern: new RegExp("^mv\\b.*\\s(?:~|\\$HOME|/home/[A-Za-z][\\w.-]*)/(?:\\.claude|\\.config|\\.agents|\\.local/bin)/\\S*$"),
    on: "plain",
    reason: "mv into ~/.claude, ~/.config, ~/.agents or ~/.local/bin REPLACES a mise-managed symlink with a regular file, silently unlinking it from ~/dotfiles \u2014 edits then stop reaching the repo",
    alternative: "Use `cp` instead of `mv`, which writes through the symlink and keeps it intact",
  },
]

const ALWAYS_ALLOW = new RegExp("^(?:kubectl|kubecolor|helm|helmfile|flux|talosctl|tofu|terraform|git)\\b(?=.*\\s--dry-run(?:=(?:client|server))?(?:\\s|$))")

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
