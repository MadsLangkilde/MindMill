---
name: work-item
description: Create, draft or propose a PBI, bug or task in the current project's work-item tracker (Azure DevOps, Mindmill's own tracker, or Jira), guided step by step and using what the knowledge base knows about the project. It learns the tracker's organization, project, area, sprints, team and conventions as it goes and asks only for what it can't infer. Use for "create a PBI", "make a bug for this", "add a work item", "turn this follow-up into a PBI", "propose PBIs from this meeting", /create-pbi in a project without its own create-pbi skill, and when the Mindmill app's Create PBI button starts it.
allowed-tools: Bash(kb:*), Bash(git:*), Read, Grep, Glob, AskUserQuestion
---

# Work items

The CLI is `kb` (or `"${CLAUDE_PLUGIN_ROOT}/bin/kb"`). A work item is drafted as a **backlog entry**
(`projects/<p>/backlog/`, format in `${CLAUDE_PLUGIN_ROOT}/docs/format.md`) and only becomes a real tracker
item after the user approves it: here in chat, or with the Create button in the Mindmill app.

If the repo has its own work-item skill (such as `.claude/skills/create-pbi`) and the user invoked it by
name, that skill wins. This one is the project-aware default.

## Asking

- **Terminal:** every choice uses `AskUserQuestion`, with a step number and title in `header`
  ("3. Sprint") and real, fetched values as options. The recommended option comes first, marked
  "(Recommended)". Never add an "I'll type it" option; Other covers it.
- **Mindmill app** (the system prompt says you run in the Mindmill app): `AskUserQuestion` isn't available. Ask one
  question per message: a short bold heading with the step ("**3. Sprint**"), one line of context, then a
  ` ```choices ` block with one option per line (recommended first, marked "(Recommended)"). For a
  multi-select use ` ```choices multi `. The user clicks an option or types their own answer.
- **Ask only when needed.** When the settings or the source already settle a step, don't ask it. Show the
  values you'll use in the summary at step 8 instead, where the user can change them.

## 1. Source

The item usually comes from somewhere: a follow-up, a meeting's action item, a decision, a reminder, or the
user's own words. Read it (`kb show <id>`) and what it links to, so the draft builds on it and picks up
details already decided (a parent id like 417760, the platform, the sprint). An action item that says
"PBI(s)" may need more than one item; propose the split as a choice.

Then check it doesn't exist already: `kb list --section backlog` (proposals and created items) and
`kb tracker items --search "<2–3 keywords>"` (Azure DevOps, also closed items). When one covers it, show it
(number, title, state) and ask: "Use #<n>" (on a follow-up, close it with `--resolved-by <its url>`) /
"Create a new one anyway" / "Make it a child of #<n>". Don't draft until the user picks.

## 2. Know the tracker (learn once)

`kb tracker show --project <p>` prints the project's `tracker` settings: kind, organization, project,
area path, iteration root, title prefix, tags, default parent, assignee, and how "found in" is derived
for bugs.

Missing or incomplete? **Infer first, then ask, then save:**
- A git remote in the project's paths (`dev.azure.com/<org>/<project>/_git/<repo>` → azure-devops, org,
  project). A related project's tracker (`kb settings show --project <related>`): offer "Same as
  <related>" as the first choice. The project's own skills or docs that describe its work items.
- Ask for the rest with concrete options. Save each answer at once with
  `kb settings set tracker.<key> '<json>' --project <p>`, and say in one line what you saved so the user
  can correct it in the app's project settings.
- Rules that aren't tracker fields ("titles get `iOS: ` or `Android: ` by the platform it's for", "bugs from
  customers get the `Customer` tag") go in `kb settings set conventions.<key> '"<one sentence>"'`.
- Never store credentials. Azure DevOps uses the PAT in `~/.git-credentials`.

`tracker.kind` decides where the item goes. Steps 3–9 below are for `azure-devops`; for `local` and `jira`
see **Local and Jira trackers** at the end, which changes only where the item is looked up and created.

When a stored value turns out stale (for example `kb tracker sprints` notes that `iteration_root` has no
current sprint), show what the tracker has now, ask, and save the fix.

## 3. Type

PBI or Bug. Skip when the source says it.

## 4. Parent

Options, in this order and only those that exist: a parent named in the source (check it with
`kb tracker item <id>` and show its title), `tracker.default_parent`, two or three likely features from
`kb tracker features --search "<keyword>"`, then "No parent". When the user types a keyword, search
features with it and offer the matches.

## 5. Sprint

`kb tracker sprints --project <p>`. Options: the current sprint (Recommended), the next one, "No sprint".
Use the full iteration path.

## 6. Area, assignee, tags

- **Area:** `tracker.area_path` unless the user wants another (`kb tracker areas`). "No area" is `none`.
- **Assignee:** `tracker.assignee` (the user) or someone from `kb tracker people [name]`, or "Not now"
  (`none`). An action item's owner is a strong hint.
