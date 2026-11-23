# CLAUDE.md

The `kb` Claude Code plugin and its macOS app, Mindmill (the user-facing name; the CLI, plugin, skills, bundle id
`dk.langkilde.kb` and module names stay `kb`/`KB`). See `README.md` for what it does.

## Layout

- `scripts/kb.py`: the `kb` CLI everything else calls (KB entries, tracker, PRs, crew sessions, strategies).
- `skills/`, `hooks/`, `bin/`: the plugin. `strategies/`: built-in Build strategies (read-only in the app).
- `macos/`: SwiftUI macOS app. `Sources/KBCore` is the testable logic; `Sources/KB` is the UI.
- `art/mindmill-logo.png`: the 64 px PixelLab logo both app icons are built from (`macos/Scripts/make-icon.swift`,
  and the Android `mipmap-*/ic_launcher_*.png`, scaled nearest-neighbour).
- `android/`: the Mindmill phone app (Kotlin, Compose), a client of the Mac over `docs/remote-api.md`. Each app
  keeps its own logic; the protocol doc is the contract between them.
- The knowledge base it manages is `~/knowledgebase` (split layout: `shared/`, private `<scope>/` folders, and team
  knowledge in each repo's `knowledgebase/`; see `kb layout show`). Never write test data there or in those repos.

## Build, test, install

- App: `swift build` and `swift test` in `macos/`. Put logic that can be tested in KBCore and cover it there.
- CLI: `python3 -m unittest tests.test_kb` from the repo root.
- Android: `./gradlew assembleDebug testDebugUnitTest` in `android/` (JDK 21).
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
