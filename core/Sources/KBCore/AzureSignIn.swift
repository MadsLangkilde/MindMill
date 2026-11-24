import Foundation

/// The Azure CLI sign-in that the Azure DevOps MCP (`-a azcli`) uses: telling from a reply that it has expired, and
/// reading what `az` prints. Its refresh token dies after 90 days unused, and every Azure DevOps call then fails.
public enum AzureSignIn {
    /// Azure DevOps' resource id, for `az account get-access-token --resource`.
    public static let devOpsResource = "499b84ac-1321-427f-aa17-267ca6975798"

    static let phrases = [
        "aadsts", "az login", "refresh token has expired", "interaction_required", "azure cli credential",
        "azureclicredential",
    ]

    /// `justSignedIn`: the reply to "it works now" talks about az login too, so only an actual Entra error counts.
    public static func isProblem(_ text: String, justSignedIn: Bool = false) -> Bool {
        let t = text.lowercased()
        if justSignedIn { return t.range(of: #"aadsts\d+"#, options: .regularExpression) != nil }
        return phrases.contains { t.contains($0) }
    }

    /// `AADSTS700082: The refresh token has expired due to inactivity.`: the code and its first sentence.
    public static func shortReason(_ text: String) -> String? {
        guard let r = text.range(of: #"AADSTS\d+:[^.\n]*\.?"#, options: .regularExpression) else {
            let first = text.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !first.isEmpty else { return nil }
            return first.count > 160 ? String(first.prefix(157)) + "…" : first
        }
        return String(text[r])
    }

    /// The sign-in page `az login` prints when it opens the browser, for when the browser didn't open.
    public static func signInURL(in output: String) -> URL? {
        for line in output.components(separatedBy: .newlines) {
            guard let r = line.range(of: "https://login.") else { continue }
            let raw = line[r.lowerBound...].prefix { !$0.isWhitespace && $0 != "\"" && $0 != "'" }
            let cleaned = raw.hasSuffix(".") ? String(raw.dropLast()) : String(raw)
            if let url = URL(string: cleaned) { return url }
        }
        return nil
    }

    /// `2026-11-21 09:40:12.000000` from `--query expiresOn -o tsv` as `2026-11-21 09:40`; nil when it isn't a time.
    public static func expiry(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard line.range(of: #"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}"#, options: .regularExpression) != nil else { return nil }
        return String(line.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    /// `az` on the login shell's PATH, else where Homebrew and the installer put it.
    public static func executable(path: String?, exists: (String) -> Bool = FileManager.default.isExecutableFile) -> URL? {
        let dirs = (path ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.lazy.map { "\($0)/az" }.first(where: exists).map(URL.init(fileURLWithPath:))
    }

    /// What a session is told once the sign-in works again.
    public static func resumeMessage(expires: String?) -> String {
        "I signed in to Azure again from Mindmill, and the Azure DevOps token check passes now"
            + (expires.map { " (it expires \($0))" } ?? "") + ". Carry on with what failed."
    }
}
