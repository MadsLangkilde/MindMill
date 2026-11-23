---
name: goals
description: Coach the user toward their personal long-term goals (a career step such as tech lead, a skill, a habit): define what a goal takes, suggest small concrete steps that fit their everyday work, and log progress. Use for "I want to become …", "set a goal", "how am I doing on my goal", "suggest next steps for my goal", "log that I …", and when the Mindmill app's goal coach starts it.
allowed-tools: Bash(kb:*), Bash(python3:*), Read, Grep, Glob, Edit, Write, mcp__claude_ai_Microsoft_365__outlook_calendar_search, mcp__claude_ai_Microsoft_365__chat_message_search
---

# Personal goals

The CLI is `kb` (or `"${CLAUDE_PLUGIN_ROOT}/bin/kb"`). Goals live in `goals/<slug>.md` at the KB root. They
are the user's own, not a project's:

```markdown
---
title: Become a tech lead
status: active          # active | paused | achieved | dropped
horizon: by end of 2027 # in the user's words
created: 2026-11-09
---
## Why
## What it takes        # the concrete competencies or evidence, as a list
## Suggestions          # - [ ] small next steps; the user ticks them
## Proposed progress    # - YYYY-MM-DD: what the user did that may count; they add or dismiss it in the app
## Progress             # - YYYY-MM-DD: what happened, newest first
```

**A goal is a side agenda.** It shapes how the user does the work they already have; it never adds a
second job. Everything here stays small, concrete and optional.

## Set up or sharpen a goal

`kb goal add --title "…" --horizon "…" --why "…"`, or edit the file. Then fill **What it takes** with 4–7
concrete items for *this* user's context. For a career level, think of scope (team → several teams →
the product), technical direction (design docs, decisions others build on), raising the bar (reviews,
quality, practices), multiplying others (mentoring, sharing knowledge), and visibility (presenting,
writing). If the company has its own career ladder, ask once whether the user can paste it; don't invent
the company's criteria.

## Suggest next steps

Look at what is already on the user's plate in the next two weeks, then find where a goal fits into it:

- upcoming meetings (`kb list --section meetings` in each project, and the calendar)
- open work items and PRs, today's and recent plans in `daily/`
- recent decisions and meetings in the KB: where the user led, where a decision has no owner
- **Progress** and ticked **Suggestions**, so you don't repeat yourself

Write 3–5 suggestions into `## Suggestions` with the Edit tool, each as
`- [ ] <action in ≤15 words>: <which "What it takes" item it serves> (<the meeting, work item or entry it rides on>)`.
Prefer steps that *ride on existing work* ("In Thursday's refinement, write up the retry upload options as
a one-page decision note") over new projects. Remove unticked suggestions older than three weeks; keep
ticked ones.

## Log progress

When the user says they did something toward a goal, or a filed meeting or decision shows they led
something, `kb goal log <id> "<what happened, with the entry id>"`. Log what the user confirms; propose
the rest in one line.

## Find progress

Look for what the user did that counts toward an active goal, since the goal's `last looked for progress`
date in `kb goal list` (or its newest Progress line; at most 14 days back):

- pull requests they completed (`kb pr done --json`) and reviewed, work items they resolved (`kb tracker mine`)
- meetings filed in the KB where they presented, led or decided something; decisions they recorded
- ticked items in recent `daily/` plans, and ticked **Suggestions**
- discussions they settled, references or architecture notes they wrote

Propose each with `kb goal propose <id> "<what they did, ≤15 words> (<PR, work item or entry it shows in>)" --date
<when>`. It lands under **Proposed progress**, where the user adds it to Progress (editing it first if they like)
or dismisses it. Only what shows a "What it takes" item, at most 3 per goal per run, and nothing already in
Progress. When nothing fits, run `kb goal scanned <id>`. Never `kb goal log` it yourself.

## Elsewhere (light touch)

- **Morning routine:** at most one `## Side goal` line in the day plan, and Find progress for each active goal
  that wasn't looked at today.
- **Meeting prep:** at most one `**Side goal:**` line in `## Prep`.
- **Session briefs:** at most one closing line.
- **Never** during a live meeting, never as a reason to change a task, and silence when nothing fits.

## In the Mindmill app

The goal's coach chat sends `Suggest next steps` for its button: run the section above and reply with at most
5 lines. `Find progress` runs Find progress for that goal; reply with at most 3 lines on what you proposed. Other messages are coaching questions; answer them briefly and concretely, citing what you used.
