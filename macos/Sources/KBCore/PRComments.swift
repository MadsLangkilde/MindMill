import Foundation

/// How much Claude may do on its own with the open review comments on one of the user's pull requests.
public enum PRCommentsMode: String, CaseIterable, Sendable, Identifiable {
    case withMe, simpleOnly, all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .withMe: return "Go Through Them with Me"
        case .simpleOnly: return "Handle Simple Ones, Ask Me the Rest"
        case .all: return "Handle All Without Asking"
        }
    }

    public var systemImage: String {
        switch self {
        case .withMe: return "person.2"
        case .simpleOnly: return "wand.and.stars"
        case .all: return "bolt"
        }
    }

    public var help: String {
        switch self {
        case .withMe: return "One comment at a time. Nothing is changed, pushed, posted or resolved without your yes."
        case .simpleOnly: return "Clear-cut fixes and answers are done, pushed, replied to and resolved. Anything that needs your judgement is asked at the end."
        case .all: return "Every comment is fixed or answered, pushed and replied to. Disagreements get a reply and stay open for the reviewer."
        }
    }

    /// What the session shows as the user's message.
    public func display(_ pr: PullRequest) -> String {
        switch self {
        case .withMe: return "Go through the comments on !\(pr.id) with me"
        case .simpleOnly: return "Handle the simple comments on !\(pr.id), ask me about the rest"
        case .all: return "Handle all comments on !\(pr.id) without asking"
        }
    }

    public func prompt(_ pr: PullRequest) -> String {
        let intro = """
        Handle the open review comments on my pull request !\(pr.id) (“\(pr.title)”) in \(pr.repo), branch `\(pr.source)` into `\(pr.target)`: \(pr.url)
        Read them with `kb pr show \(pr.id)`. Work in the branch's worktree if there is one, else check the branch out. \
        Follow the repository's own rules for code, tests, commits and pushing.
        Replies are posted as me: short and plain, saying what changed (with the commit) or why not. \
        Never mention Claude, sessions, agents or tools in a reply.
        """
        let body: String
        switch self {
        case .withMe:
            body = """
            Take the open threads one at a time: say what the reviewer asks, whether you agree and why, and propose a code fix or a reply. \
            Ask me with choices before you change code, commit, push, post a reply (`kb pr reply`) or resolve a thread (`kb pr thread --status fixed`).
            """
        case .simpleOnly:
            body = """
            First sort every open thread into simple or needs me, and show me the list in one short table.
            Simple: the reviewer's intent is clear and there is one obvious answer — a typo, a rename, a missing test or null check, \
            a small fix the reviewer spelled out, a question the code answers.
            Needs me: a change of behaviour, design or scope; anything you disagree with; an unclear ask; a product or UX decision; \
            anything risky or touching more than the lines commented on.
            For the simple ones you have my permission, without asking: fix them, run the relevant tests, commit, push to `\(pr.source)`, \
            then reply on each thread with what changed and resolve it (`kb pr reply \(pr.id) <thread> --text "…" --status fixed`).
            Then ask me about each needs-me thread with choices, one at a time, and act on my answer.
            End with a short summary: resolved, waiting for me, left open.
            """
        case .all:
            body = """
            You have my permission to handle every open thread without asking: fix what you agree with, run the relevant tests, \
            commit, push to `\(pr.source)`, reply on the thread with what changed and resolve it (`kb pr reply \(pr.id) <thread> --text "…" --status fixed`).
            Where you disagree or the ask is unclear, change nothing: reply with your reasoning or question and leave the thread open for the reviewer.
            Only stop and ask me if a fix would change behaviour a user sees, or tests fail in a way you cannot fix.
            End with a short summary: resolved, answered and left open, and anything I should look at.
            """
        }
        return intro + "\n\n" + body
    }
}
