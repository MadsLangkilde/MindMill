# How the app talks to Claude

The app never calls a model API itself. For anything that needs Claude (meeting prep, live meeting
flags, filing, the morning routine), it runs the user's own `claude` CLI headless, with this plugin
loaded. Everything Claude produces lands as files in the knowledge base, which the app already watches.
So the app's job is to send text, show short replies, and present files for approval.

## Starting a session

```
claude -p --input-format stream-json --output-format stream-json --verbose \
  --session-id <uuid the app generates> \
  --plugin-dir <plugin root> \
  --append-system-prompt "<mode prompt, below>" \
  --allowedTools "Bash(kb:*) Bash(python3:*) Read Grep Glob Write Edit mcp__claude_ai_Microsoft_365__outlook_calendar_search mcp__claude_ai_Microsoft_365__teams_list_chats mcp__claude_ai_Microsoft_365__chat_message_search mcp__claude_ai_Microsoft_365__outlook_email_search mcp__claude_ai_Microsoft_365__read_resource"
```

- **Working directory:** the project's first `paths` entry from `kb.json` (`~` expanded). For a project
  without paths, use the KB root. Claude then sees the code and the session-start KB index.
- **`--plugin-dir`:** the plugin root is the parent of the app's `macos/` folder in development. Make it a
  setting (default `~/projects/claude_plugins/kb`). If the plugin is also installed, it loads twice;
  that's harmless.
- **Model:** a setting, default `sonnet` for live meetings (latency) and the user's default otherwise.
- **`claude` binary:** resolve it through an interactive login shell (`/bin/zsh -ilc 'command -v claude'`,
  falling back to `-lc`), because GUI apps don't inherit the shell PATH and `~/.local/bin` is often added only
  in `.zshrc`. A plain login shell can find a stale npm install that lacks `--plugin-dir`.
- **One process per meeting or routine**, kept alive while its window is open. The session id is stored
  in the meeting's `session_id` field, so the user can continue in a terminal with `claude --resume <id>`.

## Messages

Send one JSON object per line on stdin:

```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"…"}]}}
```

Read JSON lines from stdout:

- `{"type":"system","subtype":"init",…}` is emitted once per turn. Ignore it except for `session_id`.
- `{"type":"assistant","message":{"content":[{"type":"text","text":"…"}, {"type":"tool_use",…}]}}`:
  show text blocks, and show tool uses only as a subtle "working…" state.
- `{"type":"result","subtype":"success","result":"<final text>"}` ends a turn. Treat `result` as the
  turn's reply.
- Anything else (`hook_*`, `rate_limit_event`, `commands_changed`) is ignored.

Queue messages while a turn is running, and send them in order. Never block typing on Claude.

MCP connectors (Outlook, Teams) connect after the first turn. Every session's first message is the
warm-up `Reply OK.`, and the mode prompts wait for their trigger word (`today`, `sync`) so the warm-up
doesn't start the work.

The `init` line carries `mcp_servers` with each server's `status`. When `claude.ai Microsoft 365` is
`needs-auth` or `failed`, the app shows a banner whose **Sign In** opens Terminal on `claude /mcp`
(choose the connector, then Authenticate) and checks again when it becomes active.

## Mode prompts (`--append-system-prompt`)

**Prepare** (`prepare <meeting id>`):
> You are preparing the meeting `<id>` with the user, using the kb:meeting skill's Prepare phase.
> The meeting file exists with `status: prepared`. Keep `## Prep` and `## Questions` in that file up to
> date using the Edit tool. Reply in chat in at most 5 lines; the file is the deliverable.

**Live** (`live <meeting id>`):
> The user is in the meeting `<id>`, typing notes. Each message is a new note. Follow the kb:meeting skill's
> Capture phase. Reply with exactly `OK` when there is nothing worth saying. Otherwise reply with at
> most two lines, each starting with `⚠` (conflicts with a decision or the code) or `ℹ` (already decided,
> or open since an earlier meeting), citing entry ids. When a note answers one of the meeting's
> `## Questions`, add a line `ANSWERED: <the question text exactly as written>`. Never edit files during
> the live phase.

**Review** (sent as a user message when the user presses Done, in the same live session):
> The meeting is over. Run the kb:meeting skill's Summarize phase with the raw notes in the meeting file.
> Write `## Summary` into the meeting file and set `status: review`. Do not ask for approval in chat.
> Write every proposed decision, fact and follow-up as an inbox entry (`kb inbox add …`) with
> `proposed_by: <meeting id>`, and every proposed PBI or bug as a backlog entry with
> `source: [<meeting id>]`. Then reply with one line: `PROPOSED <n>`.

**Calendar** (`sync`, model `haiku`, tools `Bash(kb:*)` and `outlook_calendar_search` only): run the
`kb:calendar` skill for today and tomorrow and reply with the importer's summary line or `ERROR <reason>`.
The app runs it at launch, every 30 minutes (a setting), when the Mac wakes and from the Today header,
and runs the morning routine right after it when today has no plan yet.

**Email** (`scan`, the default model, tools `Bash(kb:*)`, `outlook_email_search`, `read_resource`): run the
`kb:email` skill and reply `EMAIL <n> proposed, <m> skipped` or `ERROR <reason>`. From the envelope button in
Today and Reminders; the morning routine scans email itself.

**Morning** (`today`):
> Run the kb:today skill for <date>. Write `daily/<date>.md`, prepare meetings as files, and put proposals
> in the inbox and the backlog. Reply with at most 5 lines.

**Session window** (`session`): the user's own task, often a skill. The prompt says it runs in the app,
that `AskUserQuestion` is unavailable (`--disallowedTools AskUserQuestion`) and choices go in a
` ```choices ` / ` ```choices multi ` block, that `/<name>` means run that skill, and that nothing leaves the
machine without the user's yes. The app reads `slash_commands` from the init line, each `tool_use` input
as a one-line step, and the result's `permission_denials` for the Allow button (which resumes the session
with the tool added to `--allowedTools`).

## What the app does with the files

- **Live meeting:** the raw notes pane is the meeting file's `## Raw notes` section. Save it at most
  every 2 s while typing (debounced), so a crash loses nothing. Flags go into the gutter next to the
  note they answered. `ANSWERED:` lines tick the matching question in the file.
- **Review:** show the meeting's `## Summary` (editable) and every inbox entry with
  `proposed_by == <meeting id>`, plus backlog entries whose `source` contains it, as cards with
  checkboxes. **File selected** runs `kb inbox approve <id>` for each ticked card and `kb inbox reject <id>`
  for each unticked one, leaves backlog entries as `proposed` (the Backlog section is where they are
  created), and sets the meeting to `status: filed`.
- **Backlog:** a **Create in <tracker>** button runs `kb backlog create <id> --yes`, which posts the item
  and writes `work_item` and `url` back. **Reject** runs `kb backlog reject <id>`.

The app runs the CLI as `python3 <plugin root>/scripts/kb.py <args>`. Its exit code and stderr are what to
show on failure.
