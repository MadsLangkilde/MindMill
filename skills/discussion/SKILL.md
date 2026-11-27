---
name: discussion
description: Track an open discussion (an email thread, a chat in Teams or Slack, a debate across meetings) in the KB until it settles, and file what it produces as facts, decisions, follow-ups or backlog items. Use for "start a discussion from this mail", "what's the state of the X discussion", "check for new replies", "file the findings", "conclude it", and when the Mindmill app's Discussions buttons send `/mindmill:discussion <action> …`.
allowed-tools: Bash(kb:*), Read, Edit, mcp__claude_ai_Microsoft_365__outlook_email_search, mcp__claude_ai_Microsoft_365__chat_message_search, mcp__claude_ai_Microsoft_365__teams_list_chats, mcp__claude_ai_Microsoft_365__read_resource
---

# Discussions

A discussion is something people are still working out: who said what, what's still open, and what was
learned along the way. It lives in `<scope>/discussions/` with `status: open | parked | concluded` and
`waiting_on: me | others | nobody` (me = the user owes an answer or a decision). It is **not** a decision: until
it concludes, nothing in it is in force. The CLI is `kb`.

The file:

```
## Summary        what is being discussed and why it matters, 2–4 lines, kept current
## Points raised  - YYYY-MM-DD · Name: the point, one line each, oldest first
## Open questions - [ ] question  (tick with [x] when answered, and say the answer in Points raised)
## Findings       - something learned that is worth keeping beyond the discussion
## Outcome        what was settled, written when it concludes
```

Frontmatter: `title`, `date` (started), `updated`, `status`, `waiting_on`, `people` (names only, never email
addresses), `channel` (email | teams | slack | meeting | other), `thread` (the email conversation id or the chat
id, to find replies), `link` (the mail or chat web link), `summary`, `scopes`.

The app sends one of these. `<id>` is the discussion's entry id.

## `start <scope> <what to look for>`

1. Find the thread in the user's mail tool (and their chat tool when it sounds like a chat), the ones `kb tools`
   names (Microsoft 365: `outlook_email_search`, `chat_message_search`), with the words given. If several threads match, ask the user which one with choices; if none, say so and stop.
2. Check `kb discussion list --all-projects --json` for one with the same `thread`; if it exists, do `refresh`
   on it instead.
3. Read the messages (in full when the preview isn't enough) and create it:
   `kb new discussion --scope <scope> --title "<the question being discussed, ≤10 words>" --summary "<one line>"
   --field channel=email --field thread=<conversation id> --field link=<webLink> --field "people=[Ana B, Bo C]"
   --field waiting_on=<me|others|nobody> --body "<Summary text>"`. The user picked the scope in the app, so
   add `--cross-project` when the CLI refuses because the session sits in another scope.
4. Add each substantive point, oldest first: `kb discussion note <id> --who "<name>" --date <day> --text "<point>"`.
   Skip greetings, thanks and quoted history. Open questions: `--kind question`. Findings: `--kind finding`.
5. Reply in 3–5 lines: what it's about, where it stands, who it waits on. Offer `file` when there are findings.

## `refresh <id>`

Read the file. Search the thread (`thread` / `link`, or the title's words) for messages after `updated`. Add
the new points, tick answered questions, add findings, update the Summary when the picture changed (edit the
file), and set `--waiting-on`. Reply with what's new in ≤5 lines, or "No new replies since <date>."

## `work <id>`

The user wants to think it through with you. Read the file, `kb show` the entries it touches, and anything in the
KB or code that bears on the open questions. Say where it stands, what's still open, and propose next steps or a
reply. Draft a reply only when asked, and don't send anything. Record what the user decides here with
`kb discussion note`.

## `file <id>`

Turn the Findings, answered questions and anything settled into KB entries **proposed for approval**, so the
user approves each in the Inbox:

- a stable truth about the product, an API or a person's role: `--section facts`
- something agreed that changes how the team works or builds: `--section decisions`
- something someone must do or answer: `--section followups`
- work for the backlog: `--section backlog` (with `--field parent=<n>` when a parent work item is named, and
  `related` for items proposed together, as in the mindmill:work-item skill)

```sh
kb inbox add --scope <scope> --section facts --proposed-by <id> --source <id> --title "…" --summary "…" \
  --reason "<why it's worth keeping, one line>" --body "…"
```

Pick the scope the finding belongs to (it may differ from the discussion's; add `--cross-project` then) and
add `--scopes` when it touches more than one. Check first that the KB doesn't already hold it (`kb search …`); when it does but
says something else, flag it with `kb fact challenge` instead. Don't file opinions nobody agreed on. Then mark
each filed finding in the file: `- <finding> → <inbox id>`. Reply with the list of what you proposed.

## `conclude <id> [outcome]`

When the outcome isn't given, propose one from the file and ask the user to confirm it with choices. Then
`kb discussion status <id> concluded --outcome "<what was settled>"`, and offer `file` for anything not filed yet.

## Rules

- Names only, never email addresses, in any file or command. A privacy hook may refuse a command with the
  user's address; don't get around it.
- Shared things (work items, PRs, mail) never name KB ids or local paths.
- Nothing is sent, posted or created outside the KB without the user's yes.
