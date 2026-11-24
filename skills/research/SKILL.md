---
name: research
description: Research something with the user and keep what is found in the KB — alone, or for a PBI, idea or discussion — then finish it with a summary, takeaways for the PBI, and facts worth keeping. Use for "research X", "look into X for #1234", "find out whether…", and when the Mindmill app's Research buttons send `/mindmill:research <action> <id>`.
allowed-tools: Bash(kb:*), Read, Edit, Grep, Glob, WebSearch, WebFetch
---

# Research

A research is the user's own digging into a question. It lives in `<scope>/research/` (private) with
`status: open | review | done | parked` and, when it is for something, `for: wi:<id>` (a PBI or bug) or the id of
an idea or discussion. The CLI is `kb`.

```
## Question        what we are trying to find out, in the user's words
## Findings        - what we found, one line each, with where it came from
## Open questions  - [ ] what is still unanswered
## Sources         - links, files, people
## Summary         written when finishing: the answer in a few lines
## Takeaways       written when finishing: one line each, fit to put on the PBI
```

Write as you go, not at the end: `kb research note <id> --kind finding|question|source --text "…"`. Keep each
line short and specific. Tick an open question in the file once it is answered and note the answer as a finding.

## `start <id>` and `continue <id>`

Read the file (`kb show <id>`). If it is for a work item, read it: `kb tracker item <n> --json`, or `kb work show <n>`
when the scope uses Mindmill's own tracker. If it is for an idea or discussion, read that entry. For `continue`, pick up
from the findings and open questions already there.

Then look where the answer is likely to be: `kb search` and related decisions and facts first (something may be
decided already), the code of the scope's repositories, then the web. Say in a few lines what you found and what you
would look at next, and ask with a choices block when the direction is the user's call. Don't design or implement
the solution; find out what is needed to decide it.

## `adopt <id>`

A conversation the user started in Build was moved here. Fill in the file from the conversation so far: the question
(only if it is empty or vague), findings, open questions and sources. Then say in two lines where it stands.

## `finish <id>`

1. Read the file. Write the summary and the takeaways in one go, which also sets the status to review:
   `kb research summary <id> --takeaway "…" --takeaway "…"` with the summary on stdin.
   - **Summary:** the answer in 2–6 lines, with what is still uncertain.
   - **Takeaways:** 2–7 lines a teammate can act on, each standing on its own. They may be added to the PBI, so
     they never name KB ids, `kb://` links or paths on this machine, and say nothing private. If the research is
     not for a PBI, write them anyway; they stay in the research.
2. Propose what is worth keeping in the KB, each linked back to the research, after `kb search` shows it isn't there:
   `kb inbox add --scope <scope> --section facts --proposed-by <id> --source <id> --title "…" --summary "…"
   --reason "<one line>" --body "…"`. Mostly facts (true now, useful later); a decision only when one was made.
   Propose nothing rather than something weak.
3. Reply in three lines: the answer, how many takeaways, how many proposals. The user picks in the app's Finish tab
   which takeaways go on the PBI and which proposals to keep; don't add anything to the PBI yourself.

## Rules

- Nothing is written to the tracker, repositories or messages from a research session. The app adds the takeaways
  the user picks (`kb tracker note`).
- Shared things never name KB ids or local paths.
