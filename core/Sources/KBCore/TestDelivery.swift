import Foundation

/// A build or preview the Mac made for a target.
public struct TestDelivery: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case building, ready, sent, installed, failed }

    public var id: String
    public var scope: String
    public var target: String
    public var kind: DeliveryKind
    public var title: String
    public var created: Date
    public var state: State
    /// The file in the delivery folder (APK), its size and SHA-256.
    public var file: String?
    public var size: Int?
    public var sha256: String?
    /// For `url` deliveries and iOS install links.
    public var url: String?
    public var message: String?
    public var session: String?

    public init(id: String = UUID().uuidString.prefix(10).lowercased(), scope: String, target: String, kind: DeliveryKind, title: String,
                created: Date = Date(), state: State = .building) {
        self.id = id
        self.scope = scope
        self.target = target
        self.kind = kind
        self.title = title
        self.created = created
        self.state = state
    }

    /// The kind the phone sees: an iOS link opens like a URL; a TestFlight upload opens the TestFlight app; device
    /// installs don't go to the phone.
    public var phoneKind: String? {
        switch kind {
        case .apk: return "apk"
        case .url, .iosLink: return "url"
        case .preview: return "preview"
        case .testflight: return "testflight"
        case .iosDevice: return nil
        }
    }

    /// The phone platform that can use it; nil for any phone (links and previews).
    public var platform: String? {
        switch kind {
        case .apk: return RemotePlatform.android
        case .iosLink, .testflight, .iosDevice: return RemotePlatform.ios
        case .url, .preview: return nil
        }
    }

    /// The `test.delivery` event, as docs/remote-api.md has it.
    public var event: JSONValue? {
        guard let phoneKind else { return nil }
        var d: [String: JSONValue] = ["id": .string(id), "scope": .string(scope), "target": .string(target),
                                      "kind": .string(phoneKind), "title": .string(title)]
        if let platform { d["platform"] = .string(platform) }
        if let url { d["url"] = .string(url) }
        if let size { d["size"] = .number(Double(size)) }
        return .object(d)
    }

    public var summary: JSONValue {
        var d: [String: JSONValue] = ["id": .string(id), "scope": .string(scope), "target": .string(target), "kind": .string(phoneKind ?? kind.rawValue),
                                      "title": .string(title), "state": .string(state.rawValue), "created": .number(created.timeIntervalSince1970)]
        if let platform { d["platform"] = .string(platform) }
        if let url { d["url"] = .string(url) }
        if let size { d["size"] = .number(Double(size)) }
        if let message { d["message"] = .string(message) }
        return .object(d)
    }
}

public enum DeliveryFiles {
    public static let chunkSize = 256 * 1024

    public static func sha256(_ data: Data) -> String {
        Digest.sha256Hex(data)
    }

    /// The `file` frames for a download, per docs/remote-api.md.
    public static func frames(_ data: Data, delivery: String) -> [RemoteFrame] {
        let count = max(1, (data.count + chunkSize - 1) / chunkSize)
        return (0..<count).map { i in
            let start = data.startIndex + i * chunkSize
            let end = min(data.endIndex, start + chunkSize)
            return RemoteFrame(header: ["kind": "file", "delivery": .string(delivery), "seq": .number(Double(i)), "last": .bool(i == count - 1)],
                               payload: Data(data[start..<end]))
        }
    }

    /// A path a preview may ask for: inside its folder, no `..`.
    public static func safePath(_ path: String) -> String? {
        let clean = path.split(separator: "?").first.map(String.init) ?? path
        let parts = clean.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !parts.contains(".."), !parts.isEmpty else { return parts.isEmpty ? "index.html" : nil }
        return parts.joined(separator: "/")
    }

