---
name: today
description: The morning routine. Checks today's calendar, the user's work items and pull requests, the knowledge base's open follow-ups, proposals and pending decisions across all projects, then writes the day plan (daily/<date>.md), prepares today's meetings, and proposes backlog items. Use for "start my day", "morning routine", "what's on today", "plan my day", /mindmill:today, and when the Mindmill app's Run morning routine button starts it.
allowed-tools: Bash(kb:*), Bash(curl:*), Bash(git:*), Read, Grep, Glob, Write, Edit, Skill, mcp__claude_ai_Microsoft_365__outlook_calendar_search, mcp__claude_ai_Microsoft_365__outlook_email_search, mcp__claude_ai_Microsoft_365__chat_message_search, mcp__claude_ai_Microsoft_365__teams_list_chats, mcp__claude_ai_Microsoft_365__read_resource
---

# Start the day

The CLI is `kb` (or `"${CLAUDE_PLUGIN_ROOT}/bin/kb"`). The output is `daily/<YYYY-MM-DD>.md` in the KB root
(`kb today` prints the path), in the format in `${CLAUDE_PLUGIN_ROOT}/docs/format.md`. If it already
exists, update it: keep ticked items ticked, keep lines marked `[-]` (set aside as not relevant) as they are,
never add back a line the user removed, and keep the user's own lines.

This routine spans projects. **Every item names its project** (`[project-id]`), and everything it writes
into the KB goes into that project's own folders.

## 1. Gather (in parallel where you can)

| Source | What |
|---|---|
| Calendar | Run the `mindmill:calendar` skill for today and tomorrow first; it mirrors the events as meeting files. Then read today's meetings with `kb list --section meetings` per project. If it fails, say so under Questions for you and carry on. |
| Tracker, per distinct tracker in the projects' settings | Work items assigned to the user in the current sprint that aren't Done, with state; PRs where the user is a reviewer and hasn't voted; the user's own PRs with new comments or failing builds. Azure DevOps: WIQL with `@Me` and the `_apis/git/pullrequests` API, PAT from `~/.git-credentials`. |
| Sprints | `kb sprint status --json`: a tracker whose current sprint started in the last two days, or whose `state` is `ended` (no sprint after it), gets one **To decide** line: review what the previous sprint left unfinished (in Mindmill: Build → Ready to Start, or Today's sprint card), and for `ended` add the next sprint. Jira and other trackers reached through Claude: check their board's sprints the same way only if the connector is at hand. |
| KB, per project | Open follow-ups (overdue and due today first), decisions with `status: proposed` (waiting for sign-off), meetings still `prepared`/`live`/`review`, the inbox count, proposed backlog items. |
| Yesterday | `daily/<yesterday>.md`: unticked items carry over, marked `(carried)`; `[-]` lines do not. |
| Email | Run the `mindmill:email` skill: it proposes reminders for new mail that needs the user, and skips the rest. |
| Reminders | `kb reminder list`: open ones that are overdue or due today go into **Today**; count the proposed ones. |
| Goals | `kb goal list`: the user's active personal goals and their open suggestions. |
| Chat, light (the user's chat tool, `kb tools`) | Only threads that ask the user for a decision or an answer today. At most 3. |

Never write to the tracker, chat or email in this routine.

## 2. Act

- **Meetings:** for each meeting today that is still `scheduled` and worth preparing (not a stand-up the
  user hasn't prepared before), run the `mindmill:prep` skill. Keep it light; the user deepens it in the app.
- **Proposals:** follow the `mindmill:work-item` skill's "Proposing from the knowledge base". Add at most 3
  backlog proposals per project, only where the evidence is clear. Decisions or facts you notice go to
  the inbox (`kb inbox add … --proposed-by daily:<date>`).

## 3. Write the plan

```markdown
---
title: <Weekday d Month>
date: <YYYY-MM-DD>
---

## Today
- [ ] [<project>] <action, imperative, ≤12 words> (<id, ado:<n> or pr:<n>>)
- [ ] [reminder] <reminder title> (reminders/<id>)

## Meetings
- HH:MM–HH:MM [<project>] <title> → <meeting id> (prepared)

## To decide
- [<project>] <the decision, as a question> (<follow-up or decision id>)

## Side goal
- [ ] [goal] <one small action that rides on today's work> (goals/<id>)

## Proposed
- <n> backlog items, <n> inbox entries and <n> proposed reminders waiting: open the app's Inbox, Backlog and Reminders.

## Questions for you
- <only what you couldn't resolve: a meeting whose project you guessed, a missing tracker setting>
```

**Goal progress:** for each active goal whose `last looked for progress` (in `kb goal list`) is before today,
run the mindmill:goals skill's **Find progress**: what the user finished yesterday that counts goes under the goal's
Proposed progress, for them to add or dismiss in the app. It doesn't go in the plan.

**Side goal** is at most one line, and only when something already on today's plan or calendar gives a
natural chance to move toward an active goal (an open suggestion from the goal file, or a fresh one in the
same spirit). Leave the section out when nothing fits. It never goes in **Today** and never displaces it.

Order **Today** by what unblocks others first: reviews and answers people are waiting for, then due and
overdue items, then sprint work. 5–10 items; this is a plan, not a dump. Leave out empty sections.

## 4. Report

At most 5 lines: the count of items, meetings prepared, proposals made, and the single most important
thing today. In a terminal, end with the path of the plan, and offer to open it in the app (`kb open`).
