# Mindmill for Android

The phone companion to Mindmill on the Mac. The Mac is the server; the phone talks to it over one TLS WebSocket on
the same network or over Tailscale. The contract is [`docs/remote-api.md`](../docs/remote-api.md).

## Build

Needs JDK 21 and the Android SDK (`local.properties` with `sdk.dir`, not committed).

```sh
export JAVA_HOME=$(/usr/libexec/java_home -v 21)
./gradlew assembleDebug        # app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest    # JVM unit tests
```

Kotlin, Jetpack Compose and Material 3 in one `app` module (`dk.langkilde.mindmill`), minSdk 29, targetSdk 36,
compileSdk 37 (the current AndroidX and OkHttp releases need it).

## Pairing

1. On the Mac: Settings → Remote → turn it on → Show Pairing Code.
2. On the phone: Scan the QR code (or paste the `kb://pair?…` invite under "Paste the invite instead").
3. Check the 6-digit code and tap Pair. An expired or used code says so, with Scan again.

The phone keeps the hosts, port, certificate fingerprint and device token, encrypted with an Android Keystore key.
It trusts only the Mac's certificate whose SHA-256 matches the pinned fingerprint. If the Mac removes the phone,
the app goes back to pairing. The phone never asks for, receives or stores an API key.

## Connection

`remote/ConnectionMachine.kt` decides what the phone shows (tested without a network): a quiet "Connecting to
<Mac>…" on the first try, "Retrying in Ns" with Retry now after a failure (backoff 1, 2, 4, 8, 15, 30 s), and after
four failed tries "Can't reach <Mac>" with the reason and what to check (same Wi-Fi or Tailscale, Mindmill open, Remote
on). It starts over and tries at once when the network changes or the app comes to the front. Screens wait for the
connection instead of failing; a request made while it can't reach the Mac waits a few seconds, then fails with a
sentence and Retry.

## Permissions

| Permission | For |
|---|---|
| Camera | Scanning the pairing code |
| Microphone, notifications | Voice and live meetings, kept alive with the screen off (foreground service) |
| Nearby devices (Bluetooth) | Talking through a headset or the car |
| Screen capture (asked each meeting) | Sending screenshots to the meeting notes |
| Install unknown apps | Installing test builds; the Test screen walks you through allowing it |

## Screens

A **Plan | Build** switch at the top, as on the Mac (remembered). Each mode shows the Mac's own sidebar for it, in
the user's order, from `app.structure` (a built-in copy when the Mac is older), with its counts and "needs you"
badges. **Ask Mindmill** (the sparkle) and **Voice** (the microphone) are at the top in both modes.

- **Phone**: a bottom bar with the mode's most important sections (Plan: Home, Sessions, Backlog, Meetings; Build:
  Overview, Factories, Testing, Sessions) and More for the rest. Labels shrink rather than being cut off.
- **Tablet, unfolded or landscape** (600 dp and wider): every section in a side list, under the Mac's headings.
  From 840 dp, lists (Sessions, Backlog, Meetings, Facts, Pull requests, Discussions…) open their items beside them.

- **Sessions** (Plan): every Plan conversation, however it was started (Sessions, Research, Ideas, a discussion, a
  follow-up, a meeting, a goal, an entry, Ask), grouped by kind as on the Mac, with "needs you" and running state;
  "Older · n" and "Archived · n" folded at the bottom. Archive or restore with a swipe, a long-press, or the
  session's ⋮ menu; Undo shows in the bar at the bottom. **Sessions** (Build): by project, helpers under their lead.
- **Home**: Ask Mindmill, quick actions (talk, meeting on the Mac or the phone, new session, all actions), the next
  meeting with Start on Mac, and what needs you (the Mac's `overview`).
- **Ask Mindmill**: a chat with the Mac's assistant session (`assistant.open`), which can do anything Mindmill can.
  Type or dictate; New conversation; Talk instead.
- **Backlog**: your or everyone's work items; open one to change state, assign, comment. New work item.
- **Voice**: talk to the brain, which reaches every action; action cards show what was done and its data.
- **More**:
  - **All actions**: every action of `actions.list`, by area and searchable, each with a form made from its JSON
    schema; risky ones ask first. "Every area of the Mac" lists the areas, so each is one tap away.
  - **Facts**, **Knowledge** (sections, search everything, new entries), **Discussions**, **Tags**, **People**.
  - **Follow-ups**: on you, waiting on others, or all; done, drop, note, and new ones.
  - **Meetings**: start one on the Mac (from the calendar or now) and follow it live: notes, transcription, stop,
    file. Or record on the phone. Notes and summaries by day.
  - **Factories**: status, progress, questions; start, pause, resume, stop; new, edit, duplicate and delete with
    the full editor (`factory.config.*`).
  - **Pull requests**, **Today**, **Reminders**, **Goals**, **Strategies**: from the Mac's actions, with the
    area's other actions a tap away.
  - **Test**: builds to install, links and previews to open, changes to review, and the Mac's test set-up.
  - **Connection**: the Mac, voice options, forget the Mac.

Lists pull to refresh, load with placeholders, say what to do when empty, and offer Retry when a request fails.
Finished actions say so at the bottom of the screen (in the layout, not over it); deleting asks first. If the Mac's
Mindmill is older than the phone's, screens say "Update Mindmill on the Mac".
