import Foundation

/// Which Xcode scheme builds the app: a project lists a scheme for every package and library too.
public enum XcodeSchemes {
    /// The names of a project's targets that build an app, from its project.pbxproj.
    public static func appTargets(pbxproj: String) -> [String] {
        pbxproj.components(separatedBy: "isa = PBXNativeTarget;").dropFirst().compactMap { chunk in
            let block = chunk.components(separatedBy: "\n\t\t};").first ?? chunk
            guard block.contains("productType = \"com.apple.product-type.application\"") else { return nil }
            return value("name", in: block)
        }
    }

    /// The app's scheme: one named after an app target (the project's own name first, then the shortest, so
    /// `Contoso` before `Contoso Staging`), else one named after the project, else the first.
    public static func pick(_ schemes: [String], appTargets: [String], project: String?) -> String? {
        let apps = schemes.filter { appTargets.contains($0) }
        if let project, apps.contains(project) { return project }
        if let shortest = apps.min(by: { ($0.count, $0) < ($1.count, $1) }) { return shortest }
        if let project, schemes.contains(project) { return project }
        let named = schemes.filter { s in appTargets.contains { s.hasPrefix($0) } }
        return named.min(by: { ($0.count, $0) < ($1.count, $1) }) ?? schemes.first
    }

    /// The first error in an xcodebuild or Gradle log, in one line.
    public static func firstError(_ log: String) -> String? {
        let lines = log.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let i = lines.firstIndex(of: "* What went wrong:"), i + 1 < lines.count, !lines[i + 1].isEmpty {
            return String(lines[i + 1].prefix(240))
        }
        guard let line = lines.first(where: { $0.hasPrefix("error:") || $0.contains(": error:") || $0.hasPrefix("xcodebuild: error:") }) else { return nil }
        let text = line.range(of: "error:").map { String(line[$0.upperBound...]) } ?? line
        return String(text.trimmingCharacters(in: .whitespaces).prefix(240))
    }

    static func value(_ key: String, in block: String) -> String? {
        guard let r = block.range(of: "\n\t\t\t\(key) = ") else { return nil }
        let rest = block[r.upperBound...]
        let raw = rest.prefix { $0 != ";" }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }
}
