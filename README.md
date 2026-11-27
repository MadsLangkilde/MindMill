# Mindmill

A per-project knowledge base for Claude Code: decisions, meeting notes, facts and architecture notes,
kept as Markdown in a git repo you own. **Mindmill** is the macOS app that browses and edits it, plans and builds
the work with Claude sessions, and keeps meetings, follow-ups and the backlog together. The Claude Code plugin and
its command line are called `kb`.

- **Session start:** Claude loads the index of the project you're in, plus related projects for reference.
- **Task start:** Claude opens with a short *From the KB* brief when something is relevant.
- **You overrule the KB:** Claude does it your way and records a new decision that supersedes the old one.
- **Meetings:** `mindmill:meeting` prepares questions and flags conflicts in one or two lines while you take
  notes. When you're done, it files the notes and decisions into the project.
- **Editing in the app:** whatever is on disk is the truth. The next prompt in a running session is told
  which entries changed.

Projects never mix. Each has its own folder, the app shows one project at a time, and the CLI refuses to
write outside the session's project without `--cross-project`.

## Install

**On a new Mac:** open `Mindmill-<version>.dmg`, drag Mindmill to Applications and open it. Mindmill isn't notarized yet, so the
first time macOS asks: System Settings → Privacy & Security → **Open Anyway** (or right-click Mindmill → Open). Nothing
else is needed up front: the plugin is inside the app.

The first time it opens, Mindmill walks through setup:

1. **Your AI.** Pick the brain (Claude Code today), and optionally other models for specific tasks. Mindmill checks it's
   installed (and offers to install it in Terminal), that you're signed in, and that Python 3 is there (it offers
   Apple's command line tools). **Add to Claude Code** also makes `/mindmill` work in Terminal and your editor.
