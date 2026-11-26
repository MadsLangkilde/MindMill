import Foundation

/// One group of actions, as an action browser shows them.
public struct ActionArea: Equatable, Sendable {
    public var title: String
    public var actions: [ActionSpec]

    public init(_ title: String, _ actions: [ActionSpec]) {
        self.title = title
        self.actions = actions.map { var a = $0; a.area = title; return a }
    }
}

/// Everything in Mindmill that voice, the phone, the assistant session or a real-time voice model can do. Each one
/// runs the same app function its button runs, so what it changes shows in the app at once.
public enum ActionCatalog {
    static let scope = ActionParam("scope", "The project (scope) id or name; leave out for the current project.")
    static func id(_ about: String) -> ActionParam { ActionParam("id", about, required: true) }
    static let entryID = ActionParam("id", "The entry id, e.g. app/facts/2026-01-02-login", required: true)
    static let factory = ActionParam("factory", "The factory's name or id", required: true)
    static let session = ActionParam("id", "The session id", required: true)
    static let pr = ActionParam("id", .integer, "The pull request number", required: true)
    static let meeting = ActionParam("meeting", "The meeting's entry id; leave out for the meeting open on the Mac")
    static let owner = ActionParam("owner", "Whose work: me (default), meAndUnassigned or everyone",
                                   choices: WorkFilter.Owner.allCases.map(\.rawValue))

    /// The factory rule fields an action can set one by one; the phone's editor uses `factory.config.save` instead.
    static let factoryFields: [ActionParam] = [
        ActionParam("scopes", .strings, "Scope ids it takes work from"),
        ActionParam("assigned_to_me", .boolean, "Take items assigned to the user"),
        ActionParam("unassigned", .boolean, "Take unassigned items too (assigning them to the user first)"),
        ActionParam("pbis", .boolean, "Take PBIs"),
        ActionParam("bugs", .boolean, "Take bugs"),
        ActionParam("sprint", "Which sprints", choices: FactoryRules.SprintFilter.allCases.map(\.rawValue)),
        ActionParam("resume_started", .boolean, "Also the user's items already in progress that no session works on"),
        ActionParam("new_work_items", "What to do with new work it finds", choices: FactoryRules.NewWorkItems.allCases.map(\.rawValue)),
        ActionParam("questions", "When it asks", choices: FactoryRules.Questions.allCases.map(\.rawValue)),
        ActionParam("strategy", "Default strategy slug; empty for one session without a strategy"),
        ActionParam("checkpoints", .strings, "Checkpoints where it stops to ask: "
                    + FactoryCheckpoint.allCases.filter { $0 != .newWorkItems }.map(\.rawValue).joined(separator: ", ")),
        ActionParam("open_prs", .boolean, "Open pull requests"),
        ActionParam("complete_prs", .boolean, "Also complete (merge) them"),
        ActionParam("max_parallel", .integer, "How many work items at once (1–10)"),
        ActionParam("hours", .number, "Run for this many hours from when it starts; 0 runs until stopped"),
        ActionParam("until", "Run until this time (ISO 8601, e.g. 2026-11-23T18:00:00+01:00)"),
    ]

    public static let screens = ["today", "timeline", "project", "sessions", "reminders", "goals", "prs"]
        + KBSection.allCases.map(\.rawValue)
        + ["build", "ready", "factory", "session", "test", "strategies", "settings", "entry", "meeting", "ask", "assistant"]

