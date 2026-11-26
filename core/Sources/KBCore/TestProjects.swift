import Foundation

/// What kind of thing a project (or one part of it) builds, for testing.
public enum ProjectType: String, Codable, CaseIterable, Sendable, Identifiable {
    case ios, android, web, backend, desktopMac, desktopWindows, embedded, unknown

    public var id: String { rawValue }

    /// Whether a phone of `platform` can try a build of this kind of project itself: its own apps, and websites.
    /// Anything else (no phone, a desktop shell) sees every kind.
    public func testable(on platform: String?) -> Bool {
        switch platform {
        case RemotePlatform.android: return self == .android || self == .web
        case RemotePlatform.ios: return self == .ios || self == .web
        default: return true
        }
    }

    public var title: String {
        switch self {
        case .ios: return "iOS app"
        case .android: return "Android app"
        case .web: return "Website or web app"
        case .backend: return "Backend service"
        case .desktopMac: return "macOS app"
        case .desktopWindows: return "Windows app"
        case .embedded: return "Embedded or instrument software"
        case .unknown: return "Other"
        }
    }

    public var icon: String {
        switch self {
        case .ios: return "iphone"
        case .android: return "candybarphone"
        case .web: return "globe"
        case .backend: return "server.rack"
        case .desktopMac: return "macwindow"
        case .desktopWindows: return "pc"
        case .embedded: return "cpu"
        case .unknown: return "questionmark.square.dashed"
        }
    }
}

/// The files of a repository, as relative paths, with a way to read the small ones: enough to tell what it builds.
public struct RepoListing: Sendable {
    public var paths: [String]
    private let reader: @Sendable (String) -> String?

    public init(paths: [String], read: @escaping @Sendable (String) -> String?) {
        self.paths = paths
        self.reader = read
    }

    /// A listing of files held in memory, for tests.
    public init(files: [String: String]) {
        self.paths = files.keys.sorted()
        self.reader = { files[$0] }
    }

    public func read(_ path: String) -> String? { reader(path) }

    static let skipped: Set<String> = ["node_modules", ".git", "build", "Pods", ".build", "DerivedData", ".gradle", "dist",
                                       "vendor", ".venv", "venv", "__pycache__", "target", "bin", "obj", ".idea", ".next"]

    /// Lists a folder on disk, `depth` levels down, skipping build output and dependencies.
    public static func scan(_ root: URL, depth: Int = 4, limit: Int = 6000) -> RepoListing {
        var out: [String] = []
        let fm = FileManager.default
        func walk(_ dir: URL, _ rel: String, _ level: Int) {
            guard level <= depth, out.count < limit,
                  let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = url.lastPathComponent
                let path = rel.isEmpty ? name : rel + "/" + name
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
                        out.append(path)
                        out.append(path + "/project.pbxproj")
                        continue
                    }
                    if skipped.contains(name) { continue }
                    walk(url, path, level + 1)
                } else {
                    out.append(path)
                }
            }
        }
        walk(root, "", 0)
        let base = root
        return RepoListing(paths: out) { rel in
            let url = base.appendingPathComponent(rel)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 400_000 else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }
}

/// One thing in a project that can be tested on its own: an app, a site, a service, firmware.
public struct DetectedTarget: Equatable, Sendable, Codable {
    public var type: ProjectType
    /// The folder, relative to the repository; empty for its root.
    public var path: String
    /// What gave it away, in a few words.
    public var evidence: String
    /// A command found in the project, e.g. `npm run dev` or `./gradlew assembleDebug`.
    public var startCommand: String?
    public var testCommand: String?

    public init(type: ProjectType, path: String, evidence: String, startCommand: String? = nil, testCommand: String? = nil) {
        self.type = type
        self.path = path
        self.evidence = evidence
        self.startCommand = startCommand
        self.testCommand = testCommand
    }
}

/// Tells from a repository's files what it builds. A repository can hold several targets (an app and its backend);
/// each folder is looked at on its own and a folder inside one already found for the same type is skipped.
public enum ProjectDetector {
    public static func detect(_ listing: RepoListing) -> [DetectedTarget] {
        var dirs: Set<String> = [""]
        for p in listing.paths {
            let parts = p.split(separator: "/").map(String.init)
            if parts.count > 1 { dirs.insert(parts[0]) }
            if parts.count > 2 { dirs.insert(parts[0] + "/" + parts[1]) }
        }
        var found: [DetectedTarget] = []
        for dir in dirs.sorted(by: { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }) {
            for t in detect(in: dir, listing) {
                let covered = found.contains { f in
                    f.type == t.type && (f.path.isEmpty || t.path == f.path || t.path.hasPrefix(f.path + "/"))
                }
                if !covered { found.append(t) }
            }
        }
        let known = found.filter { $0.type != .unknown }
        return known.isEmpty ? [DetectedTarget(type: .unknown, path: "", evidence: "Nothing recognisable")] : known
    }

