import AppKit
import KBCore
@preconcurrency import ScreenCaptureKit
import Vision

/// Watches one window or screen the user picks (the call, the shared slides), or an area of it, and reads its text
/// on this Mac whenever it changes. Only text leaves this class, unless the user shows Claude a picture or lets it
/// show Claude each big change (a new slide).
@MainActor
@Observable
final class ScreenWatcher {
    /// A window, or a whole screen when `isDisplay`.
    struct Window: Identifiable, Hashable {
        /// The window's id, or the display's.
        let ref: UInt32
        var isDisplay = false
        let app: String
        let title: String
        let pid: pid_t
        var id: String { (isDisplay ? "d" : "w") + String(ref) }
        var name: String { isDisplay ? title : title.isEmpty ? app : "\(app): \(title)" }
        var icon: NSImage? {
            isDisplay ? NSImage(systemSymbolName: "display", accessibilityDescription: nil) : NSRunningApplication(processIdentifier: pid)?.icon
        }
    }

    private(set) var windows: [Window] = []
    private(set) var displays: [Window] = []
    /// The part of it to read, in fractions of its size; nil reads all of it.
    private(set) var area: CGRect?
    /// Show Claude a picture by itself when the content changes a lot, like a new slide. On by default: following
    /// the screen means Claude sees the slides, not only their text.
    var picturesOnChange = true {
        didSet { lastAutoPicture = nil }
    }
    /// When new text was last found, and the start of it.
    private(set) var lastChange: Date?
    private(set) var lastSnippet: String?
    /// When Claude was last shown a picture by itself.
    private(set) var lastPicture: Date?
    private(set) var watching: Window?
    private(set) var error: String?
    private(set) var permissionMissing = false
    /// When the window's text was last read, and whether a read is running now.
    private(set) var lastRead: Date?
    private(set) var reading = false
    @ObservationIgnored var onText: ((String, Window) -> Void)?
    @ObservationIgnored var onPicture: ((CGImage, Window) -> Void)?

    @ObservationIgnored private var scWindows: [CGWindowID: SCWindow] = [:]
    @ObservationIgnored private var scDisplays: [CGDirectDisplayID: SCDisplay] = [:]
    @ObservationIgnored private var ownApps: [SCRunningApplication] = []
    @ObservationIgnored private var lastAutoPicture: Date?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastThumb: [UInt8]?
    @ObservationIgnored private var lastLines: [String] = []
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var failures = 0

    static let interval: TimeInterval = 4
    /// Average change per pixel of a 24×24 thumbnail that counts as new content; video tiles move less than this.
    static let changeThreshold = 4.0
    /// A change this big is a new slide or page, worth a picture when the user asked for them.
    static let bigChangeThreshold = 20.0
    /// At most one picture by itself this often.
    static let autoPictureGap: TimeInterval = 45

    var isOn: Bool { watching != nil }