    public static let areas: [ActionArea] = [
        ActionArea("Overview", [
            ActionSpec("overview", "What needs the user now: proposed facts, open follow-ups, their work items, factories and sessions waiting.",
                       params: [scope]),
            ActionSpec("projects.list", "The user's projects (scopes) and which one is current."),
            ActionSpec("project.select", "Make a project the current one on the Mac.", risk: .write,
                       params: [ActionParam("scope", "The project (scope) id or name", required: true)]),
            ActionSpec("app.show", "Bring the Mac app to the front on a screen, an entry, a factory or a session.", params: [
                ActionParam("screen", "Where to go", required: true, choices: screens),
                ActionParam("id", "An entry, factory, session or meeting id, or a settings tab (general, ai, meetings, voice, remote, connections…)"),
            ]),
            ActionSpec("sync.all", "Sync everything: knowledge base, tracker, pull requests and calendar.", risk: .write),
        ]),
        ActionArea("Knowledge", [
            ActionSpec("knowledge.search", "Search facts, decisions, meetings, follow-ups and notes.",
                       params: [ActionParam("query", "Words to look for", required: true), scope]),
            ActionSpec("entries.list", "Entries in one section, newest first.", params: [
                ActionParam("section", "Which section", required: true, choices: KBSection.allCases.map(\.rawValue)),
                ActionParam("query", "Only those matching these words"), ActionParam("tags", .strings, "Only with these tags"),
                ActionParam("limit", .integer, "How many"), scope,
            ]),
            ActionSpec("entry.read", "Read one entry (fact, decision, meeting, follow-up…) in full, to answer or summarise.",
                       params: [entryID]),
            ActionSpec("entry.create", "Write a new entry: a decision, fact, architecture note, idea, reference note…", risk: .write, params: [
                ActionParam("section", "Which section", required: true, choices: KBSection.allCases.filter { $0 != .inbox && $0 != .meetings }.map(\.rawValue)),
                ActionParam("title", "The title", required: true), ActionParam("summary", "One line"),
                ActionParam("body", "The text, in Markdown"), ActionParam("tags", .strings, "Tags"),
                ActionParam("fields", .strings, "Other frontmatter fields as key=value"), scope,
            ]),
            ActionSpec("entry.update", "Change an entry: title, summary, status, a field, or its text (replace or add to the end).", risk: .write, params: [
                entryID, ActionParam("title", "New title"), ActionParam("summary", "New summary"), ActionParam("status", "New status"),
                ActionParam("field", "A frontmatter field to set"), ActionParam("value", "The field's new value; empty removes it"),
                ActionParam("body", "New text (replaces it)"), ActionParam("append", "Text to add at the end"),
            ]),
            ActionSpec("entry.delete", "Delete an entry from the knowledge base.", risk: .destructive, params: [entryID],
                       confirm: "Delete {id}? Its file is removed (git history keeps it)."),
            ActionSpec("entry.move", "Move an entry to another project.", risk: .write,
                       params: [entryID, ActionParam("to", "The project (scope) id to move it to", required: true)]),
            ActionSpec("entry.tags", "Set an entry's tags.", risk: .write,
                       params: [entryID, ActionParam("tags", .strings, "All its tags", required: true)]),
            ActionSpec("entry.scopes", "Add or remove another scope an entry belongs to.", risk: .write, params: [
                entryID, ActionParam("scope", "The scope id", required: true), ActionParam("add", .boolean, "true adds, false removes", required: true),
            ]),
            ActionSpec("entry.share", "Share an entry with the team (into the repository's knowledgebase folder) or make it private.", risk: .write,
                       params: [entryID, ActionParam("shared", .boolean, "true shares, false makes it private", required: true)]),
            ActionSpec("entry.ask", "Open the Ask window on the Mac about an entry.", params: [entryID]),
        ]),
        ActionArea("Facts", [
            ActionSpec("facts.list", "Confirmed facts, newest first.", params: [scope, ActionParam("limit", .integer, "How many"),
                                                                                ActionParam("links", .boolean, "Also each fact's linked facts, as ids")]),
            ActionSpec("facts.proposed", "Proposed facts waiting for the user's yes or no.", params: [scope]),
            ActionSpec("fact.approve", "Approve a proposed fact.", risk: .write, params: [ActionParam("id", "The proposed fact's id", required: true)]),
            ActionSpec("fact.decline", "Decline a proposed fact.", risk: .write, params: [ActionParam("id", "The proposed fact's id", required: true)]),
            ActionSpec("fact.propose", "Propose a new fact for the user to approve.", risk: .write, params: [
                ActionParam("title", "The fact, as a short statement", required: true), ActionParam("body", "More detail"),
                ActionParam("reason", "Where it comes from"), scope,
            ]),
            ActionSpec("fact.links", "The facts linked to a fact.", params: [entryID]),
            ActionSpec("fact.link", "Link two facts, or unlink them.", risk: .write, params: [
                ActionParam("id", "One fact's id", required: true), ActionParam("other", "The other fact's id", required: true),
                ActionParam("remove", .boolean, "true unlinks them"),
            ]),
            ActionSpec("fact.links.suggest", "Ask for links to other facts to be suggested (they show on the Mac).", risk: .write, params: [entryID]),
            ActionSpec("fact.change.resolve", "Answer a fact change: update the fact, or keep it as it is.", risk: .write, params: [
                ActionParam("id", "The fact change's id", required: true), ActionParam("how", "update or keep", required: true, choices: ["update", "keep"]),
            ]),
            ActionSpec("fact.change.remove", "Answer a fact change with: no longer true. Removes the fact.", risk: .destructive,
                       params: [ActionParam("id", "The fact change's id", required: true)], confirm: "Remove the fact this change is about?"),
            ActionSpec("quiz.round", "Make a few quiz questions from the facts, to check what the user remembers.",
                       params: [ActionParam("count", .integer, "How many questions (default 5)"), scope]),
            ActionSpec("quiz.answer", "Record whether the user knew a fact in the quiz.", risk: .write, params: [
                ActionParam("fact", "The fact's id", required: true), ActionParam("correct", .boolean, "Whether they knew it", required: true),
            ]),
        ]),
        ActionArea("Follow-ups", [
            ActionSpec("followups.list", "Open follow-ups: on the user, waiting on others, or all.",
                       params: [ActionParam("filter", "Which ones", choices: ["mine", "waiting", "all"]), scope]),
            ActionSpec("followup.create", "Add a follow-up (an action or a question).", risk: .write, params: [
                ActionParam("title", "What needs doing or answering", required: true),
                ActionParam("kind", "action or question", choices: ["action", "question"]),
                ActionParam("owner", "Who it's on; leave out for the user"),
                ActionParam("due", "YYYY-MM-DD"), scope,
            ]),
            ActionSpec("followup.update", "Change a follow-up: close it, drop it, reopen it, or add a note.", risk: .write, params: [
                ActionParam("id", "The follow-up's id", required: true),
                ActionParam("status", "New status", choices: ["done", "dropped", "open"]),
                ActionParam("note", "A line to add under Updates"),
                ActionParam("answer", "The answer or what was done, when closing"),
                ActionParam("resolved_by", "A decision id or work item link that resolved it"),
            ]),
            ActionSpec("followups.duplicates", "Look for duplicate follow-ups; proposals to merge show on the Mac.", risk: .write, params: [scope]),
            ActionSpec("followup.merge", "Merge one follow-up into another.", risk: .destructive, params: [
                ActionParam("keep", "The id to keep", required: true), ActionParam("other", "The id merged into it and removed", required: true),
            ], confirm: "Merge {other} into {keep}?"),
            ActionSpec("followups.check", "Check whether open follow-ups were answered elsewhere (mail, chats, the tracker).", risk: .write, params: [scope]),
        ]),
        ActionArea("Discussions", [
            ActionSpec("discussion.start", "Find a discussion in mail or chats and start tracking it.", risk: .write,
                       params: [ActionParam("look_for", "What the discussion is about, or who with", required: true), scope]),
            ActionSpec("discussion.status", "Park, reopen or conclude a discussion.", risk: .write, params: [
                entryID, ActionParam("status", "New status", required: true, choices: DiscussionStatus.allCases.map(\.rawValue)),
                ActionParam("outcome", "What was concluded"),
            ]),
            ActionSpec("discussion.waiting", "Say who a discussion waits on.", risk: .write, params: [
                entryID, ActionParam("on", "Who", required: true, choices: WaitingOn.allCases.map(\.rawValue)),
            ]),
            ActionSpec("discussion.refresh", "Check a discussion for new replies.", risk: .write, params: [entryID]),
            ActionSpec("discussion.file", "File what a discussion found into the knowledge base.", risk: .write, params: [entryID]),
        ]),
        ActionArea("Ideas and Research", [
            ActionSpec("idea.status", "Set an idea's status.", risk: .write, params: [
                entryID, ActionParam("status", "New status", required: true, choices: IdeaStatus.allCases.map(\.rawValue)),
            ]),
            ActionSpec("idea.turn", "Turn an idea into a backlog item, fact, decision, follow-up, architecture note or project.", risk: .write, params: [
                entryID, ActionParam("into", "What it becomes", required: true, choices: IdeaOutcome.allCases.map(\.rawValue)),
            ]),
            ActionSpec("idea.brainstorm", "Brainstorm on an idea in a session.", risk: .write, params: [entryID]),
            ActionSpec("note.add", "Write a note down: a thought that doesn't belong anywhere yet.", risk: .write, params: [
                ActionParam("text", "What to note", required: true), ActionParam("title", "A short title"), scope,
            ]),
            ActionSpec("note.discuss", "Talk a note through in its session: it sums it up, checks with the user and suggests where things belong.", risk: .write, params: [
                entryID, ActionParam("spoken", .boolean, "The user talks out loud"),
            ]),
            ActionSpec("note.sort", "Suggest where each part of a note belongs (facts, decisions, ideas, follow-ups…).", risk: .write, params: [entryID]),
            ActionSpec("note.status", "Set a note's status.", risk: .write, params: [
                entryID, ActionParam("status", "New status", required: true, choices: NoteStatus.allCases.map(\.rawValue)),
            ]),
            ActionSpec("research.start", "Start researching a question.", risk: .write, params: [
                ActionParam("question", "What to find out", required: true), ActionParam("title", "A short title"),
                ActionParam("work_item", .integer, "A work item it is for"), ActionParam("entry", "An entry it is for"), scope,
            ]),
            ActionSpec("research.continue", "Carry on with a research.", risk: .write, params: [entryID]),
            ActionSpec("research.finish", "Summarise a research so its takeaways can be filed.", risk: .write, params: [entryID]),
            ActionSpec("research.status", "Set a research's status.", risk: .write, params: [
                entryID, ActionParam("status", "New status", required: true, choices: ResearchStatus.allCases.map(\.rawValue)),
            ]),
        ]),
        ActionArea("References", [
            ActionSpec("reference.save", "Save a link or a note to References.", risk: .write, params: [
                ActionParam("title", "The title", required: true), ActionParam("url", "The link"), ActionParam("note", "Why it matters"),
                ActionParam("kind", "What it is", choices: ReferenceKind.allCases.map(\.rawValue)), scope,
            ]),
            ActionSpec("reference.from_mail", "Find a mail or Teams chat and save it to References.", risk: .write, params: [
                ActionParam("look_for", "What to look for", required: true),
                ActionParam("kind", "email or teams", choices: ["email", "teams"]), ActionParam("note", "Why it matters"), scope,
            ]),
        ]),
        ActionArea("Reminders and Goals", [
            ActionSpec("reminders.list", "The user's reminders.", params: [ActionParam("status", "Which ones", choices: ["open", "proposed", "done", "all"])]),
            ActionSpec("reminder.create", "Add a reminder.", risk: .write, params: [
                ActionParam("title", "What to remember", required: true), ActionParam("due", "today, tomorrow or YYYY-MM-DD"),
                ActionParam("note", "More detail"), ActionParam("link", "A link"), ActionParam("scope", "A project it belongs to"),
            ]),
            ActionSpec("reminder.update", "Mark a reminder done, reopen, accept or dismiss it, or change its date.", risk: .write, params: [
                ActionParam("id", "The reminder's id (reminders/…)", required: true),
                ActionParam("status", "New status", choices: Reminder.Status.allCases.map(\.rawValue)),
                ActionParam("due", "today, tomorrow, YYYY-MM-DD, or none"),
            ]),
            ActionSpec("reminder.delete", "Delete a reminder.", risk: .destructive,
                       params: [ActionParam("id", "The reminder's id", required: true)], confirm: "Delete the reminder?"),
            ActionSpec("goals.list", "The user's goals and their latest progress."),
            ActionSpec("goal.create", "Add a goal.", risk: .write, params: [
                ActionParam("title", "The goal", required: true), ActionParam("horizon", "When, e.g. this quarter"), ActionParam("why", "Why it matters"),
            ]),
            ActionSpec("goal.status", "Set a goal's status.", risk: .write, params: [
                ActionParam("id", "The goal's id (goals/…)", required: true),
                ActionParam("status", "New status", required: true, choices: Goal.Status.allCases.map(\.rawValue)),
            ]),
            ActionSpec("goal.progress", "Log progress on a goal.", risk: .write, params: [
                ActionParam("id", "The goal's id", required: true), ActionParam("text", "What happened", required: true),
            ]),
            ActionSpec("goal.coach", "Ask the goal coach something about a goal.", risk: .write, params: [
                ActionParam("id", "The goal's id", required: true), ActionParam("text", "The question", required: true),
            ]),
            ActionSpec("goal.delete", "Delete a goal.", risk: .destructive,
                       params: [ActionParam("id", "The goal's id", required: true)], confirm: "Delete the goal?"),
        ]),
        ActionArea("Today", [
            ActionSpec("today.plan", "The day's plan: what to do today, what to decide, and the side goal.",
                       params: [ActionParam("day", "today, tomorrow, yesterday or YYYY-MM-DD")]),
            ActionSpec("today.check", "Tick an item of today's plan, or untick it.", risk: .write, params: [
                ActionParam("item", .integer, "The item's number from today.plan", required: true), ActionParam("done", .boolean, "Done or not", required: true),
            ]),
            ActionSpec("today.morning", "Run the morning routine: read mail and calendar and write today's plan.", risk: .write),
            ActionSpec("sync.calendar", "Sync the calendar into meetings now.", risk: .write),
            ActionSpec("sync.email", "Read new mail for reminders now.", risk: .write),
        ]),
        ActionArea("Meetings", [
            ActionSpec("meetings.list", "Meetings on a day, with their notes' status.",
                       params: [ActionParam("day", "today, tomorrow, yesterday or YYYY-MM-DD"), scope]),
            ActionSpec("calendar.upcoming", "Calendar meetings coming up, and the one running on the Mac.", params: [
                ActionParam("days", .integer, "1 is today, 2 adds tomorrow…"),
                ActionParam("scope", "Only this project; leave out for every project"),
            ]),
            ActionSpec("meeting.create", "Plan a meeting for later.", risk: .write, params: [
                ActionParam("title", "The title", required: true), ActionParam("date", "YYYY-MM-DD, today or tomorrow", required: true),
                ActionParam("start", "HH:MM"), ActionParam("attendees", .strings, "Who comes"), scope,
            ]),
            ActionSpec("meeting.prepare", "Prepare a meeting with the brain: questions and what to know, in its window on the Mac.", risk: .write,
                       params: [ActionParam("meeting", "The meeting's entry id", required: true)]),
            ActionSpec("meeting.mac.start", "Start a meeting on the Mac now: opens its window, takes notes and transcribes live.", risk: .write, params: [
                ActionParam("event", "A meeting id from calendar.upcoming; leave out for a new meeting"),
                ActionParam("title", "The title of a new meeting"),
                ActionParam("transcribe", .boolean, "Transcribe live (default yes)"), scope,
            ]),
            ActionSpec("meeting.mac.note", "Add a note to the meeting running on the Mac.", risk: .write,
                       params: [ActionParam("text", "The note", required: true), meeting]),
            ActionSpec("meeting.mac.transcribe", "Turn live transcription on or off in the meeting on the Mac.", risk: .write,
                       params: [ActionParam("on", .boolean, "On or off", required: true), meeting]),
            ActionSpec("meeting.mac.stop", "End the meeting on the Mac and write its summary and proposals.", risk: .destructive,
                       params: [meeting], confirm: "End the meeting on the Mac and write its summary?"),
            ActionSpec("meeting.mac.file", "File a reviewed meeting: its summary and the proposals left ticked.", risk: .write, params: [meeting]),
            ActionSpec("meeting.mac.status", "The meeting open on the Mac: its stage, transcript and notes.", params: [meeting]),
        ]),
        ActionArea("Backlog", [
            ActionSpec("backlog.list", "Work items (PBIs and bugs) from the tracker.", params: [
                ActionParam("mine", .boolean, "Only the user's"), ActionParam("state", "Only this state, e.g. New, Active"), scope,
            ]),
            ActionSpec("workitem.get", "One work item in full.", params: [ActionParam("id", .integer, "The work item number", required: true), scope]),
            ActionSpec("workitem.search", "Find work items in the tracker, finished ones too.", params: [ActionParam("query", "Words or a number", required: true)]),
            ActionSpec("workitem.create", "Create a work item in the tracker.", risk: .external, params: [
                ActionParam("title", "The title", required: true),
                ActionParam("kind", "pbi or bug", choices: ["pbi", "bug"]),
                ActionParam("description", "What it is about"),
                ActionParam("sprint", "current, next or none", choices: ["current", "next", "none"]), scope,
            ], confirm: "Create the work item “{title}” in the tracker?"),
            ActionSpec("workitem.update", "Change a work item's state, assignee or sprint, or add a comment.", risk: .external, params: [
                ActionParam("id", .integer, "The work item number", required: true),
                ActionParam("state", "New state, e.g. Active, Resolved"),
                ActionParam("assignee", "me, a name or an email"),
                ActionParam("sprint", "current, next or an iteration path"),
                ActionParam("comment", "A comment to post"), scope,
            ], confirm: "Update work item {id} in the tracker?"),
            ActionSpec("workitem.tasks", "Set the state of tasks under a work item.", risk: .external, params: [
                ActionParam("ids", .strings, "The task numbers", required: true),
                ActionParam("state", "New state", required: true, choices: ["New", "In Progress", "Done"]),
            ], confirm: "Set {ids} to {state} in the tracker?"),
            ActionSpec("workitem.implement", "Start implementing a work item in a Build session (moves it to in progress).", risk: .external, params: [
                ActionParam("id", .integer, "The work item number", required: true),
                ActionParam("mode", "guided asks along the way, fast doesn't", choices: ["guided", "fast"]),
                ActionParam("strategy", "A strategy slug"), scope,
            ], confirm: "Start work item {id} and move it to in progress?"),
            ActionSpec("workitem.tags.align", "Write a work item's aligned Mindmill tags to the tracker.", risk: .external,
                       params: [ActionParam("id", .integer, "The work item number", required: true), scope],
                       confirm: "Write the tags of {id} to the tracker?"),
            ActionSpec("backlog.proposed", "Backlog items proposed in the knowledge base, not yet in the tracker.", params: [scope]),
            ActionSpec("backlog.propose", "Propose a PBI or bug in the knowledge base (not yet in the tracker).", risk: .write, params: [
                ActionParam("title", "The title", required: true), ActionParam("details", "What it is about"),
                ActionParam("bug", .boolean, "A bug rather than a PBI"),
                ActionParam("source", "The entry it comes from (a meeting, decision…)"), scope,
            ]),
            ActionSpec("backlog.create", "Create a proposed backlog item in the tracker, linked to its parent and related items. Refused while it may duplicate an existing item, unless not_duplicate is set.", risk: .external, params: [
                ActionParam("id", "The backlog entry's id", required: true),
                ActionParam("sprint", "current, next or none", choices: Sprint.allCases.map(\.rawValue)),
                ActionParam("parent", "The parent's work item number, or none; leave out for the entry's own or the one its text names"),
                ActionParam("related", .strings, "Work item numbers or backlog entry ids to link as related (replaces the entry's list)"),
                ActionParam("not_duplicate", .boolean, "The user checked the possible duplicate and wants it created anyway"),
            ], confirm: "Create {id} in the tracker?"),
            ActionSpec("backlog.duplicates", "Check the proposals waiting to be created for items that already exist in the tracker or are proposed twice: likely, possible or no duplicate, with the matching item.",
                       params: [ActionParam("id", "Only this backlog entry"), scope]),
            ActionSpec("backlog.link", "Set the parent and related links of created backlog items or work items, in the tracker and the knowledge base. Several ids are linked as related to each other.", risk: .external, params: [
                ActionParam("ids", .strings, "Backlog entry ids or work item numbers", required: true),
                ActionParam("parent", "The parent's work item number, or none to remove it"),
                ActionParam("related", .strings, "Work item numbers or backlog entry ids to link as related"), scope,
            ], confirm: "Change the links of {ids} in the tracker?"),
            ActionSpec("backlog.drop", "Drop a proposal that duplicates an existing item, optionally adding its notes to that item as a comment.", risk: .external, params: [
                ActionParam("id", "The backlog entry's id", required: true),
                ActionParam("of", "The work item number or backlog entry id it duplicates", required: true),
                ActionParam("comment", .boolean, "Add the proposal's notes as a comment on the existing item"),
            ], confirm: "Drop {id} as a duplicate of {of}?"),
            ActionSpec("backlog.reject", "Reject a proposed backlog item.", risk: .destructive,
                       params: [ActionParam("id", "The backlog entry's id", required: true)], confirm: "Reject {id}?"),
            ActionSpec("work.startable", "What can be started now: work in the current sprint nobody has started and no session works on.", params: [
                owner, ActionParam("types", .strings, "Any of pbi, bug, task; leave out for the filter last used on the Mac"), scope,
            ]),
        ]),
        ActionArea("Sprints", [
            ActionSpec("sprint.status", "Each tracker's previous, current and next sprint; whether a new sprint started or the last one ended with none after it; and a sprint review waiting.",
                       params: [scope]),
            ActionSpec("sprint.review", "What the previous sprint left unfinished (PBIs and bugs with their tasks), each with a suggested decision.",
                       params: [owner, scope]),
            ActionSpec("sprint.apply", "Carry out decisions on the previous sprint's unfinished items in the tracker: done, move to the new sprint, back to the backlog, or remove.",
                       risk: .external, params: [
                           ActionParam("decisions", .strings, "One per item as id:action, action being done, resolved, move, backlog, remove, keep or state:<name>, e.g. 123:move"),
                           ActionParam("accept_suggestions", .boolean, "Also apply the suggested decision to every other item the owner filter shows"),
                           owner, scope,
                       ], confirm: "Apply these sprint decisions in the tracker?"),
            ActionSpec("sprint.create", "Add the next sprint to Mindmill's own tracker: the same length as the last one, starting after it, unless given.",
                       risk: .write, params: [
                           ActionParam("name", "Its name; leave out for the next number"), ActionParam("start", "First day, YYYY-MM-DD"),
                           ActionParam("finish", "Last day, YYYY-MM-DD"), scope,
                       ]),
            ActionSpec("sprint.dismiss", "Put the sprint review off until tomorrow, or mark it done.", risk: .write, params: [
                ActionParam("how", "not_now or done", required: true, choices: ["not_now", "done"]), scope,
            ]),
        ]),
        ActionArea("Pull Requests", [
            ActionSpec("prs.list", "The user's open pull requests: comments, approvals and what blocks completing."),
            ActionSpec("prs.reviews", "Pull requests waiting for the user's review, with the review session if one is started."),
            ActionSpec("pr.review", "Start a session that reviews a pull request (or open the one that does); it asks before posting anything.",
                       risk: .write, params: [pr]),
            ActionSpec("pr.get", "One pull request with its comment threads.", params: [pr]),
            ActionSpec("pr.comment", "Post a new comment on a pull request.", risk: .external,
                       params: [pr, ActionParam("text", "The comment", required: true)], confirm: "Post this comment on pull request {id}?"),
            ActionSpec("pr.reply", "Reply on a comment thread, and resolve it if asked.", risk: .external, params: [
                pr, ActionParam("thread", .integer, "The thread id", required: true), ActionParam("text", "The reply", required: true),
                ActionParam("resolve", .boolean, "Also resolve the thread"),
            ], confirm: "Post this reply on pull request {id}?"),
            ActionSpec("pr.thread", "Set a comment thread's status.", risk: .external, params: [
                pr, ActionParam("thread", .integer, "The thread id", required: true),
                ActionParam("status", "New status", required: true, choices: ["fixed", "wontFix", "closed", "active"]),
            ], confirm: "Mark thread {thread} on pull request {id} as {status}?"),
            ActionSpec("pr.approve", "Approve a pull request.", risk: .external, params: [pr], confirm: "Approve pull request {id}?"),
            ActionSpec("pr.vote", "Vote on a pull request.", risk: .external, params: [
                pr, ActionParam("vote", "The vote", required: true, choices: ReviewVote.allCases.map(\.rawValue)),
            ], confirm: "Vote {vote} on pull request {id}?"),
            ActionSpec("pr.complete", "Complete (merge) a pull request now, or set it to complete by itself when ready.", risk: .external, params: [
                pr, ActionParam("auto", .boolean, "Set auto-complete instead of merging now"),
                ActionParam("strategy", "Merge strategy", choices: ["squash", "noFastForward", "rebase", "rebaseMerge"]),
                ActionParam("delete_branch", .boolean, "Delete the source branch"),
                ActionParam("complete_work_items", .boolean, "Complete the linked work items"),
                ActionParam("message", "The merge commit message"),
            ], confirm: "Complete pull request {id}?"),
            ActionSpec("pr.autocomplete.cancel", "Cancel a pull request's auto-complete.", risk: .external, params: [pr],
                       confirm: "Cancel auto-complete on pull request {id}?"),
            ActionSpec("pr.comments.handle", "Have a session work through a pull request's comments.", risk: .write, params: [
                pr, ActionParam("mode", "Which comments", choices: PRCommentsMode.allCases.map(\.rawValue)),
            ]),
            ActionSpec("pr.conflicts", "Have a session resolve a pull request's merge conflicts.", risk: .write, params: [pr]),
            ActionSpec("pr.build.fix", "Have a session fix a pull request's failed build.", risk: .write, params: [pr]),
            ActionSpec("pr.build.rerun", "Run a pull request's build again.", risk: .external, params: [pr], confirm: "Run the build of pull request {id} again?"),
        ]),
        ActionArea("Factories", [
            ActionSpec("factories.status", "Each software factory: running, paused or stopped, what it works on, progress and open questions."),
            ActionSpec("factory.get", "A factory's whole configuration and state.", params: [factory]),
            ActionSpec("factory.create", "Make a new software factory. It doesn't start until asked.", risk: .write,
                       params: [ActionParam("name", "Its name", required: true)] + factoryFields),
            ActionSpec("factory.update", "Change any of a factory's settings or its name.", risk: .write,
                       params: [factory, ActionParam("name", "A new name")] + factoryFields),
            ActionSpec("factory.duplicate", "Copy a factory with its settings.", risk: .write,
                       params: [factory, ActionParam("name", "The copy's name")]),
            ActionSpec("factory.delete", "Delete a factory (stopping it first if it runs).", risk: .destructive, params: [factory],
                       confirm: "Delete the factory {factory}?"),
            ActionSpec("factory.start", "Start (or start again) a software factory.", risk: .write, params: [factory]),
            ActionSpec("factory.pause", "Pause a factory: it takes no new work items, sessions working carry on.", risk: .write, params: [factory]),
            ActionSpec("factory.resume", "Resume a paused factory.", risk: .write, params: [factory]),
            ActionSpec("factory.stop", "Stop a factory: it starts nothing new and its sessions finish the step they're on.", risk: .destructive,
                       params: [factory], confirm: "Stop the factory {factory}?"),
            ActionSpec("factory.settings", "Change how a factory runs.", risk: .write, params: [
                factory,
                ActionParam("max_parallel", .integer, "How many work items at once"),
                ActionParam("questions", "When it asks", choices: FactoryRules.Questions.allCases.map(\.rawValue)),
                ActionParam("hours", .number, "Run for this many hours from now; 0 runs until stopped"),
            ]),
            ActionSpec("factory.answer", "Answer a question a factory asked.", risk: .write, params: [
                ActionParam("question", "The question's id", required: true), ActionParam("answer", "The answer", required: true),
            ]),
            ActionSpec("factory.question.skip", "Let the factory decide a question itself.", risk: .write,
                       params: [ActionParam("question", "The question's id", required: true)]),
            ActionSpec("factory.item.skip", "Skip a work item for this run of a factory.", risk: .write, params: [
                factory, ActionParam("work_item", .integer, "The work item number", required: true),
            ]),
        ]),
        ActionArea("Strategies", [
            ActionSpec("strategies.list", "The strategies a Build session or factory can follow."),
            ActionSpec("strategy.get", "One strategy in full.", params: [ActionParam("slug", "The strategy's slug", required: true)]),
            ActionSpec("strategy.save", "Write a strategy of the user's own, or change one.", risk: .write, params: [
                ActionParam("slug", "The slug of the one to change; leave out for a new one"),
                ActionParam("title", "Its title", required: true), ActionParam("summary", "One line"),
                ActionParam("instructions", "What the session should do, step by step", required: true),
                ActionParam("model", "Model for its sessions, e.g. opus or sonnet"),
            ]),
            ActionSpec("strategy.delete", "Delete a strategy of the user's own (a changed built-in goes back to the original).", risk: .destructive,
                       params: [ActionParam("slug", "The strategy's slug", required: true)], confirm: "Delete the strategy {slug}?"),
            ActionSpec("strategy.draft", "Draft a new strategy together with the brain in a session.", risk: .write),
        ]),
        ActionArea("Sessions", [
            ActionSpec("sessions.list", "Plan and Build sessions, and which ones wait for the user."),
            ActionSpec("session.read", "The latest messages of a session.", params: [session, ActionParam("last", .integer, "How many messages")]),
            ActionSpec("session.start", "Start a Plan or Build session with a first message; for deeper work like planning or implementing.",
                       risk: .write, params: [
                           ActionParam("space", "plan or build", required: true, choices: ["plan", "build"]),
                           ActionParam("message", "What the session should do", required: true),
                           ActionParam("title", "A short title"), ActionParam("strategy", "A strategy slug (Build)"), scope,
                       ]),
            ActionSpec("session.lead", "Start a Build lead session that splits the work over helper sessions.", risk: .write, params: [
                ActionParam("brief", "What to build", required: true), ActionParam("title", "A short title"),
                ActionParam("strategy", "A strategy slug"), ActionParam("helpers", .integer, "How many helpers; leave out to let it decide"), scope,
            ]),
            ActionSpec("session.send", "Send a message to a session.", risk: .write, params: [session, ActionParam("text", "The message", required: true)]),
            ActionSpec("session.stop", "Stop what a session is doing.", risk: .destructive, params: [session], confirm: "Stop that session?"),
            ActionSpec("session.retry", "Send a session's last message again after it failed.", risk: .write, params: [session]),
            ActionSpec("session.allow", "Allow what a session was refused, for that session.", risk: .write, params: [session]),
            ActionSpec("session.strategy", "Give a session a strategy, or take it away.", risk: .write, params: [
                session, ActionParam("strategy", "A strategy slug; empty for none", required: true),
            ]),
            ActionSpec("session.to_build", "Move a Plan session to Build.", risk: .write, params: [session]),
            ActionSpec("session.archive", "Archive a session, or take it out of the archive.", risk: .write,
                       params: [session, ActionParam("archived", .boolean, "true archives it")]),
            ActionSpec("session.delete", "Delete a session (stopping it first).", risk: .destructive, params: [session], confirm: "Delete that session?"),
        ]),
        ActionArea("Testing", [
            ActionSpec("test.status", "Testing set-up and the latest test delivery for a project.", params: [scope]),
            ActionSpec("test.detect", "Look for what can be tested in a project again (apps, web, services).", risk: .write, params: [scope]),
            ActionSpec("test.check", "Check this Mac's tools and the project's compatibility for testing again.", risk: .write, params: [scope]),
            ActionSpec("test.deliver", "Build a test target and deliver it: to the phone, a preview, a link.", risk: .write, params: [
                ActionParam("target", "The target's id from test.status", required: true), scope,
                ActionParam("session", "The Build session whose work it is, so the delivery and its review card name it"),
            ]),
            ActionSpec("test.server.stop", "Stop a running dev server.", risk: .destructive,
                       params: [ActionParam("id", "The server's id", required: true)], confirm: "Stop that server?"),
        ]),
        ActionArea("Projects", [
            ActionSpec("scans.list", "Project scans and what they found."),
            ActionSpec("scan.start", "Scan projects for facts, decisions, architecture and more.", risk: .write, params: [
                ActionParam("scopes", .strings, "The scopes to scan; leave out for the current one"),
                ActionParam("kinds", .strings, "What to look for: " + ScanKind.allCases.map(\.rawValue).joined(separator: ", ")),
                ActionParam("sources", .strings, "Where to look: " + ScanSource.allCases.map(\.rawValue).joined(separator: ", ")),
                ActionParam("focus", "Anything in particular"),
            ]),
            ActionSpec("scan.stop", "Stop a scan.", risk: .destructive, params: [ActionParam("id", "The scan's id", required: true)], confirm: "Stop the scan?"),
            ActionSpec("scan.apply", "Add a scan's findings to the knowledge base.", risk: .write, params: [
                ActionParam("id", "The scan's id", required: true), ActionParam("findings", .strings, "Finding ids; leave out for all"),
            ]),
            ActionSpec("repos.pull", "Pull the latest of a project's repositories (fast-forward only).", risk: .write, params: [scope]),
            ActionSpec("people.list", "People Mindmill knows: names, emails.", params: [ActionParam("query", "Only matching")]),
            ActionSpec("people.refresh", "Read the people directory again.", risk: .write),
        ]),
        ActionArea("Settings", [
            ActionSpec("settings.get", "Mindmill's settings: the AI brain and models, voice, meetings, calendar and general ones."),
            ActionSpec("settings.ai", "Choose the brain or the model for a task.", risk: .write, params: [
                ActionParam("task", "The task, or brain for the main AI", required: true, choices: ["brain"] + AITask.allCases.map(\.rawValue)),
                ActionParam("model", "A model (opus, sonnet, haiku…); empty uses the default"),
                ActionParam("provider", "The provider id, e.g. claude-code"),
            ]),
            ActionSpec("settings.voice", "Change voice settings.", risk: .write, params: [
                ActionParam("engine", "keyless (built-in) or api (real-time API)", choices: ["keyless", "api"]),
                ActionParam("rate", .number, "Speech speed, 0.5 to 2"),
                ActionParam("language", "auto, da-DK or en-US", choices: ["auto", "da-DK", "en-US"]),
                ActionParam("barge_in", .boolean, "Stop speaking when the user talks"),
            ]),
            ActionSpec("settings.meetings", "Change how meetings are transcribed.", risk: .write, params: [
                ActionParam("language", "Transcript language id, e.g. auto, da-DK, en-US"),
                ActionParam("microphone", .boolean, "Hear the microphone"), ActionParam("computer_audio", .boolean, "Hear the computer's audio"),
            ]),
            ActionSpec("settings.general", "Change general settings.", risk: .write, params: [
                ActionParam("appearance", "system, light or dark", choices: ["system", "light", "dark"]),
                ActionParam("open_in", "Which mode the app opens in; empty for where it was left", choices: ["", "plan", "build"]),
                ActionParam("morning", .boolean, "Run the morning routine by itself"),
                ActionParam("calendar_minutes", .integer, "How often to sync the calendar: 15, 30, 60, or 0 for only at launch"),
            ]),
            ActionSpec("app.mode", "Switch the Mac app to Plan or Build.", risk: .write,
                       params: [ActionParam("mode", "plan or build", required: true, choices: ["plan", "build"])]),
        ]),
    ]

    public static let all: [ActionSpec] = areas.flatMap(\.actions)

    /// The actions a real-time voice model gets as tools of their own; it reaches the rest with `find_actions` and
    /// `run_action`. Its APIs take fewer tools than Claude does.
    public static let voiceCore: Set<String> = [
        "overview", "projects.list", "app.show", "knowledge.search", "entry.read", "facts.proposed", "fact.approve", "fact.decline",
        "followups.list", "followup.create", "followup.update", "reminders.list", "reminder.create", "today.plan",
        "meetings.list", "calendar.upcoming", "meeting.mac.start", "meeting.mac.note", "meeting.mac.stop", "meeting.mac.status",
        "backlog.list", "workitem.get", "workitem.create", "workitem.update", "prs.list", "pr.approve",
        "factories.status", "factory.start", "factory.pause", "factory.resume", "factory.stop", "factory.answer",
        "sessions.list", "session.read", "session.start", "session.send", "test.status",
    ]
}