    /// The files directly in a folder and up to two levels below it, relative to it.
    static func files(in dir: String, _ listing: RepoListing, depth: Int = 3) -> [String] {
        let prefix = dir.isEmpty ? "" : dir + "/"
        return listing.paths.compactMap { p in
            guard p.hasPrefix(prefix) else { return nil }
            let rel = String(p.dropFirst(prefix.count))
            return rel.split(separator: "/").count <= depth ? rel : nil
        }
    }

    static func detect(in dir: String, _ listing: RepoListing) -> [DetectedTarget] {
        let files = files(in: dir, listing)
        let prefix = dir.isEmpty ? "" : dir + "/"
        func read(_ rel: String) -> String { listing.read(prefix + rel) ?? "" }
        func has(_ name: String) -> Bool { files.contains(name) }
        func any(_ match: (String) -> Bool) -> String? { files.first(where: match) }
        var out: [DetectedTarget] = []

        // Xcode projects: iOS or macOS by the SDK they build for.
        for pbx in files.filter({ $0.hasSuffix(".xcodeproj/project.pbxproj") }) where pbx.split(separator: "/").count <= 2 {
            let text = read(pbx)
            if text.contains("SDKROOT = iphoneos") || text.contains("TARGETED_DEVICE_FAMILY") {
                out.append(DetectedTarget(type: .ios, path: dir, evidence: "Xcode project for iOS"))
            }
            if text.contains("SDKROOT = macosx") {
                out.append(DetectedTarget(type: .desktopMac, path: dir, evidence: "Xcode project for macOS"))
            }
            if text.isEmpty { out.append(DetectedTarget(type: .ios, path: dir, evidence: "Xcode project")) }
        }
        if has("Package.swift") {
            let text = read("Package.swift")
            if text.contains(".iOS(") && !out.contains(where: { $0.type == .ios }) {
                out.append(DetectedTarget(type: .ios, path: dir, evidence: "Swift package for iOS", testCommand: "swift test"))
            }
            if text.contains(".executableTarget") && text.contains(".macOS(") && !out.contains(where: { $0.type == .desktopMac }) {
                out.append(DetectedTarget(type: .desktopMac, path: dir, evidence: "Swift package with a macOS app", startCommand: "swift run", testCommand: "swift test"))
            }
        }

        // Android: the application plugin in a Gradle build, or a manifest in the usual place.
        let gradle = files.filter { $0.hasSuffix("build.gradle") || $0.hasSuffix("build.gradle.kts") }
        if gradle.contains(where: { let t = read($0); return t.contains("com.android.application") || t.contains("android.application") })
            || has("app/src/main/AndroidManifest.xml") || has("src/main/AndroidManifest.xml") && has("build.gradle.kts") {
            let wrapper = has("gradlew") ? "./gradlew" : "gradle"
            out.append(DetectedTarget(type: .android, path: dir, evidence: "Android Gradle project",
                                      startCommand: "\(wrapper) assembleDebug", testCommand: "\(wrapper) testDebugUnitTest"))
        }

        // JavaScript: a front end, a back end, or an Electron desktop app.
        if has("package.json") {
            let pkg = read("package.json")
            let json = (try? JSONSerialization.jsonObject(with: Data(pkg.utf8))) as? [String: Any] ?? [:]
            let deps = ((json["dependencies"] as? [String: Any]) ?? [:]).merging((json["devDependencies"] as? [String: Any]) ?? [:]) { a, _ in a }
            let scripts = json["scripts"] as? [String: Any] ?? [:]
            let run = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : "npm run"
            let test = scripts["test"] != nil ? (run == "npm run" ? "npm test" : "\(run) test") : nil
            if deps["electron"] != nil {
                out.append(DetectedTarget(type: .desktopMac, path: dir, evidence: "Electron app", startCommand: scripts["start"] != nil ? "\(run) start" : nil, testCommand: test))
            }
            let frontEnd = ["react", "vue", "svelte", "next", "vite", "@angular/core", "phaser", "nuxt", "astro", "solid-js", "preact", "three", "pixi.js", "@sveltejs/kit"]
            let backEnd = ["express", "fastify", "@nestjs/core", "koa", "hapi", "@hapi/hapi", "hono"]
            if frontEnd.contains(where: { deps[$0] != nil }) {
                let start = scripts["dev"] != nil ? "\(run) dev" : scripts["start"] != nil ? "\(run) start" : nil
                out.append(DetectedTarget(type: .web, path: dir, evidence: "Web front end (\(frontEnd.first { deps[$0] != nil } ?? "")) ", startCommand: start, testCommand: test))
            } else if backEnd.contains(where: { deps[$0] != nil }) {
                out.append(DetectedTarget(type: .backend, path: dir, evidence: "Node.js service (\(backEnd.first { deps[$0] != nil } ?? ""))",
                                          startCommand: scripts["dev"] != nil ? "\(run) dev" : scripts["start"] != nil ? "\(run) start" : nil, testCommand: test))
            } else if has("index.html") || has("public/index.html") {
                out.append(DetectedTarget(type: .web, path: dir, evidence: "Web page with package.json",
                                          startCommand: scripts["dev"] != nil ? "\(run) dev" : scripts["start"] != nil ? "\(run) start" : nil, testCommand: test))
            }
        } else if has("index.html") && dir.isEmpty || has("index.html") && files.contains(where: { $0.hasSuffix(".js") || $0.hasSuffix(".css") }) {
            out.append(DetectedTarget(type: .web, path: dir, evidence: "Static web page", startCommand: "python3 -m http.server 8080"))
        }

        // Other back ends.
        if has("go.mod") {
            out.append(DetectedTarget(type: .backend, path: dir, evidence: "Go module", startCommand: "go run .", testCommand: "go test ./..."))
        }
        let pyText = ["requirements.txt", "pyproject.toml", "Pipfile"].filter(has).map(read).joined(separator: "\n").lowercased()
        if ["fastapi", "flask", "django", "aiohttp", "starlette"].contains(where: pyText.contains) || has("manage.py") {
            out.append(DetectedTarget(type: .backend, path: dir, evidence: "Python web service", testCommand: "pytest"))
        }
        let jvm = (gradle.map(read) + [has("pom.xml") ? read("pom.xml") : ""]).joined()
        if jvm.contains("spring-boot") || jvm.contains("io.ktor") || jvm.contains("quarkus") {
            out.append(DetectedTarget(type: .backend, path: dir, evidence: "JVM service", testCommand: has("gradlew") ? "./gradlew test" : has("pom.xml") ? "mvn test" : "gradle test"))
        }
        if has("Cargo.toml") {
            let cargo = read("Cargo.toml")
            if ["axum", "actix-web", "rocket", "warp", "poem"].contains(where: cargo.contains) {
                out.append(DetectedTarget(type: .backend, path: dir, evidence: "Rust service", startCommand: "cargo run", testCommand: "cargo test"))
            } else if cargo.contains("embedded-hal") || cargo.contains("cortex-m") || cargo.contains("esp-hal") {
                out.append(DetectedTarget(type: .embedded, path: dir, evidence: "Embedded Rust", startCommand: "cargo build --release", testCommand: "cargo test"))
            }
        }

        // .NET: web services and Windows desktop apps.
        for proj in files.filter({ $0.hasSuffix(".csproj") }) where proj.split(separator: "/").count <= 2 {
            let t = read(proj)
            if t.contains("Microsoft.NET.Sdk.Web") {
                out.append(DetectedTarget(type: .backend, path: dir, evidence: "ASP.NET service", startCommand: "dotnet run", testCommand: "dotnet test"))
            } else if t.contains("UseWPF") || t.contains("UseWindowsForms") || t.contains("Microsoft.WindowsAppSDK") || t.contains("WinExe") {
                out.append(DetectedTarget(type: .desktopWindows, path: dir, evidence: "Windows desktop app (.NET)", testCommand: "dotnet test"))
            }
        }
        if files.contains(where: { $0.hasSuffix(".vcxproj") }) {
            out.append(DetectedTarget(type: .desktopWindows, path: dir, evidence: "Visual C++ project"))
        }

        // Embedded and instrument software.
        if has("platformio.ini") {
            out.append(DetectedTarget(type: .embedded, path: dir, evidence: "PlatformIO project", startCommand: "pio run", testCommand: "pio test"))
        } else if has("sdkconfig") || has("sdkconfig.defaults") {
            out.append(DetectedTarget(type: .embedded, path: dir, evidence: "ESP-IDF project", startCommand: "idf.py build"))
        } else if has("prj.conf") && has("CMakeLists.txt") {
            out.append(DetectedTarget(type: .embedded, path: dir, evidence: "Zephyr project", startCommand: "west build"))
        } else if any({ $0.hasSuffix(".ioc") }) != nil || any({ $0.hasSuffix(".ino") }) != nil {
            out.append(DetectedTarget(type: .embedded, path: dir, evidence: "Microcontroller project"))
        } else if has("CMakeLists.txt") || has("Makefile") {
            let build = [has("CMakeLists.txt") ? read("CMakeLists.txt") : "", has("Makefile") ? read("Makefile") : ""].joined()
            if ["arm-none-eabi", "avr-gcc", "CMAKE_SYSTEM_PROCESSOR", "riscv", "STM32", "nrf", "FreeRTOS"].contains(where: build.contains) {
                out.append(DetectedTarget(type: .embedded, path: dir, evidence: "Cross-compiled C/C++", startCommand: has("Makefile") ? "make" : "cmake --build build"))
            }
        }
        return out
    }
}
