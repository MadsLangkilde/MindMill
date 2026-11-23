import Foundation

/// Claude Code's sign-in, as the app sees it: telling a sign-in failure from other errors, and reading what
/// `claude auth login` and `claude auth status --json` print.
public enum ClaudeAuth {
    /// What Claude Code says when its login is missing, expired or refused. A 403 from Cloudflare in front
    /// of the API comes out as "Failed to authenticate" too, and signing in again is what clears it.
    static let signInPhrases = [
        "failed to authenticate", "please run /login", "invalid api key", "oauth token has expired",
        "oauth token revoked", "authentication_error", "not logged in", "api error: 401", "invalid bearer token",
        "token has been revoked", "login expired", "/login to sign in",
    ]

    public static func isSignInProblem(_ text: String) -> Bool {
        let t = text.lowercased()
        return signInPhrases.contains { t.contains($0) }
    }

    /// The error in a line for a banner: the first line, without the HTML title Cloudflare adds.
    public static func shortReason(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 140 ? String(trimmed.prefix(137)) + "…" : trimmed
    }

    /// Terminal escapes (colours, and the OSC 8 hyperlinks the CLI wraps links in) removed.
    public static func plainText(_ s: String) -> String {
        var out = ""
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            guard c == "\u{1B}" else { out.unicodeScalars.append(c); continue }
            guard let kind = it.next() else { break }
            if kind == "[" {
                while let n = it.next(), !(0x40...0x7E).contains(n.value) {}
            } else if kind == "]" {
                // Runs to BEL or ESC \.
                while let n = it.next() {
                    if n == "\u{07}" { break }
                    if n == "\u{1B}" { _ = it.next(); break }
                }
            }
        }
        return out
    }

    /// The sign-in page `claude auth login` prints for when the browser didn't open.
    public static func signInURL(in output: String) -> URL? {
        let text = plainText(output)
        let lines = text.components(separatedBy: .newlines)
        let preferred = lines.first { $0.contains("visit:") || $0.contains("Sign in at:") }
        for line in [preferred].compactMap({ $0 }) + lines {
            if let r = line.range(of: "https://") {
                let raw = line[r.lowerBound...].prefix { !$0.isWhitespace }
                if let url = URL(string: String(raw)) { return url }
            }
        }
        return nil
    }

    public static func succeeded(_ output: String) -> Bool {
        plainText(output).contains("Login successful")
    }

    /// `claude auth status --json`.
    public struct Status: Decodable, Equatable, Sendable {
        public var loggedIn: Bool
        public var email: String?
        public var orgName: String?
        public var loginExpiresAt: String?

        public init(loggedIn: Bool, email: String? = nil, orgName: String? = nil, loginExpiresAt: String? = nil) {
            self.loggedIn = loggedIn
            self.email = email
            self.orgName = orgName
            self.loginExpiresAt = loginExpiresAt
        }

        public static func decode(_ json: String) -> Status? {
            let start = json.firstIndex(of: "{").map { String(json[$0...]) } ?? json
            return try? JSONDecoder().decode(Status.self, from: Data(start.utf8))
        }

        /// "you@example.com (Org)".
        public var account: String {
            [email, orgName.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        }
    }
}