    func refreshWindows() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let mine = Bundle.main.bundleIdentifier
            let usable = content.windows.filter { w in
                w.windowLayer == 0 && w.frame.width >= 300 && w.frame.height >= 200
                    && w.owningApplication?.bundleIdentifier != mine
                    && !(w.owningApplication?.applicationName ?? "").isEmpty
            }
            scWindows = Dictionary(usable.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            windows = usable.map {
                Window(ref: $0.windowID, app: $0.owningApplication?.applicationName ?? "", title: $0.title ?? "",
                       pid: $0.owningApplication?.processID ?? 0)
            }
            .sorted { ($0.app.lowercased(), $0.title.lowercased()) < ($1.app.lowercased(), $1.title.lowercased()) }
            scDisplays = Dictionary(content.displays.map { ($0.displayID, $0) }, uniquingKeysWith: { a, _ in a })
            ownApps = content.applications.filter { $0.bundleIdentifier == mine }
            let names = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
                guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return (CGDirectDisplayID(n.uint32Value), screen.localizedName)
            }, uniquingKeysWith: { a, _ in a })
            displays = content.displays.enumerated().map { i, d in
                Window(ref: d.displayID, isDisplay: true, app: "Screen",
                       title: names[d.displayID] ?? "Screen \(i + 1)", pid: 0)
            }
            permissionMissing = false
            if error != nil, watching == nil { error = nil }
        } catch {
            windows = []
            displays = []
            permissionMissing = !CGPreflightScreenCaptureAccess()
            self.error = permissionMissing
                ? "Mindmill may not see the screen. Allow it under System Settings → Privacy & Security → Screen & System Audio Recording, then reopen Mindmill."
                : "Could not list the windows: \(error.localizedDescription)"
        }
    }

    func watch(_ window: Window) {
        stop()
        watching = window
        area = nil
        lastChange = nil
        lastSnippet = nil
        lastPicture = nil
        error = nil
        failures = 0
        lastThumb = nil
        lastLines = []
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        watching = nil
        reading = false
    }

    /// Reads only `area` from now on; nil reads all of it.
    func setArea(_ area: CGRect?) {
        self.area = area
        lastThumb = nil
        lastLines = []
        check()
    }

    /// A picture of what is watched (its area, when one is set), for the user to show Claude; at most 1600 px wide.
    func picture() async throws -> CGImage {
        guard let w = watching else { throw WatchError.noWindow }
        return try await capture(w, maxWidth: area == nil ? 1600 : 2400, cropped: true)
    }

    /// All of what is watched, to choose an area on.
    func wholePicture() async throws -> CGImage {
        guard let w = watching else { throw WatchError.noWindow }
        return try await capture(w, maxWidth: 1600, cropped: false)
    }

    private func check() {
        guard !busy, let w = watching else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let image = try await capture(w, maxWidth: 2400, cropped: true)
                failures = 0
                let thumb = Self.thumbnail(image)
                let change = lastThumb.map { ScreenText.difference($0, thumb) }
                if let change, change < Self.changeThreshold { return }
                lastThumb = thumb
                if picturesOnChange, let change, change >= Self.bigChangeThreshold,
                   Date().timeIntervalSince(lastAutoPicture ?? .distantPast) >= Self.autoPictureGap {
                    lastAutoPicture = Date()
                    lastPicture = Date()
                    onPicture?(image, w)
                }
                reading = true
                let lines = await Self.recognize(image)
                reading = false
                lastRead = Date()
                guard watching == w else { return }
                if let added = ScreenText.added(lines, since: lastLines) {
                    let line = ScreenText.line(added)
                    lastChange = Date()
                    lastSnippet = String(line.prefix(120))
                    onText?(line, w)
                }
                lastLines = lines
            } catch {
                reading = false
                failures += 1
                // The window was closed or moved to another space for a while: stop rather than retry forever.
                if failures >= 3 {
                    let name = w.name
                    stop()
                    self.error = "Stopped watching \(name): Mindmill can no longer see it."
                }
            }
        }
    }

    private func capture(_ w: Window, maxWidth: CGFloat, cropped: Bool) async throws -> CGImage {
        let filter: SCContentFilter
        let frame: CGRect
        if w.isDisplay {
            guard let d = scDisplays[w.ref] else { throw WatchError.noWindow }
            // Mindmill's own windows stay out of the picture.
            filter = SCContentFilter(display: d, excludingApplications: ownApps, exceptingWindows: [])
            frame = d.frame
        } else {
            guard let sc = scWindows[w.ref] else { throw WatchError.noWindow }
            filter = SCContentFilter(desktopIndependentWindow: sc)
            frame = sc.frame
        }
        let config = SCStreamConfiguration()
        // A small area gets the full resolution, so its text stays readable.
        let wanted = cropped ? maxWidth / max(area?.width ?? 1, 0.25) : maxWidth
        let scale = min(CGFloat(filter.pointPixelScale), wanted / max(frame.width, 1))
        config.width = max(1, Int(frame.width * scale))
        config.height = max(1, Int(frame.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard cropped, let area, let part = image.cropping(to: ScreenArea.pixels(area, width: image.width, height: image.height)) else {
            return image
        }
        return part
    }

    static func thumbnail(_ image: CGImage, size: Int = 24) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size)
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        return pixels
    }

    /// The window's text, line by line in reading order, recognised on this Mac.
    nonisolated static func recognize(_ image: CGImage) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["en-US", "da-DK"]
                try? VNImageRequestHandler(cgImage: image).perform([request])
                let lines = (request.results ?? [])
                    .filter { $0.confidence >= 0.4 }
                    .compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines)
            }
        }
    }

    /// Writes a picture where the meeting's Claude session can read it; the caller deletes it after.
    static func save(_ image: CGImage) throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("KB/screen")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString.prefix(8)).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw WatchError.encode
        }
        try data.write(to: url)
        return url
    }

    enum WatchError: LocalizedError {
        case noWindow, encode
        var errorDescription: String? {
            switch self {
            case .noWindow: return "No window is being watched."
            case .encode: return "Could not save the picture."
            }
        }
    }
}
