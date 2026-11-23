# Mindmill (macOS app)

Native macOS app (SwiftUI, macOS 14+) for browsing and editing the knowledge base described in
`../docs/format.md`. It reads and writes the Markdown files directly and watches the folder, so edits
made by Claude or another editor appear immediately.

## Build and install

```sh
./build.sh            # swift build -c release, assembles and ad-hoc signs build/Mindmill.app
./build.sh --install  # also copies it to ~/Applications/Mindmill.app and registers the kb:// scheme
swift test            # unit tests for the parser, serialiser, index, store and Markdown renderer
```

No third-party dependencies. `KBCore` (plain Swift) holds parsing, serialising, indexing, file writes,
the Markdown renderer and the FSEvents watcher; `KB` is the SwiftUI app.

## Knowledge base root

Read from `~/.config/kb/config.json` (`{"root": "~/projects/knowledge"}`); without that file the root is
`~/projects/knowledge`. Change it in Settings (⌘,), which writes the same file. For one launch you can
override it without touching the config: `open build/Mindmill.app --args --root /path/to/kb` or `KB_ROOT=/path`.

The app is project-first: pick a project at the top of the sidebar, and everything (sections, counts,
timeline, search, new entries) is limited to that project. The last project is remembered. Search covers
only the selected project unless you switch the scope to All Projects.

## Workflow

- **Today** (top of the sidebar, ⌘0) shows `daily/<date>.md` across projects: tick the checklist (written straight
  back), open meetings, step through earlier days, and **Run Morning Routine** (a headless Claude session in the KB root).
- **Inbox**, **Follow-ups** and **Backlog** are per-project sections. Approve/Reject, Mark done/Drop and
  Create in Azure DevOps/Reject run the plugin CLI (`python3 <plugin root>/scripts/kb.py …` with `KB_ROOT` set).
  Inbox entries never appear in other sections, the timeline or search.
- **Meeting mode** (⇧⌘N, or Prepare/Resume/Review on a meeting) is a separate window: Prepare with Claude, a live
  notes editor whose paragraphs go to Claude with flags in a gutter beside them, then Review and File Selected.
  Closing the window stops Claude and keeps the file; reopening a live meeting resumes the session.
- **Ask** (⌘K) answers questions about the selected project with citations, using the KB, the code and the
  knowledge sources configured per project (gear next to the project) or globally (Settings → Sources).

Claude settings (Settings → Claude): plugin root (default `~/projects/claude_plugins/kb`), the live-meeting model
(default `sonnet`) and the model for everything else (empty = your default). `claude` is found through an
interactive login shell (`zsh -ilc`), because a plain login shell can find an older install than your terminal does.

## URL scheme

- `kb://open?id=<project>/<section>/<stem>` opens that entry (and switches to its project)
- `kb://open?project=<project-id>[&section=inbox]` selects the project (and a section)
- `kb://open?id=<id>&action=edit|done|create|meeting` opens an entry and starts that action
- `kb://today[?date=YYYY-MM-DD]`, `kb://meeting?id=<meeting id>`, `kb://ask[?project=&q=]`,
  `kb://settings?project=<id>&tab=tracker|conventions|sources`, `kb://new-meeting`

## Shortcuts

⌘N new decision, ⇧⌘N new meeting, ⌘K ask, ⌘S save, ⌘E edit/preview, ⌘0 today, ⌘1–⌘5 sections, ⌘6 decisions
timeline, ⌘7 follow-ups, ⌘8 backlog, ⌘9 inbox, ⇧⌘R reveal in Finder, ⇧⌘O open in the default editor. In meeting mode
⌘↩ starts the meeting, ends it (Done) and files the review.

## Diagnostics

`KB_SNAPSHOT=/tmp/kb.png` (via `open --env`) makes the app render its own window to that PNG every two
seconds, which needs no screen-recording permission. Other windows go to `/tmp/kb-<window title>.png` and an
attached sheet to `…-sheet.png`.

For checking without a keyboard: `KB_OPEN_URL=<kb:// url>` handles that URL at launch, `KB_MODEL=haiku` overrides
both model settings, `KB_CLAUDE_LOG=<file>` appends every Claude session event to a file, and
`KB_MEETING_SCRIPT="start;type <paragraph>;wait 20;done;untick <title words>;file"` drives an opened meeting
window through the same code paths as typing.
