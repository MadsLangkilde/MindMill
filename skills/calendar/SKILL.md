---
name: calendar
description: Mirror the user's Outlook calendar into the knowledge base as meeting files, so new, moved and cancelled meetings show up in the Mindmill app. Use for "sync my calendar", "update my meetings", from the morning routine, and when the Mindmill app's calendar sync starts it.
allowed-tools: Bash(kb:*), mcp__claude_ai_Microsoft_365__outlook_calendar_search
---

# Sync the calendar

The CLI is `kb` (or `"${CLAUDE_PLUGIN_ROOT}/bin/kb"`). The window is the dates you were given, or today and
tomorrow.

1. Call `outlook_calendar_search` with `query: "*"`, `afterDateTime: <from>T00:00`,
   `beforeDateTime: <day after to>T00:00`, `limit: 25`, `order: "oldest"`, `offset: 0`. While the response
   ends with a `nextOffset`, call it again with that offset.
2. If the tool is missing, needs sign-in or returns an error, **stop**. Don't run `kb`, since an empty import
   would mark meetings cancelled. Reply `ERROR <the reason>` and, when it needs sign-in, add: "Run `/mcp` and
   authenticate claude.ai Microsoft 365."
3. Pipe the events into the importer with these fields only, values copied exactly from the tool:
   `id`, `subject`, `start`, `end`, `organizerName`, `namedAttendees` as `[{"name": "…"}]`, `location`,
   `summary`, `isAllDay`, `isCancelled`, `webLink`. **Leave out every email address** (`organizer`,
   `attendees`, the `address` of each attendee): the KB stores names only, and a privacy hook may refuse a
   command that contains the user's address.

   ```sh
   kb calendar import --from <from> --to <to> <<'JSON'
   {"events": [{"id": "…", "subject": "…", "start": {"dateTime": "…"}, "end": {"dateTime": "…"}, "organizerName": "…", "namedAttendees": [{"name": "…"}], "location": "…", "summary": "…", "isAllDay": false, "isCancelled": false, "webLink": "…"}]}
   JSON
   ```

   If a hook still refuses the command, reply `ERROR <the hook's reason>`; don't try to get around it.

4. Reply with the first line `kb` printed (`calendar: 2 new, 1 updated, …`) and nothing else.

What the importer does (`docs/format.md`, *Calendar*): new events become `status: scheduled` meeting files in
the project matched by an earlier meeting in the series, then `conventions.meeting_hints`, then the default
project (marked `project_guessed`). It updates times, attendees and title when they change, marks
cancelled or vanished events `cancelled`, never touches a meeting that has notes, and removes past
mirrors that were never prepared or held. Lunch, focus blocks and all-day events are skipped (`calendar.json`
in the KB root: `ignore`, `default_project`).
