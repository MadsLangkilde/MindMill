# Mindmill remote API

The Mindmill app on a Mac can act as the server for Mindmill on a phone (Android now, iOS later). Everything the phone does goes
through the Mac: the knowledge base, the tracker, sessions, meetings and voice. Turn it on in **Settings → Remote**.

## Connection

- One WebSocket over TLS: `wss://<host>:<port>/` (port 7878 unless changed).
- The Mac uses its own self-signed certificate. The phone **pins its SHA-256 fingerprint** (hex, lower case, of the
  certificate's DER bytes) from the pairing invite and refuses any other certificate. No certificate authority is
  involved, so it works on a LAN and over Tailscale alike.
- Hosts to try, in order, come in the invite: private LAN addresses, Tailscale addresses (100.64.0.0/10), the Mac's
  Tailscale MagicDNS name and its `.local` name. Try them in order with a short timeout; keep the one that answers.

## Pairing

The Mac shows a QR code (Settings → Remote → Show Pairing Code) holding:

```
kb://pair?v=1&hosts=192.168.1.5,100.101.2.3,mac.tail1234.ts.net&port=7878&fp=<sha256 hex>&code=123456&name=<Mac name>
```

The 6-digit code is valid for 10 minutes and for one phone. The phone connects and sends `pair`:

```json
{"id": "1", "method": "pair", "params": {"code": "123456", "name": "Pixel 9"}}
```

The answer holds the device token, shown once. Store it in the phone's encrypted storage with the hosts, port and
fingerprint. Every later connection starts with `hello`:

```json
{"id": "1", "method": "hello", "params": {"token": "<device token>"}}
```

`pair` fails with `bad_code` and a message to show when the Mac shows no code, the code has expired, or it is wrong.
After five wrong codes the code stops working and the Mac shows that pairing failed; the user shows a new code. The
Mac shows "<name> paired" with the `name` the phone sent, so send the device's model name ("Pixel 10").

Removing the phone in Settings → Remote closes its connection and invalidates the token (answer `unauthorized`:
pair again). Renaming it on the Mac changes nothing for the phone.

The Mac restarts its listener by itself when it fails (port in use, no network) and when the network changes, so a
connection can drop; reconnect with `hello` and a short backoff (1 s, 2 s, 5 s, then every 10 s) while the app is open.

## Messages

JSON text frames, one message each:

| Kind | Shape |
|---|---|
| Request (phone → Mac) | `{"id": "<unique>", "method": "<name>", "params": {...}}` |
| Answer | `{"id": "<same>", "result": {...}}` |
| Failure | `{"id": "<same>", "error": {"code": "...", "message": "<for the user>"}}` |
| Event (Mac → phone) | `{"event": "<name>", "data": {...}}` |

Error codes: `unauthorized`, `bad_code`, `bad_params`, `not_found`, `unknown_method` (the Mac's Mindmill is older than
the phone's), `failed`.

Binary frames carry audio, screenshots and files: a 4-byte big-endian header length, a JSON header, then the
payload. Headers:

| Kind | Header | Payload |
|---|---|---|
| Meeting screenshot (phone → Mac) | `{"kind": "screen", "meeting": "<id>", "format": "jpeg", "seq": n}` | JPEG |
| Voice audio in (phone → Mac, API engine) | `{"kind": "voice", "conversation": "<id>", "format": "pcm16k", "seq": n}` | 16 kHz mono 16-bit little-endian PCM, ~40 ms per frame |
| Voice audio out (Mac → phone, API engine) | `{"kind": "voice", "conversation": "<id>", "format": "pcm24k", "seq": n}` | 24 kHz mono 16-bit little-endian PCM |
| File chunk (Mac → phone) | `{"kind": "file", "delivery": "<id>", "seq": n, "last": true/false}` (`seq` starts at 0) | up to 256 KB of the file |

## Methods

| Method | Params | Result |
|---|---|---|
| `hello` | `token` | `name`, `version`, `brain` (the AI's name: Claude, Codex…), `scope`, `scopes[]`, `sections[]` |
| `state` | | same as `hello` |
| `entries.list` | `scope`, `section`, `query?`, `tags?[]`, `limit?` | `entries[]`: `id, section, scope, title, date, summary, tags[], fields{status, kind, owner, due, waiting_on, start, end, work_item, raised_in, proposed_by, reason}` |
| `entries.search` | `query`, `scope?` | `entries[]` |
| `entry.get` | `id` | `id`, `frontmatter{}` (strings or string lists), `body` (Markdown), `extra{linked[]}` for facts |
| `entry.save` | `id`, `frontmatter{}` (only keys to change; `null` or `""` removes), `body?` | `saved` |
| `entry.new` | `scope`, `section`, `title`, `summary?`, `tags?[]`, `fields?{}`, `body?` | `id` |
| `inbox.approve` / `inbox.reject` | `ids[]` | `done` |
| `facts.proposed` | `scope` | `entries[]` |
| `tracker.items` | `scope`, `mine?` | `me`, `items[]` (as the app's backlog: id, type, title, state, stage, sprint, assignee, tags…) |
| `sessions.list` | `scope?`, `archived?` (true includes archived ones) | `sessions[]`: `id, title, space (plan/build), role (solo/lead/member/overseer, or assistant for the assistant session), scope, state, busy, updated, count, needsYou, archived, kind?, kindTitle?, origin?, link?`; see [Plan sessions](#plan-sessions) |
| `session.get` | `id`, `since?` (items already seen) | `session`, `items[]` (`role`: user/assistant/error/status/tool, `text`), `count` |
| `session.send` | `id`, `text` | `sent` |
| `session.new` | `space`, `title?`, `scope?`, `message?` | `id` |
| `session.archive` | `id`, `archived` (false takes it out of the archive) | `archived` |
| `app.structure` | `scope?` | `scope`, `modes[]`; see [App structure](#app-structure) |
| `kb.run` | `args[]`, `stdin?` | `output`: runs the `kb` command; reaches whatever has no method yet |

### Plan sessions

The Mac's Plan → Sessions lists every Plan conversation the user can come back to, wherever it was started: in
Sessions, from a research, an idea, a discussion, a follow-up, a meeting, a goal, an entry, or the Ask window. Show
the same list on the phone from `sessions.list`.

Each item has:

- `kind`, `kindTitle` (Plan items only; left out for Build): the section it goes in. In this order: `assistant`
  (Assistant), `workItems` (Work items: creating PBIs and bugs), `research` (Research), `ideas` (Ideas),
  `discussions` (Discussions), `followups` (Follow-ups), `meetings` (Meetings), `goals` (Goals), `entries` (On
  entries: any other KB entry), `questions` (Questions: everything else). Show a section only when it has items.
- `origin` (optional): what it was started from, an entry id (`acme/research/2026-11-20-auth`), or `goals/<name>` for
  a goal. Open it with `entry.get` (or the phone's own screen for it).
- `archived`: archived by the user. Archived items don't count anywhere and never "need you"; list them last, folded,
  as "Archived · n". A Plan session that gets a new message comes out of the archive by itself.
- `needsYou`: it waits for the user (a question, or a tool it was refused). Always show these, however old.
- `link` (optional): `{screen, id}` for a conversation that lives in its own place on the Mac rather than in a
  session: a meeting's chat (`screen: "meeting"`, `id`: the meeting entry), a goal's coach (`screen: "goals"`, `id`:
  the goal id) or the Ask window (`screen: "ask"`, `id`: the scope). Its `id` starts with `link:` and its `role` is
  `linked`; `session.get` and `session.send` don't take it. Tapping it opens the matching screen on the phone, or
  the Mac with `app.show` `screen`/`id`. It can be archived like a session.

Without `archived: true`, archived items are left out. With `scope`, the list is what the Mac shows for that scope:
sessions in the scope or in a scope it includes (the split layout's Overview includes every scope), sessions on an
entry the scope shows (an entry tagged with the scope counts, so a research in `acme` tagged `android` shows in
both), and sessions with no scope. Without `scope`, every session.

The Mac groups them like this: items updated in the last 14 days (and any that are running or need the user) go in
their `kind` section, newest first; the rest go in a folded "Older · n" section; archived ones in a folded
"Archived · n" section at the bottom. The Plan badge counts `needsYou` items that aren't archived.

Archive and unarchive with `session.archive` (`id`, `archived`), which also takes `link:` ids. The `session.archive`
action does the same for sessions.

### App structure

`app.structure` (`scope?`, the current scope when left out) gives the Mac's sidebar for each mode, in the user's
order, so the phone can show the same structure:

```json
{"scope": "acme", "modes": [
  {"id": "plan", "title": "Plan", "sections": [
    {"id": "today", "title": "Today", "icon": "sun.max", "count": 3},
    {"id": "sessions", "title": "Sessions", "icon": "bubble.left.and.text.bubble.right", "count": 2, "needsYou": 1},
    {"id": "research", "title": "Research", "icon": "binoculars", "group": "Planning", "count": 1}
  ]},
  {"id": "build", "title": "Build", "sections": [
    {"id": "overview", "title": "Overview", "icon": "binoculars.fill"},
    {"id": "scope:android", "title": "Android", "icon": "folder", "group": "Sessions", "count": 4, "needsYou": 1}
  ]}
]}
```

Each section: `id`, `title`, `icon` (an SF Symbol name; map it to the phone's own icons), `group?` (the sidebar
heading it sits under: `Planning`, `Work`, `Sessions`; none for the rows at the top), `count?` (what the Mac shows
as the row's badge: open items, or sessions), `needsYou?` (how many wait for the user; show it prominently).

Plan's sections, in order: `today`, `reminders`, `goals` (across scopes), then for the scope `project`, `sessions`,
`overview` (only when the scope has one), the Planning rows in the user's order (`inbox`, `decisions`, `meetings`,
`discussions`, `ideas`, `research`, `facts`, `followups`, `references` by default), then the Work rows in the user's
order (`backlog`, `pullRequests`, `architecture` by default). A section id that is a KB section (`research`,
`followups`…) lists with `entries.list` `section`; `sessions` with `sessions.list` `scope`; `pullRequests` with the
`prs.list` action; `today`, `reminders`, `goals` with the `today.plan`, `reminders.list`, `goals.list` actions;
`project` with `projects.list`.

Build's sections: `overview` (the overview session), `factories` (the software factories), `testing`, then one
`scope:<id>` per scope with recent Build sessions (grouped under `Sessions`; its sessions are the `sessions.list`
items with `space: "build"` and exactly that `scope`; `scope:` alone is the sessions with no scope), and `archived`
when some are archived.

The order changes when the user drags rows on the Mac; fetch it again on `index.changed` and when the app comes to
the front.

### Actions

Everything in Mindmill on the Mac can be done through the same action layer the Mac's buttons, voice and Claude
sessions use, so a change made from the phone shows on the Mac at once.

| Method | Params | Result |
|---|---|---|
| `actions.list` | | `areas[]` (area titles in display order), `actions[]`: `name, area, about, risk (read/write/destructive/external), input` (JSON schema), and `confirmsRisky` |
| `action.run` | `name`, `params{}`, `voice?` (true when said out loud) | `status` (`done`/`needs_confirmation`/`failed`), `speech` (one or two sentences to show or speak), `data?`, `token?` |
| `action.confirm` | `token` | as `action.run` |
| `action.cancel` | `token` | `status: cancelled` |

`needs_confirmation` comes for destructive actions (deleting, stopping) and writes to an outside tool (Azure DevOps,
Jira, GitHub, sending messages): ask `speech` (by voice when talking), then `action.confirm` on yes or
`action.cancel` on no. Tokens expire after two minutes.

Action names are grouped by a dot prefix (`factory.*`, `meeting.*`, `pr.*`…), and each has an `area`: a short group
title such as `Factories` for a generic action browser on the phone. Build that browser from `actions.list`: group by
`area` in the order of `areas[]`, show `about`, and build a form from `input` (types `string`, `integer`, `number`,
`boolean`, `array` of strings; `enum` gives the choices; `required` lists the required ones). Never hard-code the
list; the Mac adds actions over time. The areas and what they hold are in [Action areas](#action-areas).

### Assistant

A general Claude session that can do anything Mindmill can, through the same actions as below (it asks before risky
ones), and uses `kb` for the rest. Use it when the user doesn't know where something is: "start a meeting and
transcribe it", "make a factory for the bugs in Billing", "what did we decide about login?". It is an ordinary Plan
session: it shows in the Mac's session list (Plan → Sessions, under Assistant), in `sessions.list` with
`role: "assistant"`, and can be continued from either side. On the Mac: File → New Assistant Session (⌥⌘A).

| Method | Params | Result |
|---|---|---|
| `assistant.open` | `scope?`, `new?` (true starts a fresh one) | `session` (as in `sessions.list`), `created` (true when it was just made) |

Without `new` it returns the most recent assistant session that isn't archived (in `scope` when given), and makes one
when there is none. Then:

1. `session.get` with `id` (and `since` = items already shown) for the conversation.
2. `session.send` with `id` and `text` for each message the user types or says.
3. On `session.changed` for that id, `session.get` with `since` again. `busy: true` means it is still answering.

When the assistant needs a yes (deleting, stopping, writing to the tracker or GitHub), it asks in its reply; the user
answers in the chat ("yes"). There is no token on the phone's side here. A "New conversation" button calls
`assistant.open` with `new: true`.

### Factory editor

A factory's whole configuration, for a full editor on the phone. `rules` uses the same keys the Mac stores:

| Key | Type | Meaning |
|---|---|---|
| `scopes` | string[] | Scope ids it takes work from (at least one; from `options.scopes`) |
| `assignedToMe` | bool | Items assigned to the user |
| `unassigned` | bool | Unassigned items too (assigned to the user first) |
| `pbis`, `bugs` | bool | Which kinds (at least one) |
| `sprint` | string | `current`, `currentAndNext`, `any` (`options.sprint`) |
| `resumeStarted` | bool | Also the user's items already in progress that no session works on |
| `newWorkItems` | string | `never`, `propose`, `create` (`options.newWorkItems`) |
| `questions` | string | `whenUnsure`, `checkpointsOnly`, `never` (`options.questions`) |
| `defaultStrategy` | string | A strategy slug; `""` = one session without a strategy (`options.strategies`) |
| `strategyRules` | object[] | Exceptions, first match wins: `{id?, match, value, strategy}`; `match` from `options.strategyMatch`; `value` (a tag or words) is needed when that choice has `needsValue` |
| `checkpoints` | string[] | Checkpoint ids where it stops to ask (`options.checkpoints`) |
| `customCheckpoints` | object[] | The user's own moments to ask: `{id?, title, instruction, on}` |
| `askTexts` | {string: string} | Changed wording per ask point: `unsure`, a checkpoint id, or `custom:<id>`; leave a key out for the default text |
| `openPRs`, `completePRs` | bool | Open pull requests; also complete (merge) them |
| `maxParallel` | int | Work items at once (`options.maxParallel`) |
| `duration` | string | `untilStopped`, `hours`, `until` (`options.duration`) |
| `hours` | number | For `duration: hours` |
| `until` | string | ISO 8601 date-time with zone, for `duration: until`, e.g. `2026-11-23T18:00:00Z` |

`questions: never` turns asking off; `whenUnsure` also asks when unsure (the `unsure` ask point); `checkpointsOnly`
asks only at the ticked checkpoints and custom ones.

Saving: unknown keys and `null` values are ignored, keys left out keep the factory's current value (a new factory:
the default from `factory.config.get`), and `strategyRules`/`customCheckpoints` items without a valid `id` get one.
A value of the wrong type fails with `bad_params` and a message naming the key (`rules.maxParallel isn't valid.`).

| Method | Params | Result |
|---|---|---|
| `factory.config.get` | `id?` (none: the defaults for a new factory) | `factory` (`{id, name, status (never/running/paused/windingDown/stopped), running}`, or `null` for a new one), `name` (its name, or a suggested one for a new factory), `rules{}`, `problems[]` (what stops it from starting; empty when it can), `options{}` |
| `factory.config.save` | `id?` (none or `""`: create), `name`, `rules{}` | `id`. Fails with `bad_params` whose `message` is the problems joined by spaces (no scope, nothing to ask at, an exception without a value, an end time that has passed), to show as is. Changing a running factory tells its sessions at work |
| `factory.config.delete` | `id` | `deleted`. Stops it first when it runs. Ask the user before calling |

`options`:

```json
{
  "scopes": [{"id": "billing", "title": "Billing"}],
  "strategies": [{"slug": "", "title": "No strategy (one session)"}, {"slug": "tdd", "title": "Test first"}],
  "checkpoints": [
    {"id": "planReady", "title": "When the plan is ready, before writing code", "detail": "…", "requires": []},
    {"id": "beforePR", "title": "Before opening a pull request", "detail": "…", "requires": ["openPRs"]},
    {"id": "beforeComplete", "title": "Before completing (merging) a pull request", "detail": "…", "requires": ["openPRs", "completePRs"]}
  ],
  "unsureAsk": {"id": "unsure", "title": "When it's unsure about something that matters", "instruction": "…"},
  "sprint": [{"id": "current", "title": "Current sprint"}],
  "questions": [{"id": "whenUnsure", "title": "Ask when unsure, and at the checkpoints"}],
  "newWorkItems": [{"id": "propose", "title": "Propose them for my approval"}],
  "duration": [{"id": "untilStopped", "title": "Until I stop it"}],
  "strategyMatch": [{"id": "tag", "title": "Tagged", "needsValue": true}],
  "maxParallel": [1, 2, 3, 4, 5, 6, 8, 10]
}
```

`scopes` lists only scopes with a tracker. A checkpoint whose `requires` keys aren't all true in `rules` doesn't
apply: grey it out. Start, pause, resume and stop with the `factory.*` actions; `factories.status` lists them, and
`factory.changed` tells when one changed.

### Voice

The phone never sees or stores an API key. It asks the Mac which engine to use:

- **keyless** (default): the phone recognises speech on the device, sends the text with `voice.say`, and speaks the
  `voice.sentence` events with its own text-to-speech as they arrive.
- **api**: the phone streams microphone audio to the Mac in `voice` binary frames and plays the `pcm24k` frames
  that come back. The Mac holds the real-time API connection and the key. When it fails (bad key, quota, network),
  the Mac sends `voice.fallback` and the conversation carries on keyless.

| Method | Params | Result |
|---|---|---|
| `voice.config` | | `engine` (`keyless`/`api`), `provider?`, `providerName?`, `model?`, `rate` (speech speed, 0.5–2), `voice?` (a voice name hint), `confirmsRisky`, `language` (`auto`/`da-DK`/`en-US`) |
| `voice.start` | `scope?`, `engine?` (`keyless` forces keyless) | `conversation`, `engine` |
| `voice.say` | `conversation`, `text` | `turn` |
| `voice.interrupt` | `conversation` | `stopped`: the user started talking; the Mac stops the turn and the phone stops speaking |
| `voice.end` | `conversation` | `ended` |

| Event | Data | What to do |
|---|---|---|
| `voice.sentence` | `conversation, turn, index, text` (`index` starts at 0 in each turn) | Speak it (queue after the previous one) |
| `voice.done` | `conversation, turn, text` | The whole reply; listen again once speaking ends |
| `voice.action` | `conversation, name, status, speech, data?` | Show a card for what was done |
| `voice.error` | `conversation, message` | Say it briefly and listen again |
| `voice.transcript` | `conversation, role (user/assistant), text, final` | API engine: show the text |
| `voice.state` | `conversation, state (listening/thinking/speaking)` | API engine: show the state |
| `voice.clear` | `conversation` | API engine: the user barged in; drop queued audio now |
| `voice.fallback` | `conversation, reason, speech` | Speak `speech`, then carry on keyless in the same conversation |

### Testing and deliveries

The Mac builds and tests what sessions and factories make, and delivers builds and previews to the phone.

| Method | Params | Result |
|---|---|---|
| `test.status` | `scope?` | `targets[]`: `id, type, title, method, methodTitle, ready, checklist[]{id, title, status (ok/missing/unknown), help}`; `compatibility{checked, good, findings[]{title, detail, canStill, cannot}}`; `deliveries[]` |
| `test.download` | `delivery` | `name, size, sha256, chunks`; then the file arrives as `file` binary frames |
| `test.installed` | `delivery`, `ok`, `message?` | `noted` |
| `preview.get` | `delivery`, `path` | `mime`, `base64`: one file of a preview page; load previews in a web view that fetches every request this way. A backend preview's "try a call" panel asks for `try?method=GET&path=/x&body=…`, which the Mac makes against the local service and answers as text |
| `review.list` | `scope?` | `cards[]` (as the `review.card` event) |
| `review.respond` | `card`, `action` (`approve`/`pause`/`change`/`install`), `text?` (for `change`) | `speech` |

| Event | Data | What to do |
|---|---|---|
| `test.delivery` | `id, scope, target, kind (apk/url/preview), title, url? (kind url: open it), size?` | `apk`: `test.download`, check the SHA-256, install with the package installer, then `test.installed`. `url`: open in the web view or browser. `preview`: open `preview.get` path `index.html` |
| `review.card` | `id, scope, title, summary, workItem?, session?, factory?, tests{passed, failed, lines[]}, images[]{title, path, before?}, delivery?, actions[]` | Show the card; images load with `preview.get` (`delivery` = the card id) |

### Meetings

| Method | Params | Result |
|---|---|---|
| `meeting.start` | `scope?`, `title?` | `meeting` (an entry id) |
| `meeting.line` | `meeting`, `text`, `speaker` (`Room`/`You`), `language?` | `added` |
| `meeting.note` | `meeting`, `text` | `added` |
| `meeting.stop` | `meeting` | `stopped`; the Mac writes the summary and proposals |
| `meeting.get` | `meeting` | `title, notes, transcript[], summary?, state (live/summarising/done)` |

Screenshots during a meeting go as `screen` binary frames; the Mac reads them for the notes.

## Events

| Event | Data | What to do |
|---|---|---|
| `session.changed` | `id, count, busy, state` | If that session is open, `session.get` with `since` |
| `index.changed` | | Refresh lists on screen |
| `factory.changed` | `id, status` | Refresh factory status (`action.run` `factories.status`) |
| `meeting.changed` | `meeting, state` | If that meeting is open, `meeting.get` |

## Action areas

Every action, by area, in the order `actions.list` gives them (`risk`: `read` changes nothing, `write` changes
Mindmill, `destructive` and `external` answer `needs_confirmation` first). A `?` marks an optional parameter; `scope`
means the current project when left out. Read `actions.list` at run time for the exact JSON schemas; this list is for
planning screens. Every result has `speech` (show it, or speak it when talking); the `data` that screens need is
described after the tables.

### Overview

| Action | Risk | Params | Does |
|---|---|---|---|
| `overview` | read | `scope?` | What needs the user now: proposed facts, open follow-ups, their work items, factories and sessions waiting. |
| `projects.list` | read |  | The user's projects (scopes) and which one is current. |
| `project.select` | write | `scope` | Make a project the current one on the Mac. |
| `app.show` | read | `screen`, `id?` | Bring the Mac app to the front on a screen, an entry, a factory or a session. |
| `sync.all` | write |  | Sync everything: knowledge base, tracker, pull requests and calendar. |

### Knowledge

| Action | Risk | Params | Does |
|---|---|---|---|
| `knowledge.search` | read | `query`, `scope?` | Search facts, decisions, meetings, follow-ups and notes. |
| `entries.list` | read | `section`, `query?`, `tags?` (list), `limit?` (integer), `scope?` | Entries in one section, newest first. |
| `entry.read` | read | `id` | Read one entry (fact, decision, meeting, follow-up…) in full, to answer or summarise. |
| `entry.create` | write | `section`, `title`, `summary?`, `body?`, `tags?` (list), `fields?` (list), `scope?` | Write a new entry: a decision, fact, architecture note, idea, reference note… |
| `entry.update` | write | `id`, `title?`, `summary?`, `status?`, `field?`, `value?`, `body?`, `append?` | Change an entry: title, summary, status, a field, or its text (replace or add to the end). |
| `entry.delete` | destructive | `id` | Delete an entry from the knowledge base. |
| `entry.move` | write | `id`, `to` | Move an entry to another project. |
| `entry.tags` | write | `id`, `tags` (list) | Set an entry's tags. |
| `entry.scopes` | write | `id`, `scope`, `add` (boolean) | Add or remove another scope an entry belongs to. |
| `entry.share` | write | `id`, `shared` (boolean) | Share an entry with the team (into the repository's knowledgebase folder) or make it private. |
| `entry.ask` | read | `id` | Open the Ask window on the Mac about an entry. |

### Facts

| Action | Risk | Params | Does |
|---|---|---|---|
| `facts.list` | read | `scope?`, `limit?` (integer) | Confirmed facts, newest first. |
| `facts.proposed` | read | `scope?` | Proposed facts waiting for the user's yes or no. |
| `fact.approve` | write | `id` | Approve a proposed fact. |
| `fact.decline` | write | `id` | Decline a proposed fact. |
| `fact.propose` | write | `title`, `body?`, `reason?`, `scope?` | Propose a new fact for the user to approve. |
| `fact.links` | read | `id` | The facts linked to a fact. |
| `fact.link` | write | `id`, `other`, `remove?` (boolean) | Link two facts, or unlink them. |
| `fact.links.suggest` | write | `id` | Ask for links to other facts to be suggested (they show on the Mac). |
| `fact.change.resolve` | write | `id`, `how` (update/keep) | Answer a fact change: update the fact, or keep it as it is. |
| `fact.change.remove` | destructive | `id` | Answer a fact change with: no longer true. Removes the fact. |
| `quiz.round` | read | `count?` (integer), `scope?` | Make a few quiz questions from the facts, to check what the user remembers. |
| `quiz.answer` | write | `fact`, `correct` (boolean) | Record whether the user knew a fact in the quiz. |

### Follow-ups

| Action | Risk | Params | Does |
|---|---|---|---|
| `followups.list` | read | `filter?` (mine/waiting/all), `scope?` | Open follow-ups: on the user, waiting on others, or all. |
| `followup.create` | write | `title`, `kind?` (action/question), `owner?`, `due?`, `scope?` | Add a follow-up (an action or a question). |
| `followup.update` | write | `id`, `status?` (done/dropped/open), `note?`, `answer?`, `resolved_by?` | Change a follow-up: close it, drop it, reopen it, or add a note. |
| `followups.duplicates` | write | `scope?` | Look for duplicate follow-ups; proposals to merge show on the Mac. |
| `followup.merge` | destructive | `keep`, `other` | Merge one follow-up into another. |
| `followups.check` | write | `scope?` | Check whether open follow-ups were answered elsewhere (mail, chats, the tracker). |

### Discussions

| Action | Risk | Params | Does |
|---|---|---|---|
| `discussion.start` | write | `look_for`, `scope?` | Find a discussion in mail or chats and start tracking it. |
| `discussion.status` | write | `id`, `status` (open/parked/concluded), `outcome?` | Park, reopen or conclude a discussion. |
| `discussion.waiting` | write | `id`, `on` (me/others/nobody) | Say who a discussion waits on. |
| `discussion.refresh` | write | `id` | Check a discussion for new replies. |
| `discussion.file` | write | `id` | File what a discussion found into the knowledge base. |

### Ideas and Research

| Action | Risk | Params | Does |
|---|---|---|---|
| `idea.status` | write | `id`, `status` (new/exploring/shelved/done) | Set an idea's status. |
| `idea.turn` | write | `id`, `into` (backlog/fact/decision/followup/architecture/project) | Turn an idea into a backlog item, fact, decision, follow-up, architecture note or project. |
| `idea.brainstorm` | write | `id` | Brainstorm on an idea in a session. |
| `research.start` | write | `question`, `title?`, `work_item?` (integer), `entry?`, `scope?` | Start researching a question. |
| `research.continue` | write | `id` | Carry on with a research. |
| `research.finish` | write | `id` | Summarise a research so its takeaways can be filed. |
| `research.status` | write | `id`, `status` (open/review/done/parked) | Set a research's status. |

### References

| Action | Risk | Params | Does |
|---|---|---|---|
| `reference.save` | write | `title`, `url?`, `note?`, `kind?` (artifact/email/teams/web/document/file/note), `scope?` | Save a link or a note to References. |
| `reference.from_mail` | write | `look_for`, `kind?` (email/teams), `note?`, `scope?` | Find a mail or Teams chat and save it to References. |

### Reminders and Goals

| Action | Risk | Params | Does |
|---|---|---|---|
| `reminders.list` | read | `status?` (open/proposed/done/all) | The user's reminders. |
| `reminder.create` | write | `title`, `due?`, `note?`, `link?`, `scope?` | Add a reminder. |
| `reminder.update` | write | `id`, `status?` (open/proposed/done/dismissed), `due?` | Mark a reminder done, reopen, accept or dismiss it, or change its date. |
| `reminder.delete` | destructive | `id` | Delete a reminder. |
| `goals.list` | read |  | The user's goals and their latest progress. |
| `goal.create` | write | `title`, `horizon?`, `why?` | Add a goal. |
| `goal.status` | write | `id`, `status` (active/paused/achieved/dropped) | Set a goal's status. |
| `goal.progress` | write | `id`, `text` | Log progress on a goal. |
| `goal.coach` | write | `id`, `text` | Ask the goal coach something about a goal. |
| `goal.delete` | destructive | `id` | Delete a goal. |

### Today

| Action | Risk | Params | Does |
|---|---|---|---|
| `today.plan` | read | `day?` | The day's plan: what to do today, what to decide, and the side goal. |
| `today.check` | write | `item` (integer), `done` (boolean) | Tick an item of today's plan, or untick it. |
| `today.morning` | write |  | Run the morning routine: read mail and calendar and write today's plan. |
| `sync.calendar` | write |  | Sync the calendar into meetings now. |
| `sync.email` | write |  | Read new mail for reminders now. |

### Meetings

| Action | Risk | Params | Does |
|---|---|---|---|
| `meetings.list` | read | `day?`, `scope?` | Meetings on a day, with their notes' status. |
| `calendar.upcoming` | read | `days?` (integer), `scope?` | Calendar meetings coming up, and the one running on the Mac. |
| `meeting.create` | write | `title`, `date`, `start?`, `attendees?` (list), `scope?` | Plan a meeting for later. |
| `meeting.prepare` | write | `meeting` | Prepare a meeting with the brain: questions and what to know, in its window on the Mac. |
| `meeting.mac.start` | write | `event?`, `title?`, `transcribe?` (boolean), `scope?` | Start a meeting on the Mac now: opens its window, takes notes and transcribes live. |
| `meeting.mac.note` | write | `text`, `meeting?` | Add a note to the meeting running on the Mac. |
| `meeting.mac.transcribe` | write | `on` (boolean), `meeting?` | Turn live transcription on or off in the meeting on the Mac. |
| `meeting.mac.stop` | destructive | `meeting?` | End the meeting on the Mac and write its summary and proposals. |
| `meeting.mac.file` | write | `meeting?` | File a reviewed meeting: its summary and the proposals left ticked. |
| `meeting.mac.status` | read | `meeting?` | The meeting open on the Mac: its stage, transcript and notes. |

### Backlog

| Action | Risk | Params | Does |
|---|---|---|---|
| `backlog.list` | read | `mine?` (boolean), `state?`, `scope?` | Work items (PBIs and bugs) from the tracker. |
| `workitem.get` | read | `id` (integer), `scope?` | One work item in full. |
| `workitem.search` | read | `query` | Find work items in the tracker, finished ones too. |
| `workitem.create` | external | `title`, `kind?` (pbi/bug), `description?`, `sprint?` (current/next/none), `scope?` | Create a work item in the tracker. |
| `workitem.update` | external | `id` (integer), `state?`, `assignee?`, `sprint?`, `comment?`, `scope?` | Change a work item's state, assignee or sprint, or add a comment. |
| `workitem.tasks` | external | `ids` (list), `state` (New/In Progress/Done) | Set the state of tasks under a work item. |
| `workitem.implement` | external | `id` (integer), `mode?` (guided/fast), `strategy?`, `scope?` | Start implementing a work item in a Build session (moves it to in progress). |
| `workitem.tags.align` | external | `id` (integer), `scope?` | Write a work item's aligned Mindmill tags to the tracker. |
| `backlog.proposed` | read | `scope?` | Backlog items proposed in the knowledge base, not yet in the tracker. |
| `backlog.propose` | write | `title`, `details?`, `bug?` (boolean), `source?`, `scope?` | Propose a PBI or bug in the knowledge base (not yet in the tracker). |
| `backlog.create` | external | `id`, `sprint?` (current/next/none) | Create a proposed backlog item in the tracker. |
| `backlog.reject` | destructive | `id` | Reject a proposed backlog item. |

### Pull Requests

| Action | Risk | Params | Does |
|---|---|---|---|
| `prs.list` | read |  | The user's open pull requests: comments, approvals and what blocks completing. |
| `pr.get` | read | `id` (integer) | One pull request with its comment threads. |
| `pr.comment` | external | `id` (integer), `text` | Post a new comment on a pull request. |
| `pr.reply` | external | `id` (integer), `thread` (integer), `text`, `resolve?` (boolean) | Reply on a comment thread, and resolve it if asked. |
| `pr.thread` | external | `id` (integer), `thread` (integer), `status` (fixed/wontFix/closed/active) | Set a comment thread's status. |
| `pr.approve` | external | `id` (integer) | Approve a pull request. |
| `pr.vote` | external | `id` (integer), `vote` (approve/approve-with-suggestions/wait-for-author/reject/reset) | Vote on a pull request. |
| `pr.complete` | external | `id` (integer), `auto?` (boolean), `strategy?` (squash/noFastForward/rebase/rebaseMerge), `delete_branch?` (boolean), `complete_work_items?` (boolean), `message?` | Complete (merge) a pull request now, or set it to complete by itself when ready. |
| `pr.autocomplete.cancel` | external | `id` (integer) | Cancel a pull request's auto-complete. |
| `pr.comments.handle` | write | `id` (integer), `mode?` (withMe/simpleOnly/all) | Have a session work through a pull request's comments. |
| `pr.conflicts` | write | `id` (integer) | Have a session resolve a pull request's merge conflicts. |
| `pr.build.fix` | write | `id` (integer) | Have a session fix a pull request's failed build. |
| `pr.build.rerun` | external | `id` (integer) | Run a pull request's build again. |

### Factories

| Action | Risk | Params | Does |
|---|---|---|---|
| `factories.status` | read |  | Each software factory: running, paused or stopped, what it works on, progress and open questions. |
| `factory.get` | read | `factory` | A factory's whole configuration and state. |
| `factory.create` | write | `name`, `scopes?` (list), `assigned_to_me?` (boolean), `unassigned?` (boolean), `pbis?` (boolean), `bugs?` (boolean), `sprint?` (current/currentAndNext/any), `resume_started?` (boolean), `new_work_items?` (never/propose/create), `questions?` (whenUnsure/checkpointsOnly/never), `strategy?`, `checkpoints?` (list), `open_prs?` (boolean), `complete_prs?` (boolean), `max_parallel?` (integer), `hours?` (number), `until?` | Make a new software factory. It doesn't start until asked. |
| `factory.update` | write | `factory`, `name?`, `scopes?` (list), `assigned_to_me?` (boolean), `unassigned?` (boolean), `pbis?` (boolean), `bugs?` (boolean), `sprint?` (current/currentAndNext/any), `resume_started?` (boolean), `new_work_items?` (never/propose/create), `questions?` (whenUnsure/checkpointsOnly/never), `strategy?`, `checkpoints?` (list), `open_prs?` (boolean), `complete_prs?` (boolean), `max_parallel?` (integer), `hours?` (number), `until?` | Change any of a factory's settings or its name. |
| `factory.duplicate` | write | `factory`, `name?` | Copy a factory with its settings. |
| `factory.delete` | destructive | `factory` | Delete a factory (stopping it first if it runs). |
| `factory.start` | write | `factory` | Start (or start again) a software factory. |
| `factory.pause` | write | `factory` | Pause a factory: it takes no new work items, sessions working carry on. |
| `factory.resume` | write | `factory` | Resume a paused factory. |
| `factory.stop` | destructive | `factory` | Stop a factory: it starts nothing new and its sessions finish the step they're on. |
| `factory.settings` | write | `factory`, `max_parallel?` (integer), `questions?` (whenUnsure/checkpointsOnly/never), `hours?` (number) | Change how a factory runs. |
| `factory.answer` | write | `question`, `answer` | Answer a question a factory asked. |
| `factory.question.skip` | write | `question` | Let the factory decide a question itself. |
| `factory.item.skip` | write | `factory`, `work_item` (integer) | Skip a work item for this run of a factory. |

### Strategies

| Action | Risk | Params | Does |
|---|---|---|---|
| `strategies.list` | read |  | The strategies a Build session or factory can follow. |
| `strategy.get` | read | `slug` | One strategy in full. |
| `strategy.save` | write | `slug?`, `title`, `summary?`, `instructions`, `model?` | Write a strategy of the user's own, or change one. |
| `strategy.delete` | destructive | `slug` | Delete a strategy of the user's own (a changed built-in goes back to the original). |
| `strategy.draft` | write |  | Draft a new strategy together with the brain in a session. |

### Sessions

| Action | Risk | Params | Does |
|---|---|---|---|
| `sessions.list` | read |  | Plan and Build sessions, and which ones wait for the user. |
| `session.read` | read | `id`, `last?` (integer) | The latest messages of a session. |
| `session.start` | write | `space` (plan/build), `message`, `title?`, `strategy?`, `scope?` | Start a Plan or Build session with a first message; for deeper work like planning or implementing. |
| `session.lead` | write | `brief`, `title?`, `strategy?`, `helpers?` (integer), `scope?` | Start a Build lead session that splits the work over helper sessions. |
| `session.send` | write | `id`, `text` | Send a message to a session. |
| `session.stop` | destructive | `id` | Stop what a session is doing. |
| `session.retry` | write | `id` | Send a session's last message again after it failed. |
| `session.allow` | write | `id` | Allow what a session was refused, for that session. |
| `session.strategy` | write | `id`, `strategy` | Give a session a strategy, or take it away. |
| `session.to_build` | write | `id` | Move a Plan session to Build. |
| `session.archive` | write | `id`, `archived?` (boolean) | Archive a session, or take it out of the archive. |
| `session.delete` | destructive | `id` | Delete a session (stopping it first). |

### Testing

| Action | Risk | Params | Does |
|---|---|---|---|
| `test.status` | read | `scope?` | Testing set-up and the latest test delivery for a project. |
| `test.detect` | write | `scope?` | Look for what can be tested in a project again (apps, web, services). |
| `test.check` | write | `scope?` | Check this Mac's tools and the project's compatibility for testing again. |
| `test.deliver` | write | `target`, `scope?` | Build a test target and deliver it: to the phone, a preview, a link. |
| `test.server.stop` | destructive | `id` | Stop a running dev server. |

### Projects

| Action | Risk | Params | Does |
|---|---|---|---|
| `scans.list` | read |  | Project scans and what they found. |
| `scan.start` | write | `scopes?` (list), `kinds?` (list), `sources?` (list), `focus?` | Scan projects for facts, decisions, architecture and more. |
| `scan.stop` | destructive | `id` | Stop a scan. |
| `scan.apply` | write | `id`, `findings?` (list) | Add a scan's findings to the knowledge base. |
| `repos.pull` | write | `scope?` | Pull the latest of a project's repositories (fast-forward only). |
| `people.list` | read | `query?` | People Mindmill knows: names, emails. |
| `people.refresh` | write |  | Read the people directory again. |

### Settings

| Action | Risk | Params | Does |
|---|---|---|---|
| `settings.get` | read |  | Mindmill's settings: the AI brain and models, voice, meetings, calendar and general ones. |
| `settings.ai` | write | `task` (brain/work/ask/meetings/voice/background/calendar), `model?`, `provider?` | Choose the brain or the model for a task. |
| `settings.voice` | write | `engine?` (keyless/api), `rate?` (number), `language?` (auto/da-DK/en-US), `barge_in?` (boolean) | Change voice settings. |
| `settings.meetings` | write | `language?`, `microphone?` (boolean), `computer_audio?` (boolean) | Change how meetings are transcribed. |
| `settings.general` | write | `appearance?` (system/light/dark), `open_in?` (""/plan/build), `morning?` (boolean), `calendar_minutes?` (integer) | Change general settings. |
| `app.mode` | write | `mode` (plan/build) | Switch the Mac app to Plan or Build. |

### Data the screens need

Lists of entries use the entry summary of `entries.list` (`id, section, scope, title, date, summary, tags[], fields{}`).

| Action | `data` |
|---|---|
| `overview` | `scope, proposedFacts, followupsMine, followupsWaiting, workItems, factoriesRunning, factoryQuestions, sessionsWaiting[]` (sessions as in `sessions.list`) |
| `entries.list`, `knowledge.search`, `facts.*`, `followups.list`, `meetings.list`, `backlog.proposed`, `fact.links` | `entries[]` |
| `entry.read` | `id, title, body` |
| `entry.create`, `reference.save` | `id` |
| `reminders.list` | `reminders[]`: `id, title, due, status (open/proposed/done/dismissed), note, scope?, link?` |
| `goals.list` | `goals[]`: `id, title, horizon, status (active/paused/achieved/dropped), lastProgress?, openSuggestions` |
| `today.plan` | `day, today[], toDecide[], sideGoal[]`, each `{item, text, done, notRelevant, scope?, ref?}`; tick with `today.check` `item` |
| `quiz.round` | `questions[]`: `fact, question, answer` (show the question, reveal the answer, then `quiz.answer`) |
| `backlog.list`, `workitem.search` | `items[]` as in `tracker.items` |
| `prs.list` | `prs[]`: `id, title, repo, repo_id, scope, url, draft, author, source, target, created, merge_status, auto_complete, reviewers[]{name, vote, required, vote_name}, work_items[], open_threads, threads_total, policies[], blockers[], strategies[], keep_branch` (snake case, as `kb pr list --json`; ready to complete when `blockers` is empty) |
| `pr.get` | the same for one, plus `description` and `threads[]{id, status (active/pending/fixed/wontFix/closed/byDesign), file, line, published, comments[]{id, author, content, date}}` (`file` empty: a general comment) |
| `factories.status` | `factories[]`: `id, name, status (never/running/paused/windingDown/stopped), progress?, maxParallel, questionsMode, tasks[]{workItem, title, session, milestone?}, questions[]{id, text, options[], workItem?}` |
| `factory.get` | one of those plus `rules{}` (as in the factory editor) and `problems[]` |
| `factory.create`, `factory.duplicate` | `id` (`factory.create` also `problems[]`: it is made even when it can't start yet) |
| `strategies.list` | `strategies[]`: `slug, title, summary, origin (builtIn/custom/override), model, sessions, spawns`; `strategy.get` adds `instructions` |
| `sessions.list` | `sessions[]` as the `sessions.list` method |
| `session.read` | `items[]`: `role, text` |
| `scans.list` | `scans[]`: `id, scope, kinds[], running, failed, note, findings[]{id, kind, title, summary, status}` |
| `people.list` | `people[]`: `name, email` |
| `settings.get` | `ai{brain, tasks{<task>: {title, provider, model}}, providers[]{id, name, models[]}}`, `voice{engine, provider?, rate, language, bargeIn, confirmsRisky}`, `meetings{language, languages[]{id, name}, microphone, computerAudio}`, `general{appearance, openIn, morning, calendarMinutes}`, `remote{enabled, port, phones[]}` |
| `test.status`, `test.check` | as the `test.status` method |

Tasks for `settings.ai`: `work`, `ask`, `meetings`, `voice`, `background`, `calendar`, or `brain` (then `provider`).
An empty `model` goes back to the default. Turning confirmations off is only possible on the Mac (Settings → Voice).

### Meetings on the Mac

The Mac runs the meeting itself (its microphone and computer audio, live transcription, the meeting window), as when
the user presses Start and Transcribe in the meeting window. For a meeting heard by the phone, use the `meeting.*`
methods above instead.

| Action | `data` |
|---|---|
| `calendar.upcoming` | `events[]`: `{id, title, scope, date, start, end, attendees[], online?, status (scheduled/prepared/live/review/filed/cancelled), open}` sorted by date and start (`open`: its window is open on the Mac); `next` (the id of the one running, else the next to start; may be null) |
| `meeting.mac.start` | `meeting, title, transcribing` |
| `meeting.mac.note`, `meeting.mac.stop`, `meeting.mac.file` | `meeting` (`stop` also `stage`) |
| `meeting.mac.transcribe` | `transcribing` |
| `meeting.mac.status` | `meeting, title, stage (prepare/live/summarizing/review/filed), transcribing, lines, notes, started?, transcript[]{time, speaker, text}` (the last 40 lines), `proposals[]` (entries, in `review`); `{}` when no meeting is open |
| `meeting.create` | `meeting` |

`meeting.mac.start` without `event` starts a new meeting now ("Quick chat 14:05" unless `title` is given); with
`event` it starts that calendar meeting. It transcribes unless `transcribe` is false; when the user hasn't turned the
Mac's reminder off, `speech` ends with "Tell everyone it's being transcribed." `meeting?` left out in the others means
the meeting running on the Mac (the most recent when several are open). After `meeting.mac.stop` the stage is
`summarizing` and then `review`: show `meeting.mac.status` `proposals`, then `meeting.mac.file` files the summary and
the proposals (all are kept; untick them on the Mac to leave some out). The `meeting.changed` event fires for these
too. Past meetings: `meetings.list` (a day), `entry.read`, and the `meeting.get` method.

### Navigation

`app.show` `screen` is one of: `today`, `timeline`, `project`, `sessions`, `reminders`, `goals` (`id?`: a goal to select), `prs`, `overview`,
`decisions`, `meetings`, `facts`, `architecture`, `followups`, `backlog`, `discussions`, `ideas`, `research`,
`references`, `inbox`, `build`, `factory` (`id`: a factory id or name), `session` (`id`), `test` (`id`: a scope),
`strategies` (`id`: a slug to select), `settings` (`id`: `general`, `appearance`, `knowledgeBase`, `ai`, `meetings`,
`sources`, `connections`, `voice`, `remote`, `shortcuts`, `about`), `entry` (`id`: an entry id), `meeting` (`id`: opens
its window), `ask` (`id?`: the scope to ask in), `assistant`. It brings Mindmill on the Mac to the front there: for "show me the backlog" said to
the Mac, or a "Show on Mac" button on the phone.
