---
name: mindmill
description: Open, search or manage the knowledge base. Use when the user runs /mindmill, asks to be reminded of something, asks to open the Mindmill app (once called the KB app), to show or find notes, decisions, facts or meetings, to add a fact or architecture note, to register a new project or link related projects, or to commit the knowledge base.
allowed-tools: Bash(kb:*)
---

# Knowledge base

The CLI is `kb` (or `"${CLAUDE_PLUGIN_ROOT}/bin/kb"`). Format: `${CLAUDE_PLUGIN_ROOT}/docs/format.md`.

| The user wants… | Do |
|---|---|
| `/mindmill` with no words, "open the KB" | `kb open --project $(kb resolve)`; if that fails, `kb open` |
| to see one entry in the app | `kb open <id>` |
| to find something | `kb search <words>` (add `--project <p>` to stay in one project), then `kb show <id>` for the best hits; answer in a few lines with ids |
| a list | `kb list [--section decisions\|facts\|meetings\|architecture] [--include-superseded]` |
| to add a fact or architecture note | `kb new fact\|architecture --title "…" --summary "…" --body-stdin` with the text on stdin |
| to record or change a decision | the `mindmill:decide` skill |
| meeting notes | the `mindmill:meeting` skill; preparing one: `mindmill:prep` |
| a question answered from all sources | the `mindmill:ask` skill |
| to start the day | the `mindmill:today` skill |
| a PBI or bug | the `mindmill:work-item` skill |
| to see or act on proposals | `kb inbox list`, `kb inbox approve\|reject <id>` |
| a fact that may no longer hold | `kb fact challenge <fact id> --by <what showed it> --question "…" [--body-stdin]`; never edit it yourself. Pending ones: `kb fact changes`; the user decides with `kb fact resolve <id> --update\|--keep\|--remove` |
| the Build-mode sessions (only inside the Mindmill app) | `kb crew status`; `kb crew send <id\|me\|lead\|overseer\|title> "…"`; `kb crew start --title "…" --under me "<brief>"`; `kb crew stop <ref>` |
| strategies for Build sessions | `kb strategy list\|show\|new\|delete` |
| a personal reminder ("remind me to…", a course to finish) | `kb reminder add --title "…" [--due YYYY-MM-DD] [--project p] [--note "…"]`; turn "tomorrow", "next week" into a date, and leave `--due` out when there is none |
| to see or tick reminders | `kb reminder list`, `kb reminder done <id>`, `kb reminder due <id> <date|none>` |
| to check email for to-dos | the `mindmill:email` skill |
| a personal long-term goal ("I want to become…"), its suggestions or progress | the `mindmill:goals` skill |
| to close a follow-up | `kb followup close <id> --status done\|dropped [--answer "…"] [--resolved-by <id>]` |
| a follow-up that only says to create a PBI or bug | `kb followup to-backlog <id>`: it becomes a suggested backlog item (follow-ups are never for that) |
| a PBI or bug whose work turned out finished (no PR will close it) | ask first, then `kb tracker resolve <id> --yes` (the type's Resolved or Done state) |
| to add a knowledge source | `kb sources add --kind <kind> --title "…" --use-for "…" --config key=value [--global]` |
| project settings (tracker, conventions) | `kb settings show\|get\|set` |
| to register this repo | `kb register --id <kebab-id> --title "<title>" --path <repo root> [--related a,b]` |
| to link projects | `kb register --id <id> --related <other ids>` |
| an entry's scopes (the parts of a project it belongs to) | `kb scopes <id>`; `kb scopes <id> --add <scope>` when it holds details for another scope; `kb new … --scopes a,b` when writing it |
| projects and scopes | `kb project list\|add`, `kb scope list\|add\|move` |
| to check consistency | `kb lint` |
| to commit | only when asked: `kb commit -m "<message>"` |

Projects stay separate: write into the session's project unless the user says otherwise, and then pass
`--cross-project`.

Edit an existing architecture note in place with the Edit tool; update its `date:` to today when the
content changed. Edit a fact in place only when the user asked for that change; otherwise challenge it. Decisions are never edited in place. Supersede them with `mindmill:decide`.
