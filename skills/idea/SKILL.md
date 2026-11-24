---
name: idea
description: Brainstorm the user's ideas kept in the KB and grow them into backlog items, facts, decisions, follow-ups, architecture notes or a new KB project. Use for "I have an idea…", "write down this idea", "brainstorm X with me", "turn this idea into PBIs / a project", and when the Mindmill app's Ideas buttons send `/mindmill:idea <action> …`.
allowed-tools: Bash(kb:*), Read, Edit, Grep, Glob
---

# Ideas

An idea is the user's own, not settled and not owed to anyone: something to try, build, change or start. It
lives in `<scope>/ideas/` (private; the Overview scope holds ideas that span projects or need a new one) with
`status: new | exploring | shelved | done` (done = it turned into something). The CLI is `kb`.

```
## The idea       what it is and why it might matter, in the user's words
## Brainstorm     - thoughts, options, pros and cons, links to what bears on it
## Open questions - [ ] what has to be answered before it can go anywhere
## Next steps     - [ ] small things that would move it forward
## Turned into    - <section>: <entry id or work item> — what came out of it
```

`kb idea note <id> --kind thought|question|step|turned --text "…"` adds a line (a first thought moves it to
exploring); `kb idea status <id> <status>`; `kb idea list [--all] [--all-projects]`. Edit the file for anything
else, such as rewriting The idea when it has sharpened.

## Writing one down

`kb new idea --scope <scope> --title "<the idea, ≤10 words>" --summary "<one line>" --body "<The idea text>"`. Use
the scope it belongs to; the Overview scope when it spans projects or could become a project of its own.

## `brainstorm <id>`

Think it through *with* the user; don't run off and design it. Read the file, then look for what bears on it:
`kb search`, related decisions and facts, the code of the scope's repo, open backlog items. Then, in a few lines:
what's promising, what's risky or already decided against, and the one or two questions that matter most, asked
with a choices block when there are clear options. Write down as you go: thoughts and options worth keeping as
`thought`, what's unanswered as `question`, concrete moves as `step`. Keep each line short. When the user's
answers settle something, tick the question in the file and note the answer as a thought.

## `turn <id> <backlog | fact | decision | followup | architecture | project>`

The user wants it to become something. Read the file and draft from it:

- **backlog, fact, decision, followup, architecture:** propose each for approval, linked back to the idea:
  `kb inbox add --scope <scope> --section <backlog|facts|decisions|followups|architecture> --proposed-by <id>
  --source <id> --title "…" --summary "…" --reason "<one line>" --body "…"` (backlog items: Description and
  Acceptance criteria, sized so one person can finish one in a sprint; use the mindmill:work-item skill's conventions
  when the scope has a tracker, `--field parent=<n>` for a parent the idea names and `related` for siblings). Check `kb search` first so nothing is proposed twice. Show the list and ask
  whether it's right before adding when there are more than three.
- **project:** a new KB project. Ask with choices for what you can't tell: its name, whether it has a repo yet
  (a local path), and its scopes. Then `kb project add --id <slug> --title "<name>"`, `kb scope add --project
  <slug> --id <slug> --title "<name>" [--paths <repo>]` for each scope, move the idea into it with
  `kb move <id> --project <new scope>`, and offer to brainstorm its first backlog items there.

Then `kb idea note <id> --kind turned --text "<section>: <id> — <title>"` for each, and `kb idea status <id> done`
when what the idea was about is fully covered (ask when only part is). Reply with what you proposed and where
to approve it (Inbox, or Backlog → Suggested backlog items).

## Rules

- Nothing is created outside the KB (work items, repos, messages) without the user's yes.
- Shared things never name KB ids or local paths.
