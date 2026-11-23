---
name: brief
description: Brief the user on what the project's knowledge base says about a task before work starts. Use at the start of a task (implementing a PBI or bug, a review, a design question) when the session-start KB index has entries that might bear on it, or when the user asks "what do we know about X", "any decisions on X", "brief me", "check the KB".
allowed-tools: Bash(kb list:*), Bash(kb search:*), Bash(kb show:*), Bash(kb resolve:*)
---

# Brief from the knowledge base

The CLI is `kb` (or `"${CLAUDE_PLUGIN_ROOT}/bin/kb"`).

1. Pull 2–4 key terms from the task (feature name, component, the system it touches) and run
   `kb search <term>` for each, in the session's project and its related projects. Also scan the
   session-start index by eye; titles don't always share words with the task.
2. Read every plausible hit in full (`kb show <id>`). Skip superseded decisions unless the task is about
   their history.
3. Reply with:

```
**From the KB**
- <fact or decision, ≤20 words> (<id>, <date>)
- … at most 5
**Suggestions**
- <only where an entry changes how the task should be done, ≤2 lines each>
```

Rules:
- Nothing relevant → say nothing about the KB (or "Nothing in the KB on this." when the user asked).
- Mark entries from a related project, e.g. `(product)`, so the user sees where they come from.
- If an entry looks out of date against the code, say so and offer to supersede it. Don't fix it silently.
- This is a brief, not a report: it opens the reply to the task; then do the task.
