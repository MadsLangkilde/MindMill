---
name: decide
description: Record a decision in the project's knowledge base, or replace an earlier one. Use when the user makes or states a decision that should last ("we decided…", "from now on…", "let's go with X"), when they overrule a decision the KB has in force ("no, do it this way instead"), or when they ask to "note this decision" or "update the decision". Writes a new decision entry and marks any decision it replaces as superseded.
allowed-tools: Bash(kb list:*), Bash(kb search:*), Bash(kb show:*), Bash(kb resolve:*), Bash(kb lint:*), Bash(kb new decision:*), Bash(kb supersede:*), Bash(kb inbox add:*), Bash(kb fact challenge:*)
---

# Record a decision

The CLI is `kb` (or `"${CLAUDE_PLUGIN_ROOT}/bin/kb"`). Format: `${CLAUDE_PLUGIN_ROOT}/docs/format.md`.

## 0. Asked, or noticed?

- The user **asked** you to record it, or overruled an entry in force: write it directly (steps below).
- **You noticed** something that sounds like a lasting decision, but nobody asked for it to be recorded:
  propose it instead, with `kb inbox add --section decisions --proposed-by session:<session id> --reason "<why it looks like a decision>" …`
  (same fields as below), and tell the user in one line that it's in the inbox.

## 1. Is it a decision?

A decision is something someone chose that should still hold next month: a behaviour, a contract, a scope
cut, an owner. A one-off instruction for the current task is not. When it's unclear, ask in one line:
*"Record this as a decision for `<project>`?"*

## 2. Which project?

The session's project (`kb resolve`) unless the decision is clearly about another one. Decisions that hold
for several apps go to the Overview scope (the wide scope, e.g. `product`) once, never copied into each.
Writing outside the session's project needs `--cross-project` and the user's say-so.

## 3. Does it replace something?

`kb search <key words>` in that project and its related ones. Read each candidate in force. If the new
decision contradicts or narrows one, it **supersedes** it. Never edit an old decision's body. History is
the point.

## 4. Write it

`--project` is the scope it mainly belongs to (a decision for several apps in the Overview). Add
`--scopes` for every other scope it holds specific details for, such as Android when it says what Android does.

```sh
kb new decision --project <scope> --title "<decision as a statement>" \
  --summary "<one standalone line: what was decided>" [--scopes <other scopes it has details for>] \
  [--supersedes <old id>]... [--source <meeting id or URL>] [--tags a,b] [--date YYYY-MM-DD] \
  --body-stdin <<'EOF'
## Decision
<one or two sentences>

## Why
<the reason, the constraint, who decided; "User decision, <date>" if that's all there is>

## Consequences
<what changes in code or process; drop the section if nothing>
EOF
```

`--supersedes` also marks the old entry `status: superseded` with `superseded_by`. Use `--status proposed`
when it's a direction that still needs someone's sign-off.

Title it as the decision itself ("Network retry is set per device"), not as a topic ("Network retry").

## 5. Facts it may change

Look through the project's facts in the index for any the decision makes untrue or out of date. For each,
`kb fact challenge <fact id> --by <decision id> --question "<what may have changed>"`, with the corrected
text on stdin and `--body-stdin` when it is clear. Don't edit the fact; the user decides in the app.

## 6. Confirm

Run `kb lint`. Tell the user in **one line**: `Recorded <id>` or `Recorded <id>, supersedes <old id>`,
plus `; flagged <fact id>` for each fact challenged.
Then carry on with what they were doing. Don't commit unless asked.