- **Tags:** `tracker.tags` plus any the source suggests (multi-select).
- **Bug only:** `found_in` the way the settings say, for example `VERSION_NAME (VERSION_CODE)` from
  `gradle.properties` in the project's repo. Required.

Ask these only when there is no setting, or the source points elsewhere.

## 7. Draft

From the source, the KB (`kb search`, related decisions and follow-ups) and the code where it helps:
- **Title:** specific and outcome-shaped. No prefix; the tracker settings add it.
- **Description:** what and why, in Markdown. Say where it comes from **in words** a teammate can follow
  ("decided in Contoso sprint planning, 2026-11-09"), never as a KB id.
- **Acceptance criteria:** 3–5 checkable bullets.

Write it as a backlog entry in the scope that owns the tracker (Android's items in the Android scope):

```sh
kb new backlog --project <p> --type pbi|bug --title "…" --summary "…" --source <ids, comma-separated> \
  [--tags a,b] [--field sprint="<iteration path>"|none] [--field parent=<id>|none] \
  [--field area="<path>"|none] [--field assignee=<user>|none] [--field found_in="1.0.0 (57)"] \
  --body-stdin <<'EOF'
## Description
…

## Acceptance criteria
- …
EOF
```

When a matching proposed backlog entry already exists (`kb list --section backlog`, or one waiting in the
inbox), update and use that one instead of drafting a second.

**Work items are shared with the team; the KB is only on this machine.** Never put KB entry ids
(`product/decisions/…`), KB file paths, `kb://` links or other local paths in the title, description or
acceptance criteria. The backlog entry's `source` field keeps the link to the KB for you. Tracker ids
(#417760), repo file paths and URLs others can open are fine. `kb backlog create` drops a parenthetical KB
reference itself and refuses to create an item that still mentions one; then rewrite that sentence.

## 8. Confirm

Show the whole item, formatted: type, the prefixed title, description, acceptance criteria, sprint, area,
parent (id and title), assignee and tags. Then ask: "Create it" / "Edit title" / "Edit description" /
"Edit acceptance criteria" / "Change sprint, parent or assignee" / "Keep as proposal". Edit the backlog
entry and ask again until the user picks Create or Keep.

## 9. Create (only on approval)

`kb backlog create <id> --yes`. Print the work item id and URL from its output as a Markdown link.
A dry run without `--yes` prints exactly what would be posted.

Then, when it came from a follow-up, ask whether to close it:
`kb followup close <followup id> --status done --resolved-by "<work item url>"`. When several items
were created from it, pass `--resolved-by` once per URL (they are stored as a list and shown one per line).

Never create a work item without the user's explicit approval in this conversation or a click in the app.
**Keep as proposal** leaves the backlog entry; it shows in the app's Backlog section with a Create button.

## Local and Jira trackers

**`local`** is Mindmill's own tracker (`kb work`, see `docs/format.md`). Items are features, PBIs, bugs and tasks
(feature → PBI/bug → task). Ask and draft as above, but:
- Duplicates: `kb work list --all --scope <p>`. Parent: `kb work list --type feature` (for a task
  `--type pbi,bug`), then "No parent". Sprint: only when `kb work sprint list` says sprints are on (current,
  a later one, "No sprint"). Skip area and `found_in`.
- Draft in chat, not as a backlog entry. Confirm as in step 8 ("Not now" instead of "Keep as proposal").
- On approval:
  ```sh
  kb work add pbi|bug|feature|task "<title>" --scope <p> [--parent <id>] [--sprint current|<name>] \
    [--assignee <name>] [--tags a,b] --acceptance "- …
  - …" --description - <<'EOF'
  <description in Markdown>
  EOF
  ```
  A bug's steps to reproduce go in `--repro`. It prints `created <id>`: tell the user "#<id> in Mindmill's
  tracker". From a follow-up, close it with `--resolved-by "#<id> in Mindmill's tracker"`.

**`jira`**: work goes through Claude's Jira connector, not `kb`. Find its tools (names containing `jira` or
`atlassian`). None connected: say so ("Jira isn't connected in this session; connect it, or keep this as a
draft") and stop. Otherwise use them for the duplicate check, the parent (an epic) and the sprint, draft in
chat, and on approval create the issue (Story for a PBI, Bug, Task) with the description and acceptance
criteria. Print its key as a link. The same rule holds: no KB ids or local paths in it.

## Proposing from the knowledge base

When asked to "propose work" (or from `kb:today`): scan open follow-ups of kind `action`, meeting action
items, and active decisions whose consequences need code that doesn't exist yet (grep for it). Draft each
as a backlog entry with `status: proposed` and `source` pointing at what it came from. Check
`kb list --section backlog --include-superseded` and `kb tracker items --search "<keyword>"` first, so
nothing is proposed twice. Never create items in this mode; the user picks in the app.
