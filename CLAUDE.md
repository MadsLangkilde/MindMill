# CLAUDE.md

The `mindmill` Claude Code plugin (skills `mindmill:*`, installed as `mindmill@mindmill`) and its macOS app,
Mindmill. The CLI, bundle id `dk.langkilde.kb` and module names stay `kb`/`KB`. See `README.md` for what it does.

## Layout

- `scripts/kb.py`: the `kb` CLI everything else calls (KB entries, tracker, PRs, crew sessions, strategies).
- `skills/`, `hooks/`, `bin/`: the plugin. `strategies/`: built-in Build strategies (read-only in the app).
- `core/`: the Swift package the Mac app and the Windows engine host share (see `core/README.md`). `KBCore` is the
  testable logic; `KBEngine` is engine work without UI behind adapter protocols (`Adapters.swift`). Foundation only:
  anything Apple-only goes behind `#if canImport(…)` or an adapter.
- `macos/`: SwiftUI macOS app (`Sources/KB`): the UI, `AppModel`, and the macOS adapters. Depends on `../core`.
- `art/mindmill-logo.svg`: the navy windmill logo both app icons come from: `macos/Scripts/make-icon.swift` draws the
  Mac icon from it; the Android app's icon is the same shapes as vector drawables. Its navy is the brand colour
  (`AppTheme.brand` on the Mac).
- The phone apps and the Windows app are separate projects: `~/projects/mindmill-android`, `~/projects/mindmill-ios`,
  `~/projects/mindmill-windows`. `docs/remote-api.md` is the contract with the phones and `docs/engine-host.md` with
  the Windows shell; a protocol change here must keep the Android and iOS apps working. Each app keeps its own logic.
- The knowledge base it manages is `~/knowledgebase` (split layout: `shared/`, private `<scope>/` folders, and team
  knowledge in each repo's `knowledgebase/`; see `kb layout show`). Never write test data there or in those repos.

## Build, test, install

- Shared code: `swift test` in `core/`. Put logic that can be tested in KBCore (or KBEngine) and cover it there.
- App: `swift build` and `swift test` in `macos/`.
- CLI: `python3 -m unittest tests.test_kb` from the repo root.
- Install only when the user says "install", and only while Mindmill is closed (`pgrep -fl "Applications/(Mindmill|KB).app"`):
  `./build.sh --install` in `macos/`, then confirm with
  `cmp build/Mindmill.app/Contents/MacOS/Mindmill ~/Applications/Mindmill.app/Contents/MacOS/Mindmill`.
- Commit or push only when asked.

## UI rules (the user's, non-negotiable)

- Nothing is ever cut off or squeezed at any width. Pill and chip rows wrap whole pills (`ChipRow`/`FlowLayout`),
  never scroll sideways. Cards decide by their own width (`AdaptiveCardLayout`), never a fixed threshold.
  Check every view at ~350 pt wide.
- Lists and their empty states are top-aligned (`ListEmptyState`), never vertically centred.
- Nothing floats over content: no overlay bars or toasts. Bars go in the layout; messages go in `NoticeBar`.
- Keep session rows clean: actions go in the session header beside Strategy, in the same plain menu style.

## Writing

- KB ids and local paths never go into shared items (PBIs, PRs, replies).
- No comments that restate code.
