# Engine host: a desktop shell talking to the shared engine

On the Mac, the engine (`MindmillEngine` in KBEngine, `core/`) runs inside the SwiftUI app. On Windows it runs in its
own process, `mindmill-engine.exe` (`~/projects/mindmill-windows/engine`), and the WinUI shell
(`~/projects/mindmill-windows/src`) is its client. This file is the contract between them. Everything in
[remote-api.md](remote-api.md) applies; this file adds what a desktop shell needs.

## Finding and starting the engine

- The engine writes `engine.json` in its data folder when it listens: `%APPDATA%\Mindmill\engine.json` (macOS:
  `~/Library/Application Support/KB/engine.json`; `MINDMILL_DATA` or `--data` moves the folder):
  `{"port": 51234, "token": "<32 random bytes, hex>", "pid": 4321, "version": 1}`. Only the user can read it. The
  engine removes it when it stops. A file with a `version` newer than the shell knows means: update the shell.
- The shell reads it. When there is no file, the pid isn't running or the port doesn't answer, it starts
  `mindmill-engine.exe` (next to the shell's exe) with `--parent <shell pid>` and waits up to 10 s for the file.
- Command line: `mindmill-engine [--kb <folder>] [--parent <pid>] [--port <n>] [--data <folder>] [--plugin <folder>]
  [--claude <path>] [--stay] [--phones]`. `--kb` defaults to `KB_ROOT`, else kb's config (`~/.config/kb/config.json`); `--port 0`
  (default) takes a free port; `--plugin` defaults to the plugin chosen in Settings, else `plugin\` next to the exe;
  `--claude` (or `MINDMILL_CLAUDE`) runs that executable instead of the `claude` found on PATH (tests use a stub);
  `--stay` never exits for being idle (development); `--phones` turns phone access on.
- **Staying alive.** The engine exits 5 s after the last desktop client left, unless `desktop.keepWorkingInBackground`
  is on (factories and phones keep working; the shell keeps its notification-area icon). Started with `--parent`, it
  also exits when no shell connected within 30 s, and when that pid is gone and no desktop client is connected.
- **Several shells.** The shell is single-instance (a second launch activates the first window). Should two shells
  connect anyway, both get every event and may call everything; the engine's `platform.*` requests go to the shell
  that said `hello` last. `--parent` only matters for the start-up grace and the exit check above.

## Connection

- Plain WebSocket on `127.0.0.1:<port>` only, path `/` (or `/desktop`), no TLS: the token keeps other local users out.
- First message: `hello` with `{"token": "<engine.json token>", "client": "desktop", "platform": "windows"}`. The
  answer is the remote-api `hello` result plus `"desktop": true` and `"services": [...]`, the platform services the
  engine may ask for (below). A wrong token, or a desktop hello on a phone connection, answers `unauthorized`.
- Phones reach the engine through the shell (see [Phones on Windows](#phones-on-windows-the-shells-tls-front)).

## What a desktop client may call

All remote-api methods and actions, plus these (desktop clients only):

| Method | Params | Result |
|---|---|---|
| `desktop.state` | | `mode` (plan/build), `scope`, `scopes[]` (as `hello`), `notice?`, `needsYou` `{count, items[]}`, `factories[]`, `loadError?` (the knowledge base didn't load: show it and offer to pick another folder) |
| `desktop.mode` | `mode` (plan/build) | `mode`; also sends `desktop.state` to the shells |
| `desktop.scope` | `scope` | `scope`: makes it the engine's current scope (as `project.select`, without speech) |
| `desktop.tools` | `refresh?` (true: look again, after the user installed something) | `claude{found, path?, signedIn?, account?, problem?}`, `git{found, path?, problem?}`, `python{found, path?, problem?}`, `plugin{found, path}`, `knowledgeBase{path, loaded, problem?}`, `ready` (everything there and signed in). Onboarding shows each with its `problem` |
| `settings.get` | `key?` | all keys below as an object, or `{key, value}` |
| `settings.set` | `key`, `value` (`null` resets) | `{key, value}`; `bad_params` with a message to show |
| `remote.status` | | Phone access: `enabled`, `status` (off/starting/running/waiting/failed), `reason?`, `port`, `fingerprint?`, `addresses[]`, `pairing?` `{code, expires, invite?{url, hosts[], port, fingerprint, name}}` (`invite` is null until the shell's TLS front listens), `outcome?` (`{paired: name}` or `{failed: message}`), `devices[]` `{id, name, platform?, paired, lastSeen?, connected, push}` (dates ISO 8601) |
| `remote.pairing.show` | | as `remote.status`, with a new 6-digit code; turns phone access on when it was off. Show `invite.url` as the QR code |
| `remote.pairing.hide` | | as `remote.status` |
| `remote.device.rename` | `id`, `name` | as `remote.status` |
| `remote.device.remove` | `id` | as `remote.status`; the phone's connection closes and its token stops working |
| `entry.save` | as in remote-api, plus `body` | `saved`, `id` |

`desktop.state` shapes:
- `needsYou.items[]` are `sessions.list` items (remote-api.md) whose `needsYou` is true; `count` is their number.
  Factory questions count in `factories[].questions`, not here.
- `factories[]` are `factories.status` items: `{id, name, status (never/running/paused/windingDown/stopped),
  progress?, maxParallel, questionsMode, tasks[]{workItem, title, session, milestone?}, questions[]{id, text,
  options[], workItem?}}`.

### Settings keys

The engine keeps these in its preferences; the shell reads and writes them with `settings.get`/`settings.set`. Every
other setting (AI, voice, meetings, general) is the `settings.*` actions, as on the phone.

| Key | Type (unset) | What |
|---|---|---|
| `desktop.keepWorkingInBackground` | bool (false) | The engine keeps running without a window (see Staying alive) |
| `desktop.startAtLogin` | bool (false) | Remembered for the shell. **The shell owns start-at-login**: it writes and removes the `HKCU\…\Run` entry itself and stores its choice here |
| `desktop.toasts` | bool (true) | The shell shows `platform.notify` as toasts; off: notices only |
| `desktop.onboardingDone` | bool (false) | The first-run setup was finished or skipped |
| `knowledgeBase.path` | string | The knowledge base folder. Setting it creates the folder when missing, saves it in kb's config (unless the engine was started with `--kb`), reloads and sends `projects.changed` and `index.changed` |
| `remote.enabled` | bool (false) | Phone access; turning it on makes the engine ask the shell for `platform.phones.listen` |
| `remote.port` | int (7878) | The phones' port |
| `user.name` | string | The user's name, for whose follow-ups are whose |
| `plugin.path` | string | A plugin folder of the user's own (`scripts/kb.py`); unset: the one next to the exe |

## Events

All remote-api events, plus:

| Event | Data | What the shell does |
|---|---|---|
| `desktop.notice` | `text` | Shows it in the notice bar |
| `desktop.needsYou` | `count`, `items[]` (as in `desktop.state`) | Updates the badge; sent when the set of waiting items changes |
| `desktop.state` | as the `desktop.state` result | Sent after `desktop.mode` and the `app.mode` action |
| `desktop.show` | `screen`, `id?` | Comes to the front on that screen: `app.show`'s screens (remote-api.md, Navigation), said to voice or a phone |
| `remote.changed` | as `remote.status` | Refreshes Settings → Phones (a phone paired, connected, a code expired) |

## Platform services: the engine calls the shell

The connection is two-way: the engine sends requests (`{"id", "method", "params"}`) to the shell and the shell
answers (`{"id", "result"}` or `{"id", "error"}`), exactly like the other direction. Ids from the engine start with
`e`. A service the shell can't give answers `unavailable` with a message; with no shell connected the engine treats
every service as unavailable and falls back (no voice on this PC, notifications only to phones). The engine gives up
waiting after 30 s (`platform.pickFolder`: 10 minutes).

| Method | Params | Result / events |
|---|---|---|
| `platform.speech.start` | `language` (`auto` or a BCP-47 tag), `mode` (dictation/conversation), `aec` (bool) | `{}`; then events from the shell: `platform.speech.partial` `{text}`, `platform.speech.final` `{text}`, `platform.speech.level` `{rms}` (0–1, for barge-in), `platform.speech.error` `{message}` |
| `platform.speech.stop` | | `{}` |
| `platform.speak` | `text`, `id`, `voice?` (a `platform.voices` id), `rate?` (0.5–2) | `{}`; event `platform.speak.done` `{id, interrupted}` once it finished or was stopped |
| `platform.speak.stop` | | `{}`; every queued `platform.speak` reports done with `interrupted: true` |
| `platform.voices` | | `voices[]`: `{id, name, language, natural}`. The engine asks once after each `hello` |
| `platform.audio.capture` | `source` (system/microphone/both), `on`, `meeting?` | `{}`; while on, microphone speech comes as `platform.transcript` events `{source, text, final, at}` (`at` ISO 8601) and computer audio as `audio` binary frames (below) |
| `platform.screen.text` | `display?`: `"all"` (default: every display, primary first, separated by a blank line), `"primary"`, or a 1-based display number as a string | `{text}`: OCR of the screen, for the meeting companion |
| `platform.notify` | `title`, `body`, `action?` | `{}`: a toast. Clicking it sends `platform.notify.clicked` `{action}` and the shell itself comes to the front on the action's screen |
| `platform.pickFolder` | `title` | `{path}` or `{cancelled: true}` |
| `platform.open` | `url` or `path` | `{}`: in the default browser or app |
| `platform.phones.listen` | `port` | `{fingerprint}` (SHA-256 of the certificate's DER bytes, lower-case hex) once the TLS front listens; an error (port taken) makes the engine retry later. See below |
| `platform.phones.stop` | | `{}`: stop the TLS front and close the phones' connections |
| `platform.network.addresses` | | `{addresses[], tailscaleName?}`: every address a phone may reach this PC on, best first (private LAN, then Tailscale 100.64.0.0/10, then the MagicDNS name), for the pairing invite |

Events the shell sends without being asked: `platform.network.changed` `{key, up}` whenever the network changes (`key`
differs per network state, e.g. the joined list of addresses; `up` false without any network). The engine then asks
for addresses again and restarts phone access when it was waiting.

**Toast actions.** `action` is `<screen>` or `<screen>:<id>`, with the screens of `app.show` (remote-api.md,
Navigation): `session:<session id>`, `factory:<factory id>`, `meeting:<entry id>`, `review`, `facts`. The id is
everything after the first colon. On a click the shell shows that screen (as for `desktop.show`) and sends
`platform.notify.clicked`.

### Voice on the desktop

The Voice screen is a client of the **same `voice.*` methods as a phone** (remote-api.md, Voice), so every client
talks to the engine's voice brain one way:
- **Keyless:** the shell recognises speech with Windows recognition, sends `voice.say`, speaks the `voice.sentence`
  events with Windows synthesis, and calls `voice.interrupt` when the user talks over it (barge-in with its own
  echo-cancelled capture).
- **API engine:** the shell streams microphone audio as `voice` binary frames with `format: "pcm24k"` (24 kHz mono
  PCM16; the engine resamples by the header, phones send `pcm16k`) and plays the `pcm24k` frames that come back.

`platform.speech.*` and `platform.speak` are for speech the engine starts by itself, without the Voice screen (none
yet; reserved for spoken pings and a hands-free start). **One owner of the microphone at a time:** while the Voice
screen has a conversation, or a meeting captures the microphone, the shell answers `platform.speech.start` with
`unavailable` ("The microphone is in use"); the engine never starts `platform.speech.*` while a desktop client owns a
voice conversation.

### Meeting audio on Windows

Windows recognition only listens to the default microphone, so for a meeting the shell transcribes the microphone
itself (`platform.transcript` events, `source: microphone`) and sends the computer's sound as binary frames
`{"kind": "audio", "source": "system", "format": "pcm16k", "seq": n}` (16 kHz mono PCM16, ~40 ms each, `seq` from 0
per capture). The engine transcribes those with the realtime API's transcription when a voice API key is set, and
otherwise declines computer audio: it then never asks for `source: system`/`both` and says "Computer audio needs a
voice API key on Windows". **Today meetings don't run in the engine on Windows** (they are still in the Mac app), so
`meeting.*` methods and `meeting.mac.*` actions answer `unavailable`, the engine doesn't ask for
`platform.audio.capture`, and it drops `audio` frames.

### Deliveries for a Windows client

A desktop client gets every `test.delivery` and `review.card` broadcast, whatever their `platform`: it shows them
(the review card's actions, a preview with `preview.get`, a `url` in the browser) but never installs an `apk` or
`testflight` build; offer "Send to phone" instead: `test.send` `{delivery}` sends the delivery again to the phones of its
platform, with a push (remote-api.md, Testing and deliveries); for a review card, `review.respond` with `action: install`. iOS builds, simulators and TestFlight need a Mac: on Windows the
Test menu shows them as unavailable with the compatibility check's reason. Test delivery runs in the engine: on Windows it
builds and delivers Android (APK through Git Bash and `./gradlew`), web (a dev server and its URL), backend,
embedded and desktop targets (previews); iPhone targets show `unavailable` in `test.status` (the reason, with the
compatibility check's finding) and their deliveries fail with it. Web pages get no screenshot on Windows yet.

### Secrets

Secrets (voice API keys, the phones' TLS identity's password) never cross the socket. On Windows they are generic
credentials in the Credential Manager, target `Mindmill/<name>`, the value UTF-8, user name `Mindmill`, persisted
`CRED_PERSIST_LOCAL_MACHINE`. Names: voice API keys are `voice-api/<provider>` (`openai`, `gemini`, `grok`), so the
target is **`Mindmill/voice-api/openai`**. The shell's Settings writes and deletes the key there itself (it never
reads it back except to say whether one is set); the engine reads it when a conversation starts, so no message is
needed after a change. The provider to use is the `settings.voice` action's business (`voice.config` says which).

## Phones on Windows: the shell's TLS front

A TLS server with a self-signed certificate is hard to do in Swift on Windows (no Network.framework or Security), so
the shell terminates the phones' TLS and forwards each phone's WebSocket to the engine over loopback. Pairing, `hello`,
`platform`, push and everything else stay the engine's, exactly as on the Mac (remote-api.md).

1. When phone access is on (`remote.enabled`), the engine asks the shell `platform.phones.listen` `{port}`.
2. The shell listens on all interfaces at `port` with `SslStream` and a self-signed certificate it creates once
   (RSA 2048 or ECDSA P-256, CN `Mindmill`, 10 years) and keeps in the user's certificate store
   (`CurrentUser\My`, private key not exportable). It answers `{fingerprint}`: SHA-256 of the certificate's DER bytes,
   lower-case hex, which phones pin from the pairing invite. Port taken: answer an error with a message.
3. For each phone the shell completes TLS and the phone's WebSocket upgrade (any path), then opens a WebSocket to
   `ws://127.0.0.1:<engine port>/phone` with the header `Authorization: Bearer <engine.json token>` (and, for logs,
   `X-Mindmill-Peer: <phone ip:port>`). The engine refuses `/phone` without the token (HTTP 401).
