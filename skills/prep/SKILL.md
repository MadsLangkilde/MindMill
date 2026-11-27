---
name: prep
description: Prepare a meeting: find it in the calendar, look back at earlier meetings in the series and everything since, gather what the knowledge base, the code, the tracker and recent chats and email say about its topic, and write a prepared meeting file with context and topics or questions. Use for "prepare my 10:00", "help me prepare for the retro", "what should I bring up at the planning", "prep the retry sync", from the morning routine, and when the Mindmill app's Prepare with Claude asks for it.
allowed-tools: Bash(kb:*), Bash(curl:*), Bash(git:*), Read, Grep, Glob, Write, Edit, mcp__claude_ai_Microsoft_365__outlook_calendar_search, mcp__claude_ai_Microsoft_365__outlook_email_search, mcp__claude_ai_Microsoft_365__chat_message_search, mcp__claude_ai_Microsoft_365__teams_list_chats, mcp__claude_ai_Microsoft_365__read_resource
---

# Prepare a meeting

The CLI is `kb` (or `"${CLAUDE_PLUGIN_ROOT}/bin/kb"`). The output is the meeting file with `status: prepared`.
The Mindmill app shows `## Prep`, `## Suggested questions` and `## Questions` in its meeting window. Your questions
are suggestions: the user picks the ones for the meeting into `## Questions` and marks the meeting `ready`.

## 1. Find the meeting

- **The file usually exists already.** Calendar sync creates one per event (`status: scheduled`, with
  `start`, `end`, `attendees`, `organizer`, the invite text under `## Prep`, and `previous:` set to the last
  held meeting in the series). `kb show <id>` and work in that file.
- **Not there, or at the wrong time?** The meeting may have moved since the last sync: run `kb sync calendar`
  (with `--from`/`--to` for a day more than two weeks ahead) and look again before falling back to the calendar itself.
- Otherwise, find the event in the user's calendar, the one `kb tools` names (Microsoft 365: `outlook_calendar_search`), today or on the date given, or work from the
  user's description, and create the file (step 5).

## 2. Which project?

Keep the file's project unless it says `project_guessed: true` and the topic clearly belongs elsewhere.
Then say so in one line and suggest `kb move <id> --project <p>`; don't move it yourself from the app.
Topics spanning several areas belong to the Overview scope (e.g. `product`).

## 3. Look back

The best preparation is what happened since last time.

- **The previous meeting in the series** (`previous:` in the file, or `kb search` on the title): its summary,
  decisions, and the follow-ups it raised (`kb list --section followups`, `raised_in` = that meeting).
  Which action items are done, which are still open, and who owns them.
- **Since that date:** decisions, meetings and facts recorded in the project
  (`kb list --section decisions|meetings`), the daily plans in `daily/` (carried-over items show friction),
  and the inbox.
- **Tracker** (settings `tracker`): work items and PRs on the topic. For sprint ceremonies, the sprint itself.
- **Code:** what exists today for the topic, in a line or two. `git log --since=<previous date>` in the
  project's repo for what shipped.
- **Chat and email** (the user's tools, `kb tools`): threads on the topic or with the organizer since the previous meeting; at most 3,
  one line each.

## 4. Shape it by the kind of meeting

| Kind (from the title and invite) | Prep gathers | `## Suggested questions` holds |
|---|---|---|
| Retrospective | Sprint outcome: committed vs done, carried over, bugs found and escaped, PRs that sat long, incidents, releases; last retro's action items and whether they happened; recurring friction from daily plans | Topics grouped under `### Went well`, `### To improve`, `### Last retro's actions`, each a checkbox the user can raise, with the evidence in a few words |
| Sprint planning | Carry-over, the candidate items with state and estimate, capacity notes, open dependencies and blockers | Scope questions and risks per item |
| Refinement / estimation | The items on the agenda, their open questions, related decisions and code | Questions that would change the estimate |
| Stand-up | Your items since yesterday, blockers, PRs waiting on others | Keep it to 2–4 points: yesterday, today, blocked |
| 1:1 | Open follow-ups with that person, recent work together, anything from the user's notes | Topics to raise |
| Design / decision meeting, everything else | Decisions in force, the open questions, code today | Questions aimed at a decision or an unknown, most outcome-changing first |

Leave **Side goal** out when nothing fits, and never turn a goal into a topic or question of its own.

Cite KB ids and work items next to the line they come from. Aim for 4–10 checkboxes; skimmable, no
preamble. Build on what the user already wrote: never remove or reword their lines.

## 5. Write the file

Update the existing file with the Edit tool: replace `## Prep`, merge into `## Suggested questions` (never into
`## Questions`, which holds what the user picked or wrote; skip suggestions already there), leave
`## Raw notes` alone, and set `status: prepared` (never `ready`, which only the user sets). Without a file:

```sh
kb new meeting --project <p> --title "<title>" --date <date> --status prepared \
  --attendees "<a, b>" --field start=HH:MM --field end=HH:MM --body-stdin
```

Body:

```markdown
## Prep
- **Goal:** <what has to come out of this meeting, one line>
- **Last time:** <previous meeting id, the one or two outcomes that matter>
- **Since then:** <what changed, ≤3 bullets with ids>
- **In force:** <decision ids that constrain this, ≤10 words each>
- **Open:** <follow-up ids still open, with owners>
- **Work items:** <PBIs and bugs on the topic, `#<number> <title> (<state>)`, from `kb tracker items --search`; ≤5>
- **Side goal:** <only if an active goal (`kb goal list`) fits this meeting naturally: one line on how>

## Suggested questions
### <group>
- [ ] <topic or question; cite ids>

## Questions

## Raw notes
```

## 6. Report

One line per meeting: `Prepared <id>, <n> topics`. Plus anything that needs the user before the meeting
starts: a conflicting decision, a missing owner, a guessed project.
