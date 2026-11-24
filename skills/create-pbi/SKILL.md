---
name: create-pbi
description: Create a PBI or bug in the project's work-item tracker, step by step (type, parent, sprint, area, assignee, tags, draft, confirm), learning the project's tracker and team as it goes. Use for /create-pbi, "create a PBI", "create a bug", "make PBIs from this follow-up".
allowed-tools: Bash(kb:*), Bash(git:*), Read, Grep, Glob, AskUserQuestion
---

# Create a PBI or bug

Follow the `mindmill:work-item` skill (`${CLAUDE_PLUGIN_ROOT}/skills/work-item/SKILL.md`) from step 1 to step 9.
Read it first. Never put KB ids, KB file paths or `kb://` links in the work item: it is shared with the team,
and the KB exists only on this machine. Describe the source in words. The arguments, if any, are the source: a KB id (a follow-up, meeting or decision), a work
item id to use as parent, or the user's own description. The backlog entry goes in the scope whose tracker
settings it uses (`--project <scope>`). When the scope's `tracker.kind` is `local` (Mindmill's own tracker,
`kb work add`) or `jira` (Claude's Jira connector), follow that skill's "Local and Jira trackers" section.