4. It relays message by message both ways: text as text, binary as binary, unchanged. When either side closes, it
   closes the other. Pings are answered on each hop by its own end.
5. `platform.phones.stop` (phone access turned off): stop listening and close every phone connection. The engine also
   closes forwarded phones it no longer accepts.
6. When the shell disconnects, phones can't reach the engine (Settings → Phones shows "waiting"); when a shell says
   `hello` again the engine asks `platform.phones.listen` again. Keep the shell running in the notification area for
   phones while the window is closed.

The invite's addresses come from `platform.network.addresses`; the engine sends `remote.changed` when the pairing
code, a phone or the listener changes.

## What runs in the engine on Windows today

Answered by the engine: `hello`/`state`, `entries.*`, `entry.get/save/new`, `inbox.*`, `facts.proposed`,
`app.structure`, `kb.run`, `projects.config.get/save`, `folders.list`, `actions.*`, the `voice.*` methods (keyless
and API, with Claude Code installed), the desktop methods above, and Build:

- **Sessions**: `sessions.list`, `session.get/send/new/archive`, `assistant.open`, `session.changed` events, and the
  session actions (`session.start/send/read/lead/stop/retry/allow/strategy/to_build/archive/delete`,
  `sessions.list`). The overview session, leads and members, grouping by work item and the crew tick run in the
  engine: Claude Code sessions' `kb crew start|send|stop|archive`, `kb factory ask|log`, `kb sync tracker|prs` and
  `kb test suggest` reach it through the crew folder. `desktop.show` `{screen: "session", id}` is sent when a session
  should come forward (a lead started from an action); `platform.notify` with `session:<id>` when one starts to
  wait on the user.