    public static func mime(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "txt", "log": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    /// The manifest an iPhone reads from an `itms-services` link.
    public static func installManifest(ipaURL: String, bundleID: String, version: String, title: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>items</key><array><dict>
        <key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>\(xml(ipaURL))</string></dict></array>
        <key>metadata</key><dict><key>bundle-identifier</key><string>\(xml(bundleID))</string><key>bundle-version</key><string>\(xml(version))</string>
        <key>kind</key><string>software</string><key>title</key><string>\(xml(title))</string></dict>
        </dict></array></dict></plist>
        """
    }

    public static func installLink(manifestURL: String) -> String {
        "itms-services://?action=download-manifest&url=" + (manifestURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?"))) ?? manifestURL)
    }

    /// `xcodebuild -exportArchive` options for an ad hoc build or a TestFlight upload.
    public static func exportOptions(testflight: Bool) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>method</key><string>\(testflight ? "app-store-connect" : "release-testing")</string>
        <key>signingStyle</key><string>automatic</string>
        \(testflight ? "<key>destination</key><string>upload</string>" : "")
        </dict></plist>
        """
    }

    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// How a test run went, read from its output.
public struct TestRunSummary: Codable, Equatable, Sendable {
    public var passed: Int
    public var failed: Int
    /// The failing lines, and a few around the totals.
    public var lines: [String]
    public var exitCode: Int32

    public init(passed: Int, failed: Int, lines: [String], exitCode: Int32) {
        self.passed = passed
        self.failed = failed
        self.lines = lines
        self.exitCode = exitCode
    }

    public var ok: Bool { exitCode == 0 && failed == 0 }

    public var json: JSONValue {
        ["passed": .number(Double(passed)), "failed": .number(Double(failed)), "lines": .array(lines.map(JSONValue.string))]
    }

    /// Understands the totals of the common runners (Jest/Vitest, pytest, XCTest and swift-testing, Gradle, go,
    /// cargo, dotnet, PlatformIO); otherwise counts by the exit code.
    public static func parse(_ output: String, exitCode: Int32) -> TestRunSummary {
        var passed = 0, failed = 0
        func ints(_ pattern: String) -> [[Int]] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            return re.matches(in: output, range: NSRange(output.startIndex..., in: output)).map { m in
                (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: output).flatMap { Int(output[$0]) } }
            }
        }
        if let m = ints(#"Tests:\s+(?:(\d+) failed, )?(?:\d+ skipped, )?(\d+) passed"#).last, !m.isEmpty {
            if m.count == 2 { failed = m[0]; passed = m[1] } else { passed = m[0] }
        } else if let m = ints(#"Tests\s+(\d+) failed \| (\d+) passed"#).last, m.count == 2 {
            failed = m[0]; passed = m[1]
        } else if let m = ints(#"Tests\s+(\d+) passed"#).last, m.count == 1 {
            passed = m[0]
        } else if !ints(#"=+ .*?(\d+) passed"#).isEmpty || !ints(#"=+ .*?(\d+) failed"#).isEmpty {
            passed = ints(#"(\d+) passed"#).last?.first ?? 0
            failed = ints(#"(\d+) failed"#).last?.first ?? 0
        } else if let m = ints(#"Executed (\d+) tests?, with (\d+) failures?"#).last, m.count == 2 {
            passed = m[0] - m[1]; failed = m[1]
        } else if let m = ints(#"Test run with (\d+) tests?.*?passed"#).last, m.count == 1 {
            passed = m[0]
        } else if let m = ints(#"Test run with (\d+) tests?.*?failed"#).last, m.count == 1 {
            failed = ints(#"(\d+) issues?"#).last?.first ?? 1; passed = max(0, m[0] - failed)
        } else if let m = ints(#"(\d+) tests completed, (\d+) failed"#).last, m.count == 2 {
            passed = m[0] - m[1]; failed = m[1]
        } else if let m = ints(#"test result: \w+\. (\d+) passed; (\d+) failed"#).last, m.count == 2 {
            passed = m[0]; failed = m[1]
        } else if let m = ints(#"Passed!\s+-\s+Failed:\s+(\d+), Passed:\s+(\d+)"#).last, m.count == 2 {
            failed = m[0]; passed = m[1]
        } else if let m = ints(#"Failed!\s+-\s+Failed:\s+(\d+), Passed:\s+(\d+)"#).last, m.count == 2 {
            failed = m[0]; passed = m[1]
        } else {
            let lines = output.components(separatedBy: "\n")
            passed = lines.filter { $0.hasPrefix("ok ") || $0.hasPrefix("--- PASS") || $0.contains("[PASSED]") }.count
            failed = lines.filter { $0.hasPrefix("FAIL") || $0.hasPrefix("--- FAIL") || $0.contains("[FAILED]") }.count
        }
        if exitCode != 0, failed == 0 { failed = 1 }
        let failing = output.components(separatedBy: "\n")
            .filter { l in ["fail", "error", "✘", "assert"].contains { l.lowercased().contains($0) } }
            .map { String($0.trimmingCharacters(in: .whitespaces).prefix(240)) }
        return TestRunSummary(passed: max(0, passed), failed: failed, lines: Array(failing.prefix(30)), exitCode: exitCode)
    }
}

/// A card on the phone at a checkpoint: what changed, how the tests went, screenshots, and what to do next.
public struct TestReviewCard: Codable, Equatable, Sendable, Identifiable {
    public struct Image: Codable, Equatable, Sendable {
        public var title: String
        public var path: String
        /// The same view from the card before, to compare.
        public var before: String?

        public init(title: String, path: String, before: String? = nil) {
            self.title = title
            self.path = path
            self.before = before
        }
    }

    public var id: String
    public var scope: String
    public var target: String?
    public var title: String
    public var summary: String
    public var workItem: Int?
    public var session: String?
    public var factory: String?
    public var tests: TestRunSummary?
    public var images: [Image]
    public var delivery: String?
    /// The phone platform its build is for (from the delivery); nil when any phone can use it.
    public var platform: String?
    public var actions: [String]
    public var created: Date
    /// What the user answered, once they did.
    public var response: String?

    public init(id: String = UUID().uuidString.prefix(10).lowercased(), scope: String, target: String? = nil, title: String, summary: String,
                workItem: Int? = nil, session: String? = nil, factory: String? = nil, tests: TestRunSummary? = nil, images: [Image] = [],
                delivery: String? = nil, actions: [String] = TestReviewCard.allActions, created: Date = Date()) {
        self.id = id
        self.scope = scope
        self.target = target
        self.title = title
        self.summary = summary
        self.workItem = workItem
        self.session = session
        self.factory = factory
        self.tests = tests
        self.images = images
        self.delivery = delivery
        self.actions = actions
        self.created = created
    }

    public static let allActions = ["approve", "pause", "change", "install"]

    /// The `review.card` event, as docs/remote-api.md has it.
    public var json: JSONValue {
        var d: [String: JSONValue] = [
            "id": .string(id), "scope": .string(scope), "title": .string(title), "summary": .string(summary),
            "tests": tests?.json ?? ["passed": 0, "failed": 0, "lines": []],
            "images": .array(images.map { i in
                var o: [String: JSONValue] = ["title": .string(i.title), "path": .string(i.path)]
                if let b = i.before { o["before"] = .string(b) }
                return .object(o)
            }),
            "actions": .array(actions.map(JSONValue.string)),
        ]
        if let workItem { d["workItem"] = .number(Double(workItem)) }
        if let session { d["session"] = .string(session) }
        if let factory { d["factory"] = .string(factory) }
        if let delivery { d["delivery"] = .string(delivery) }
        if let platform { d["platform"] = .string(platform) }
        return .object(d)
    }

    /// Screenshots of the card before, matched by title, become this card's "before" images. Returns the files to
    /// copy from the earlier card's folder into this one's (from, to), since a card only serves its own folder.
    @discardableResult
    public mutating func compare(with previous: TestReviewCard?) -> [(from: String, to: String)] {
        guard let previous else { return [] }
        var copies: [(from: String, to: String)] = []
        for i in images.indices {
            if let old = previous.images.first(where: { $0.title == images[i].title }) {
                let name = "before-" + old.path
                images[i].before = name
                copies.append((old.path, name))
            }
        }
        return copies
    }
}
