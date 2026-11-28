---
name: calendar
description: Mirror the user's calendar (Outlook, Google Calendar or another calendar connector) into the knowledge base as meeting files, so new, moved and cancelled meetings show up in the Mindmill app. Use for "sync my calendar", "update my meetings", from the morning routine, and when the Mindmill app's calendar sync starts it.
allowed-tools: Bash(kb:*), mcp__claude_ai_Microsoft_365__outlook_calendar_search, mcp__claude_ai_Google_Calendar
---

# Sync the calendar

The CLI is `kb` (or `"${CLAUDE_PLUGIN_ROOT}/bin/kb"`). The window is the dates you were given, or today and
tomorrow.

**Which calendar.** The Mindmill app tells you which connector to read. Without that, `kb tools` says which calendar
the user uses; read that one, never another that happens to be connected. When neither says, reply
`ERROR No calendar is set in Mindmill. Choose one in Settings → Connections.`
Only ever read the calendar: never create, change, accept or decline an event.

1. Fetch every event in the window:
   - **claude.ai Microsoft 365** (Outlook): call `outlook_calendar_search` with `query: "*"`,
     `afterDateTime: <from>T00:00`, `beforeDateTime: <day after to>T00:00`, `limit: 25`, `order: "oldest"`,
     `offset: 0`. While the response ends with a `nextOffset`, call it again with that offset.
   - **Any other calendar** (Google Calendar or another connector): use its tool that lists or searches events,
     for the primary calendar, from `<from>` 00:00 to the day after `<to>` 00:00 in the user's time zone, with
     recurring events expanded into single occurrences. Follow its paging until there are no more.
2. If the tool is missing, needs sign-in or returns an error, **stop**. Don't run `kb`, since an empty import
   would mark meetings cancelled. Reply `ERROR <the reason>` and, when it needs sign-in, add: "Run `/mcp` and
   authenticate <the connector's name>."
3. Pipe the events into the importer. **Leave out every email address** (organizer, attendees, the `address` of
   each attendee): the KB stores names only, and a privacy hook may refuse a command that contains the user's
   address.
   - **Outlook**: these fields only, values copied exactly from the tool: `id`, `subject`, `start`, `end`,
     `organizerName`, `namedAttendees` as `[{"name": "…"}]`, `location`, `summary`, `isAllDay`, `isCancelled`,
     `webLink`.
   - **Any other calendar**: one object per event in Mindmill's own shape: `id` (the event's id, the same for
     the same occurrence every time), `title`, `start` and `end` (`YYYY-MM-DDTHH:MM` in the user's time zone, or
     `YYYY-MM-DD` for all-day), `all_day`, `cancelled`, `response` (`declined` when the user declined, else
     empty), `organizer` and `attendees` (display names; skip anyone with no name), `location`, `online_url`
     (the video link: Meet, Zoom, Teams), `calendar_url` (the link to the event), `body` (the description,
     plain text), `series` (the recurring event's id, empty for a single event).

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