- **Strategies**: `strategies.list`, `strategy.get/save/delete/draft`.
- **Factories**: `factory.config.get/save/delete`, `factories.status`, `factory.*` actions, the loop with its rules and
  run modes; a question sends `platform.notify` (`factory:<id>`) and `desktop.state`; `desktop.state.factories` and
  `factory.changed` events.
- **Tracker and pull requests**: `tracker.items`, `backlog.list`, `workitem.get/update/search/tasks/implement`,
  `prs.list`, `pr.*`, `overview`.
- **Scans**: `scans.list`, `scan.start/stop/apply`.
- **Testing**: `test.status/download/installed/send`, `review.list/respond`, `preview.get`, `test.detect/check/
  deliver/server.stop`, `test.delivery` and `review.card` events (with `platform`).

And the actions that need only the knowledge base, the `kb` CLI, Claude Code and the current scope: knowledge and
entries (`entry.delete/move/tags/scopes/share`; `entry.ask` starts a Plan session about the entry), facts (list,
proposed, approve, decline, propose, links, `fact.link`, `fact.links.suggest`, `fact.change.*`), the quiz, follow-ups
(list, create, update, merge, duplicates, check), discussions, ideas, research and references (their Claude work runs
as Plan sessions), meetings (list, create, `calendar.upcoming`; `meeting.prepare` starts a Plan session with the
kb:prep skill), reminders and goals (with the goal coach), the day's plan (`today.*`; the morning routine, the calendar
sync and the email scan run headless Claude Code with the Microsoft 365 connector), `sync.*`, backlog proposals
(`backlog.*` with the duplicate check), `workitem.tags.align`, sprints (`sprint.*`, `work.startable`), `people.*`,
`repos.pull`, projects, `app.show`, `app.mode` and the `settings.*` actions. Still only on the Mac: meetings with
transcription (`meeting.*` methods answer `unavailable`, `meeting.mac.*` actions fail with "… isn't available on
Windows yet.").

## Realtime voice

API engines (OpenAI Realtime, Gemini Live, Grok Voice) run in the engine (`RealtimeRelay`): the shell streams
microphone audio as binary frames and plays the audio the engine sends back, as the phones do (above).
