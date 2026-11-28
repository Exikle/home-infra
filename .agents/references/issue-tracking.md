# Issue Tracking — home-infra

Work that is parked, blocked, or deferred becomes a Forgejo issue. It does not live only in the
session journal.

The journal records what happened in a session. The issue tracker records what is still owed.
The journal is disposable and machine-local (`~/.agents/AGENTS.md` § Memory, which wins). A
journal bullet also cannot express a dependency or carry labels, and nobody can filter it.

## When to file

File an issue at the moment you consciously decide not to finish the work:

| Situation                                | Label            |
| ---------------------------------------- | ---------------- |
| Known, deliberately not being worked on  | `status/parked`  |
| Cannot proceed until a dependency clears | `status/blocked` |

An issue with no `status/*` label is in active work. There is no `status/in-progress`, because
the board column already says the same thing.

If a real dependency exists, say what it is and make it a checklist item. A `status/blocked`
issue with no stated blocker is a `status/parked` issue under another name.

Do not file an issue for anything finished within the session, for machine-local state (journal
formatting, scratch files), or for a preference with no work attached. Those stay in the journal,
or in memini if they are a durable lesson.

## Labels are the state; the Project board is only a view

Forgejo Projects has no REST API. `/repos/{owner}/{repo}/projects`, `/orgs/{owner}/projects`
and `/projects` all return 404, and `project` appears nowhere in the swagger spec. The Forgejo
tools of the `-ops` tier expose nothing for it either, because the MCP wraps that same API.
Column automation does not exist either. A column has a title, a colour, and an optional
"default" flag, and nothing more (forgejo/forgejo#773, open since 2023).

These consequences matter:

- No agent can read or write the board. Never treat the column of a card as the state of anything.
- Labels are the only machine-readable truth. Set them correctly even when the board looks right.
- Adding an issue to a board and moving its card are manual actions that a human does in the web UI.

Boards are per repo, not org-level. Both clusters share this repo, so they share its board. The
`cluster/*` label tells them apart.

## Label taxonomy

There are five axes, and you can query each one through the API. `.forgejo/labels.yaml` is the
source of truth. The labels-sync workflow prunes. So if you remove a label from that file, the
workflow deletes it server-side and strips it from every issue and PR that carries it.

| Namespace   | Notes                                                                                                        |
| ----------- | ------------------------------------------------------------------------------------------------------------ |
| `kind/`     | what sort of work it is                                                                                      |
| `status/`   | `parked`, `blocked`. No label means active                                                                   |
| `area/`     | `.forgejo/labeler.yaml` applies it to PRs automatically. Run `list_labels` for the live set                  |
| `cluster/`  | `artemis`, `frostlink`. Set the one that the work touches. `.forgejo/labeler.yaml` applies it to PRs by path |
| `priority/` | `high` only. It is a flag, not a scale. No label means normal                                                |

Values: `grep 'name:' .forgejo/labels.yaml`.

`local-only` is outside the axes. It goes on every issue (§ Filing one). It must stay in
`.forgejo/labels.yaml`, because the labels-sync workflow strips a label that the file does not
list, and forgesync then copies those issues to GitHub.

`priority/` is one label on purpose. It once carried `high`, `medium` and `low`. But `medium` was
the default and carried no information, and `low` was indistinguishable from `status/parked`.
Parked does not mean unimportant. A parked item can still be `priority/high`.

Do not reuse `type/*`. Renovate owns it, on PRs only. There is no `renovate/*` namespace and no
`hold` or `hold/upstream`. Use `status/blocked` for anything held on an upstream fix, on our
work, or on the work of Renovate.

`area/*` is where the gaps show up. Add another label rather than force a bad fit. Add it to
`.forgejo/labels.yaml`, and give it a glob in `.forgejo/labeler.yaml` if PRs must get it too.

`area/kubernetes` is deliberately the fallback for app namespaces with no glob of their own. It
matches most PRs, so it is not a useful filter on its own.

## Filing one

Use the Forgejo tools of the `-ops` tier where they fit. Tool names carry a server prefix that
changes when the gateway is rewired. List the tools and match on the suffix. Do not hardcode a
fully-qualified name.

Every issue that you file gets the `local-only` label. forgesync (the bot that copies issues
between Forgejo and the GitHub mirror) never copies an issue with that label to GitHub. If you
forget the label, forgesync copies the issue on its next run. Adding the label later does not
remove that copy.

From the shell, use `fjo`. It takes label names, so you do not need to look up label IDs:

```bash
fjo issue create -R Exikle/home-infra --title "<title>" -F body.md -l local-only -l status/parked -l area/<x>
fjo issue edit <N> -R Exikle/home-infra --add-label status/blocked
```

Write the body so that the next reader does not have to re-derive the investigation. State the
evidence, what you already ruled out, and the order of work. `#1700` is the model. It records
two corrections to its own first diagnosis, so that nobody repeats them.

## Journal and tracker together

Use both. `session.md` says what the journal records, and it wins. The issue is the durable
obligation. memini holds the non-obvious lesson.

When a session parks something, the journal entry says so and names the issue number. When you
file an issue, put its number in the journal entry that created it. A journal bullet that
describes parked work with no issue number is a bug in the process.