2. **Knowledge base.** Where it lives, and a first project.
3. **Your tools.** Where you track work (Azure DevOps, Jira, GitHub, Linear or Mindmill's own tracker) and mail, calendar,
   chat and docs. **Set Up with Claude** starts a session that checks each tool, helps you connect what's missing and
   saves Mindmill's settings.

Run it again from **Mindmill → Set Up Mindmill…**, or **Settings → Connections** for just the tools. **Settings → AI** changes
the brain and the model per task.

**Building it:** `macos/build.sh --install` puts `Mindmill.app` in `~/Applications`; `macos/package.sh` builds the DMG in
`macos/build/`. Set `KB_SIGN_IDENTITY` to sign with a Developer ID. **Settings → AI → Plugin folder** points Mindmill at a
checkout you edit instead of the plugin inside the app.

**Only the plugin**, without the app:

```
/plugin marketplace add <path to this repo>
/plugin install mindmill@mindmill
```

The knowledge base defaults to `~/projects/knowledge`. Change it in `~/.config/kb/config.json`
(`{"root": "…"}`, shared with the app) or via `/plugin configure mindmill`. `/mindmill` opens the app on the current project.

## Skills

| Skill | Use |
|---|---|
| `/mindmill` | Open the app, search, list, add facts, sources and settings, register a project |
| `mindmill:ask` | Answer a question from every source: the knowledge base, code, related projects, wiki, work items, Teams, email, docs, MCP, commands |
| `mindmill:brief` | What the KB says about the task at hand |
| `mindmill:decide` | Record a decision, supersede one, or propose one to the inbox |
| `mindmill:calendar` | Mirror today's and tomorrow's events (Outlook or Google Calendar) as meeting files |
| `mindmill:email` | Propose reminders from new email that needs you, keep open discussions up to date; skip newsletters and notifications |
| `mindmill:reference` | Save a copy of an email or a chat (Teams, Slack) in References, without email addresses |
| `mindmill:discussion` | Track an email thread or chat that isn't settled: points, open questions, findings; file the findings when ready |
| `mindmill:goals` | Coach personal long-term goals: what it takes, next steps, progress, and proposing progress you made |
| `mindmill:idea` | Brainstorm ideas and turn them into backlog items, facts, decisions, follow-ups, architecture notes or a new project |
| `mindmill:research` | Research a question with Claude, alone or for a PBI, idea or discussion; finish with a summary, takeaways for the PBI and proposed facts |
| `mindmill:prep` | Prepare any meeting: looks back at the series and what happened since, then topics or questions |
| `mindmill:meeting` | Capture notes live and propose the outcomes through the inbox |
| `mindmill:today` | Morning routine: day plan, prepared meetings, backlog proposals |
| `mindmill:work-item` | Draft, propose or create PBIs and bugs step by step; learns each project's tracker, sprints, team and conventions |
| `mindmill:create-pbi` | `/mindmill:create-pbi [<follow-up id>]`: the guided create flow of `mindmill:work-item` |
| `mindmill:write-as-me` | Write an email, chat message or other text in your style for that receiver, learned from what you sent them |
| `mindmill:migrate-memory` | Move project knowledge out of auto-memory, in batches you approve |

## The app's day

When Mindmill opens on a new day it syncs your calendar and then runs the morning routine. The sync repeats
every 30 minutes, so new, moved and cancelled meetings show up under **Today → Meetings**. Every meeting has
**Prepare** (Claude looks back at earlier meetings in the series and drafts topics or questions) and
**Take Notes** (the meeting companion flags conflicts in a line or two, and Done proposes the outcomes for
review). **Transcribe** in the meeting window turns the audio into text on your Mac (your microphone as
"You", the call as "Others", Danish or English); the companion reads it alongside your notes and the summary
uses it to fill gaps. Audio is never stored. **Read Along With a Window or Screen** (follow a window or screen) picks one window (the call, the shared
slides) or a whole screen, and ⋯ → **Choose an Area…** narrows it to a part you drag out; Mindmill reads its text on
your Mac when it changes and adds what is new to the transcript as "Screen". **Show Claude This** sends Claude
one picture of it (the area, when one is chosen), deleted after it is read; **Show Claude Each New Slide** does
that by itself when it changes a lot, at most once every 45 seconds (on by default). A red dot and a status line show that it is following, when it last found new text, and when Claude last saw a slide. **Materials** (in prep and live) takes files and links for the meeting: Mindmill keeps a copy of each file with the meeting, Claude reads each one, notes in a line what matters, and uses them during the meeting and in the summary; a page that needs a sign-in can be shared through Mindmill's browser. While Claude writes the summary after **Done**, the meeting shows as **Summarising** everywhere until the review is ready. Tell the attendees before you start. Meetings that aren't in the calendar: **New Meeting**.

**Reminders** (⌥⌘R) are personal to-dos with a due date (Today, Tomorrow, In a week, or a date). The morning
routine and the envelope button scan new email and *suggest* reminders, which you Add or Dismiss ("Never from
…" stops a sender). Anything in the app (an entry, a meeting, a reminder, a line in the day plan) has
**Ask Claude About This** in its right-click menu.

**Goals** are personal long-term goals, such as your next career step. Each has a coach (**Suggest Next Steps**
finds small steps that ride on your meetings, work items and plans) and a progress log. Ticking a suggestion only
marks it done; its add button puts it in Progress. Suggestions and Progress lines are edited in place (pencil or
double-click), and you can add steps of your own. The morning routine and **Find Progress** look at what you
finished (PRs, work items, meetings, decisions) and put what counts under **Proposed for Progress**, to add as it
is, edit first, or dismiss. Active goals stay a
side agenda: at most one quiet line in a session brief, in a meeting's prep and in the day plan, and never
during a live meeting. When Microsoft 365 needs signing in, Mindmill says
so and **Sign In** opens `claude /mcp` in Terminal.

## Inbox, backlog and follow-ups

Claude never quietly adds something you didn't ask for. Meeting outcomes, decisions it noticed and
morning-routine ideas go to the project's **inbox**, and you approve them in the app or with
`kb inbox approve`. Proposed PBIs and bugs wait under **Backlog → Suggested backlog items** until you
create them (`kb backlog create <id> --yes`). When you file a meeting, the backlog items you ticked are
offered at once: pick each one's sprint, assignee (a name; it is sent to Azure DevOps as that person's
email) and parent, then Create, or Not Now to leave them waiting. The meetings list opens on **Today**, with
pills for Earlier, Yesterday, the days ahead, Later and All. Open questions and action items are **follow-ups** until closed. They keep themselves current: when you save a fact, decision, meeting summary or another follow-up, a background check closes the follow-ups it settles (marked **by Mindmill**, with what settled it) and notes what changes the ones that stay open; closed ones move to **Handled** (Resolved or No longer needed), where **Reopen** puts one back. **Check Now** runs it against the last 30 days.
`kb tracker sprints|areas|features|items|item|people` reads the tracker so the skills offer real choices.

**Discussions** hold what people are still working out, often an email thread or a Teams chat: who said
what (Points raised), Open questions, Findings, and the Outcome once it settles, plus who it's waiting on.
**New Discussion** has Claude find the thread from a few words; the email scan adds new replies to the
ones it tracks. **Work on It with Claude** thinks it through with the KB and code, and **File the
Findings** proposes facts, decisions, follow-ups and backlog items to the inbox, each linked back to the
discussion. Open discussions are in every session's context, marked as not settled.

**Ideas** are yours to write down and grow: **Brainstorm** thinks one through with Claude (thoughts, open
questions, next steps), and **Turn Into** drafts backlog items, facts, a decision, follow-ups or an architecture
note for you to approve, or sets up a new project in Mindmill. Ideas that span projects go in the Overview scope.
Discussions are different: they follow a thread with other people (mail, Teams) that isn't settled yet.

**Research** (next to Ideas) is looking into a question with Claude. Start one from a thought (+), or from a PBI,
an idea or a discussion (**Research…**); each research has its own session, and Claude writes findings, open
questions and sources into it as it goes. **Finish…** has Claude write a summary and takeaways and propose facts;
you then tick which takeaways go on the PBI (its description or a comment; for an idea or discussion, its body)
and which facts to keep. Everything stays in the research. A Build session can be moved to Research from its
**⋯** menu, and one that reads like research (and has changed no files) asks once whether to move it.

**Architecture** has the KB's notes and **Project Docs**: the documentation in the scope's repository (Add →
Scan the Repository finds docs/, READMEs and other Markdown). Read and edit them in Mindmill, draw Mermaid diagrams
(**Add Diagram…**, **Edit diagram** under each one, or **Insert Diagram…** while editing any entry: by hand, from a
template, or described to Claude). Edits stay drafts in your private folder; **Save to Project…** hands them to
a Build session that branches, commits, pushes and opens the pull request the way the repository does it.

**Backlog** groups every PBI and bug by who has it, then by stage: Ready to start, In progress, In PR,
Resolved. Only items nobody has started offer **Implement**; ones under way offer **Continue**. Implement (and a
factory starting an item) moves it to its tracker's in-progress state: Committed, Active or Doing in Azure DevOps
(`kb tracker start <id>`), Committed in Mindmill's own tracker, and for Jira, GitHub or Linear the session does it first
with Claude's connector. Each shows
its tasks (done, in progress); **Tasks to close** at the top lists resolved or done items whose tasks are
still open, to mark them Done (`kb tracker task-state`). The sprint pills show the current and next
sprint and only those past sprints with work left in them; **Older sprints** opens any other past sprint
with everything finished in it (`kb tracker backlog --sprint`). A past sprint offers **Move N to
<current sprint>**, and any item can be moved to a sprint or set to a state from its page or right-click
menu (`kb tracker move`, `kb tracker state`).

**Sprints.** Mindmill reads each tracker's sprints (`kb sprint status`) at launch, on Sync, with the morning routine
and hourly, and remembers the last one it saw in Application Support. When a new sprint starts, or the last one ends
with nothing after it, a card in Build and Today offers **Review <sprint>…**: every item the sprint left unfinished,
yours by default (or with unassigned ones, or the team's), with its state, assignee, open tasks, PRs and session, and
a suggested decision you can change: done in the process's own state names, move to the new sprint, back to the
backlog, or remove. **Apply** asks once for the batch, writes each item on its own (`kb sprint apply`) and shows
each result, with **Retry Failed**. **Not Now** brings it back tomorrow. Mindmill's own tracker can add the next sprint
(`kb sprint create`); for Azure DevOps the card opens the iteration settings. Jira's sprints are only reachable
through Claude, so for Jira **Review Last Sprint** starts a session that does the review with its connector.

**Ready to Start** (Build's sidebar) lists what can be started now in the current sprint: not started, no session on
it yet, filtered by **Assigned to me**, **Me + unassigned** or **Everyone**, and by PBIs, bugs and tasks, remembered
per scope. **Start…** is the usual Implement; an unassigned item is assigned to you as it starts. It uses the same
rules as a software factory, so both agree on what is startable.

Every list has its own search field that filters just that list; the toolbar search still looks through
everything. Searching Backlog or the toolbar also asks Azure DevOps (`kb tracker backlog --search`), so
finished items and older sprints turn up too, and **Show in Backlog** opens an item in its sprint.

**Pull Requests** (Plan → Work, and My Work → In PR in Build) lists your open PRs with open comments,
votes, checks and what blocks completing. A PR's page shows every comment thread to reply to or resolve
right there, **Go Through Comments with Claude** (a Build session that proposes fixes and replies and asks
before changing, pushing or posting), and **Complete…** (merge type from the branch policy, delete the
branch, or set auto-complete). After completing, Mindmill offers to clean up: remove the worktree, delete the
local branch (only when that loses no commits, unless you tick it anyway) and the server branch (kept by
default for release, test, staging and hotfix branches), and archive its sessions. **Not Now** keeps it
under My Work → In PR → Merged · to clean up, where **Clean Up All…** does several at once (only what loses
nothing). A session whose PR is approved but blocked by a build or merge conflicts shows **Approved**, with
**Fix Blockers**. Beside any session's status, a pulsing **Merge conflicts** or **Build failed** (or a quiet
**Build queued**) says what holds its PR up. An approved PR waiting for its build shows **Build queued** or **Building**,
never both. When a build's result has expired, the PR shows **Build expired** and Mindmill runs the build again by itself
(`kb pr checks <id> --requeue-expired`, at most once every 15 minutes per PR). Each work item (and its PR) has one session in the list: a second
one on the same work, such as going through the PR's comments, starts under it as a helper, and the first
becomes its lead. Sessions that were already doubled up move under the one that implemented the item. A helper
on comments is archived once they're answered. Pull requests are re-read every three minutes while Build is in
front, and whenever you switch back to Mindmill. When approved PRs are stuck on a failed, expired or queued build or merge conflicts, Mindmill
reports the list to the overview session (and My Work → In PR offers **Fix Them All…**); say yes there and one
session works out their order, merges and fixes, re-runs builds (`kb pr checks <id> --requeue`), completes
them and cleans up. `kb pr list|show|checks|reply|thread|complete|done|cleanup`.

## Finding things and settings

**Fixing a PR from its session:** a session whose PR has merge conflicts shows a red bar with **Resolve Conflicts**:
Claude merges the target branch in, asks about any conflict whose intent is unclear, builds, tests and pushes. The
session header's **!<PR>** menu (beside Strategy) and a right-click on the session in the list offer every fix for its
PR: resolve conflicts, fix or re-run the build, show or handle comments, complete it, open it.

**Reviews and votes:** a review session always ends by asking which vote to cast (Approve, Approve with suggestions,
Wait for author, Reject or Don't vote) and casts it only after you pick (`kb pr vote <id> --vote …`). The session
header's **Vote** menu and a right-click on the session cast one any time.

**Cleaning up after a merge:** Clean Up removes only what loses nothing; **Clean Up Anyway…** removes the rest after a
confirmation that lists what it loses (uncommitted changes, commits the PR didn't take, a kept test or release
branch); a branch checked out in your main checkout is freed by switching that checkout to the PR's target branch,
carrying its uncommitted changes along. Tick **Clean up merged pull requests by themselves** in the clean-up sheet to
have Mindmill do the safe part without asking whenever a PR merges.

**Layout:** the overview session's *Waiting on you* panel sits above the input on the right; drag its handle to the
top or the left, or right-click it to move it back. **View → Reset Plan/Build Layout** and **Reset All Layouts** (also in
Settings → General) put columns, sidebar order, folded sections and panel places back the way Mindmill comes.

**Sessions sync for themselves:** when a session needs something that may have changed (a moved meeting, a new PR),
it runs `kb sync calendar|email|tracker|prs` (`--from`/`--to` for days further ahead): the app syncs and the session
reads again, instead of asking you to.

**When a tool stops working:** Mindmill checks `claude mcp list` at launch, when you come back to it and after a failed sync.
A tool Mindmill uses that is signed out or failing (a password change signs Microsoft 365 out) shows in a banner at the top
of the window with why and the fix: **Reconnect…** opens claude.ai's Connectors page (or `/mcp` for other servers),
**Check Again**, and **Troubleshoot with Claude** starts a session that tests each tool and walks you through it.
Once it works again, Mindmill syncs the calendar by itself. Settings → Connections shows the same, per tool.

**Attachments in sessions:** paste files (⌘V after copying them in Finder, one or many), a picture you copied in a
browser, or drop files and images on the input box, or use the paperclip. They wait above the box until you send,
and show with your message. Claude sees images directly and reads the other files from where they are; a pasted
picture is kept with the session's data until the session is deleted.

**⌘F** searches where you are. In Plan it puts the cursor in the search field: type words, and when you only
vaguely remember something, describe it: **Close matches** lists entries with most of the words (or words that
start the same way), and **Ask Claude to find “…”** has Claude search with other words, synonyms and both
languages, listing what it found with why. In Build, ⌘F opens a find bar in the session in front (↩ next,
⇧↩ previous, ⎋ closes) and highlights the messages that match; with no session in front it goes to the
session list's search.

**Settings** (⌘, or the gear in the toolbar): General (where Mindmill opens, the morning routine, calendar sync),
Appearance, Knowledge Base, Claude, Meetings (transcription language and sources, the live model), Sources,
Connections, Shortcuts (every shortcut, read from the menus, searchable) and About (version, build, and where
everything is).

**Appearance** picks light or dark and a theme from a list with a preview of each (Mindmill, System, Ocean, Forest,
Sunset, Lavender, Paper, Graphite, High Contrast), or your own colours: accent, selected item, sidebar background,
text and icons, content background and text. A theme with its own backgrounds picks light or dark itself.

**Connections** shows the tools Mindmill reaches through Claude (Jira and Confluence, Microsoft 365 for Outlook, Teams
and calendar, Gmail and Google Calendar, Slack, GitHub, Linear, Figma) and whether Claude is connected to each,
read from `claude mcp list`. Connect opens claude.ai's connectors; **Add a Tool…** adds an MCP server by address
for every project (`claude mcp add --scope user`). It also lists how each scope tracks work, with a link to change it.

## Mindmill's own tracker

For work you don't want in Azure DevOps or Jira, set a scope's tracker to **Mindmill's own tracker** (scope settings →
Tracker). Backlog then lists features, PBIs, bugs and tasks as a tree (add them in the field at the top, or from
an item), and the right side shows a **board** with New, Approved, Committed and Done; drag a card to move it.
An item has a state, a feature (or a PBI or bug for tasks), an optional sprint, assignee, effort and tags, a
description, acceptance criteria (and steps to reproduce for bugs), and its tasks as checkboxes. Sprints are
optional (Backlog's ⋯ → Sprints…). **Implement…** starts a Build session with the item's text, and its PBIs and
bugs show in My Work. Everything lives in the scope's folder as `work.json`; Claude uses it with `kb work`.

## Projects and scopes

A **project** (such as Acme Go) is split into **scopes**: Product-wide (always there), Android, iOS, Vault,
Comet, Localization catalog. Each scope is a folder in the knowledge base and maps to its repos. An entry lives in one
scope and can be tagged with others (`scopes: [acme-go, contoso-android]`) so it shows up in each, and Claude
tags what it writes: a product-wide fact with Android details gets both. Add your own projects and scopes
with `kb project add` and `kb scope add`, or in the app.

**Where knowledge lives.** In the split layout (`kb layout migrate --to ~/knowledgebase`), every entry lives in
`~/knowledgebase/<scope>/`, so the KB always has everything whatever branch a repository is on. An entry is
**private** (only there) or **shared**: shared ones also have a copy in the scope's repository,
`<repo>/knowledgebase/`, committed with the code and part of the pull request of the work it comes from. New
decisions, facts, architecture, follow-ups and backlog items in a scope with a repository are shared; meetings,
discussions, the inbox and notes are private. Each entry shows a small icon (lock: private; orange arrow: shared
but not committed or not pushed yet; green people: shared and pushed, so others can see it), with hover text
that says which, and **Sharing** in its header and right-click menu switches it. `kb share status`, `kb share set
<id> private|shared` and `kb share sync` do the same from the command line. The copies are kept in sync in the
direction the change was made: a teammate's entry or edit that arrives with a pull is copied into the KB, an
edit saved in the app goes to the main checkout's copy, and a session's edit in a worktree goes only to that
worktree's copy. After a branch switch the KB keeps its copies, and a shared entry the branch doesn't have is
marked "not on this branch" rather than put back. What spans projects (kb.json, daily plans, reminders, goals,
people) is in `~/knowledgebase/shared/`. The **Overview** scope has no repo, stays private, and shows everything
in Mindmill. `kb layout show` prints where each scope's folders are.

**Projects, locations and scopes.** **New Project…** and **Edit Projects and Scopes…** (the project menu in the
toolbar, the sidebar's project name, or View) open one editor: the project's name, its **locations** (the
folders its code is in, each with a name; at least one for a new project, and each new one can get a scope of
its own) and its **scopes**. A scope says which locations it **works in**, which other scopes of the project it
**also shows** (worked on together, such as a Mobile scope over Android and iOS) and what it only takes
**knowledge from**, from any project: read only, so
sessions read that code and the knowledge base but never change, branch, commit or open pull requests there. Sessions in the
scope start in the first repository it works on and can reach all of them. **Project** shows the scope's
repositories with their branch and how far behind they are; **Pull** (or **Pull All**, or View → Pull
Repositories of This Scope) fast-forwards them and never merges or overwrites local work. Sessions can do the
same with `kb repos --fetch` and `kb repos pull [--repo <scope>]`.

**Switching project:** the toolbar's project menu (Plan and Build) lists every project and its scopes;
⌃⌘1–9 switch to a project on the scope last used there. **Project** (top of the Plan sidebar) lists the project's repositories, whether each is on this Mac, and the
team knowledge already in its `knowledgebase/` folder. **Add Locations…** and **New Project…** take folders;
a `knowledgebase/` folder in them shows up in Mindmill at once. On a new Mac, **Create a Knowledge Base Here** makes an
empty knowledge base, and **Locate…** points a scope at its checkout. **New Scan…** has Claude read repositories (docs, code
and comments, git history, work items and PRs, what the KB already says) for everything or only what you tick:
overview, decisions, facts, architecture, open questions, backlog ideas, Project Docs, with an optional focus.
Each repository gets its own read-only session; findings appear as it records them (`kb scan found`), with
where each was found and whether it corrects an existing entry. Tick what you want and **Add to the Knowledge Base**; the rest
can be dismissed. Nothing goes in unticked. `kb scan new|found|progress|done|apply|dismiss|list|show`.

## Plan and Build

The app has two modes, switched in the toolbar. **Plan** is knowledge and planning: Today, meetings,
decisions, facts, follow-ups. **Build** is implementation: an **Overview** session on top that knows every
session, leads with sessions under them, all started, watched, messaged and stopped from the app
(sessions steer each other with `kb crew`).

The two feed each other through the facts. When a meeting, a decision or a Build session suggests a fact
no longer holds, the fact is flagged **may have changed** (`kb fact challenge`) and stays flagged on the
fact until you decide: **Update**, **Still true**, **No longer true** or **Clarify with Claude**. The other
way round, what Build sessions and pull request reviews learn about the product and its code (how a part
works, a convention, a pitfall) is proposed as a new fact. Proposed facts wait at the top of **Facts**, not in
the Inbox, until you **Approve** or **Decline** them; the Facts badge and Today count them.

**Strategies** are optional: pick one in a new session's "How do you want to work on it?" (Auto crew first; it starts with your first message), or later from **Strategy** at the top of a session (**Auto crew** starts sessions by itself,
**Plan first**, **Builder + reviewer**, **Tests first**), and add your own under Build → Strategies…
(`kb strategy`). Switch with ⌃⌘P and ⌃⌘B; ⇧⌘L starts a new lead.

**My Work** (Build sidebar) has tabs: **New** (assigned and not started), **In progress**, **In PR** (each
PR's state, **Complete…** when it is ready, PRs without a work item, and merged PRs still to clean up) and
**To review**; New and In progress show this sprint or all. A work item's button says whose turn it is:
**Implementing…** only while its session works, the question when it needs you, and **Open Session** when it has
stopped; a PR that only waits on others says so ("Waiting for Anna and Ben to approve · nothing for you to
do"), while comments, a failed build or a conflict show in orange. Each Build session shows its status: Needs
input or Needs permission (pulsing, and counted on the Build switch), Running, Ready to complete,
Comments to answer, Completing (auto-complete is set), Building (approved, only waiting for its build), In review,
Draft PR, Idle, Not running, Done. A session is Done as soon as its PR completes, even before the work item moves; it
then asks "Archive this session?" (Archive or Keep), in the session and in the Overview, and is archived by
itself only if nobody answers for three days. The sidebar has a section per scope (with its
project, a count and how many need you), so it is always clear which project a session (and its PR) belongs
to; fold a section by its header. When a session's PR is ready to complete, the session asks you above the
message box (Complete…, Open PR or Not Now), and a lead asks for the PRs of the sessions under it too. Whatever
waits on you is also answerable from the **Overview** (every session that needs you, plus factory questions)
and from a lead (the sessions under it): a **Waiting on you** panel shows each question with its choices, a reply
box and Allow for refused tools, so you can answer there or in the session itself. A session shows **Needs input**
only when its last reply ends with options to click; when one ends with a bare question instead, Mindmill asks it once to
put the question as options (or say it wasn't for you), so a question for a colleague never flags you. Sessions
whose work is done move to
**Archived** in the sidebar; Archive and Move Out of the Archive are in their menus. **Implement** starts the
repo's `/implement` skill, which asks you along the way. Its arrow switches to **Implement Fast**
(`/implement-fast`), which keeps going until the PR is ready. **Review** opens `/review-pr` for a PR
waiting on you. Same data on the command line: `kb tracker mine`.

**Software Factory** (Build sidebar, under Overview) picks up work items and builds them, one after
another, by rules you set in **Edit Rules…**. Beside the rules, **What it will do** shows the steps each
item goes through under them, with where it asks you; pointing at a section explains it and lights its step.
- **Work it takes:** the scopes, whose items (yours, also unassigned ones that it assigns to you first with
  `kb tracker assign`, or only unassigned), PBIs and/or bugs, which sprint, whether it continues your items
  already in progress, and how many at a time. It never takes someone else's item or one a session works on.
- **How it builds:** the default strategy (**New Strategy…** makes one and uses it), and what happens when
  the code is done: push the branch, open a pull request, or open and complete it once approved.
- **Exceptions to the default strategy:** "When the item is a bug / has the tag … / its title contains …,
  use …"; the first that fits decides.
- **New work items:** off, or **Create new work items** (assigned to you, then picked up), optionally
  asking before each one (the question waits under Needs you with Create it / Leave it).
- **When it asks you:** off (it notes its assumptions instead), or on with the moments ticked: when unsure,
  before starting, plan ready, missing knowledge, several good ways, tests failing, before the PR, before
  merging, plus your own. **Edit Texts…** changes what the sessions are told for each and manages your own.
- **How long it runs:** until you stop it, for some hours, or until a time. Stop starts nothing new; the
  sessions finish the step they're on and push. **Start** after a stop carries on the same run: the board, open
  questions and activity log stay, and the end time counts from then. A new factory starts empty.

Factories are listed under **Software Factories** in Build's sidebar (rename one by clicking its name). Each
item gets its own session with a brief built from the rules. The factory's view is a dashboard the factory
keeps its own way (**Customize**: drag or move panels, full or half width, fold them, add or remove them):
the **Board** (Up next → Working → Needs you → In review → Done; cards slide between lanes, and a click
shows the item's **details**: what its session does, its pull request and timeline), **History**, **To
approve** (facts and work items the sessions proposed), and optionally the questions, numbers and rules.
Questions (`kb factory ask`) don't block: the session carries on with what it can. **Answer** on the Needs you
lane, or the question button on a card, shows them with the work item they're about (its description and
criteria from `kb tracker item --json`, and **Open PBI/Bug**), its options, a free answer, or **Let It
Decide**; a **Catch-up** (what the session did and decided, from a throwaway copy of it) and follow-up questions come first. When something you answer, or a new fact or decision, already settles another open question (in any factory), it is answered for you: the session is told, and it shows under **Answered for you** to dismiss or add to. When a fact or decision changes while it runs, or you change the rules, the sessions at work are
told. `kb factory status` shows the same from the command line.

**Drafts.** An entry you add by hand starts as a draft with a **Save** button under the editor. Switching
away keeps it under **Drafts** at the top of its section until you save or discard it; Claude doesn't see
drafts.

**Several at once.** ⌘-click or ⇧-click entries in a list to act on all of them: **Ask Claude about
these** (for example "these facts seem to contradict each other; check other sources"), mark follow-ups
done or dropped, move, delete, or start a lead on them in Build.

## Claude sessions

The sparkles button (⇧⌘K) opens a Claude session window: a formatted conversation in the project's
working directory where Claude can run any skill (type `/` to pick one). Questions come as clickable
choices, tool calls fold into one line, and a refused tool can be allowed for that session. **Create PBI…**
on a follow-up or decision, and **Work on It with Claude…** on entries, reminders, goals and Today items,
start one with that context. Sessions are kept for 30 days and continue with `claude --resume`, also from
Terminal (session menu → Continue in Terminal). **Cancel and Edit** under a message you just sent takes it
back into the input box: still waiting, it never reaches Claude; already started, Claude stops and is told to
ignore it.

**Sessions** (top of Plan's sidebar, under Overview) lists Plan's sessions in the main window, for this scope or all scopes, grouped as
**Work items** (creating PBIs and bugs: Drafting, or Created #id), **On entries** (work on a follow-up, decision
and so on) and **Questions and research**; older ones fold away. The ones that need you count on the Plan switch
and on the sidebar row. A session that created a work item shows it with **Implement…**; the Build session that
starts links back with "Planned in …". Build's Overview says when Plan sessions wait on you, with Open in Plan.

When Claude fails to sign in (an expired login, or "Failed to authenticate" with a 403), a bar across the
window and a **Sign In Again…** button on the failed message open **Sign in to Claude**. It runs
`claude auth login`, which opens the browser like `/login` does; when Claude Code is already signed in it
offers **Restart Sessions** instead. Either way, the sessions that failed restart on the new login and send
the failed message again.

## References

**References** (in each scope) keep a copy of something you'll want again: a Claude artifact, an email, a
Teams chat, a web page, a document or a file, with a line on why it matters. Ask, briefs and sessions find
them with `kb search` and every session's context lists them.

- **Web page or Claude artifact:** it opens in Mindmill's own browser, where you sign in once (Add → Sign In Once
  for Claude or Microsoft 365) and Mindmill remembers it. **Save to References…** keeps the page's text. The same
  button is in every browser window opened from a chat. **Update Copy** on a saved one reopens it and
  replaces the text, keeping your note.
- **Email or Teams chat:** give a few words; Claude finds it, asks which one if several fit, and saves the
  thread without email addresses (`mindmill:reference`).
- **File:** PDF, Word, RTF, HTML, Markdown or text, from Add → File or by dropping it on the list. Dropping a
  link opens it in the browser to save.

## Knowledge sources

Ask uses the project's knowledge base, code and related projects, plus any sources you add, per project or globally:
folders, URLs, the Azure DevOps wiki, work items and repos, Teams, Outlook, MCP servers, or any shell
command (`{query}` is replaced). Each source's `use_for` line tells Claude when to use it.

```
kb sources add --global --kind url --title "Compose docs" --use-for "Jetpack Compose APIs" --config url=https://developer.android.com/develop/ui/compose
kb sources test <id> --query "…"
```

## Voice and the phone

**Talk to Mindmill** (⌥⌘V) opens the voice window: say what you want ("what needs me today?", "pause the nightly
factory", "add a follow-up for Anna about the release"), and the reply is spoken sentence by sentence while it is
still being written. Talk over it to interrupt. Voice uses the same actions as the buttons, so whatever it changes
shows in the app at once; stopping a factory or writing to the tracker is confirmed out loud first. The mic button
in a session's prompt dictates into it instead.

- **Built-in voice** (default, no setup): on-device speech recognition and the system voices, with the brain doing
  the thinking in one persistent session per conversation. Enhanced and Premium voices sound best; Settings → Voice
  links to where macOS downloads them.
- **Voice API** (optional): add a key for OpenAI Realtime, Gemini Live or xAI Grok Voice in Settings → Voice. Keys
  stay in this Mac's Keychain; the phone's audio goes through the Mac. If the API fails, voice falls back to
  built-in and says so.

**The phone apps** (Mindmill for Android and iOS, separate projects) connect to this Mac over the local network or Tailscale once paired in Settings →
Remote. It has the backlog, facts, follow-ups, meetings (with the phone listening to the room and sharing its
screen), sessions, factories, voice, and test builds and review cards from Build. The protocol is in
[docs/remote-api.md](docs/remote-api.md).

## Layout

See [docs/format.md](docs/format.md). In short: `kb.json` lists the projects (paths, git remotes,
related projects), and each project has `decisions/`, `meetings/`, `facts/` and `architecture/` of
Markdown files with flat frontmatter.

## Tests

```
python3 -m unittest discover -s tests
cd core && swift test     # KBCore and KBEngine, the code the Mac and Windows apps share
cd macos && swift test    # the app target's own tests
```
