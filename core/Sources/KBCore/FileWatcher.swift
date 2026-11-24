import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// Watches a folder recursively and reports the changed paths once things have been quiet for a moment. Paths
/// inside `.git` are ignored. `FileWatcher` is the platform's best one: FSEvents on macOS, polling elsewhere until
/// a host brings its own (Windows: `ReadDirectoryChangesW`) through `FileWatchers.factory`.
public protocol FileWatching: AnyObject {
    /// Starts watching; false when the folder can't be watched.
    @discardableResult func start() -> Bool
    func stop()
}

public enum FileWatchers {
    public typealias Factory = (_ path: String, _ debounce: TimeInterval, _ callbackQueue: DispatchQueue,
                                _ handler: @escaping ([String]) -> Void) -> FileWatching

    /// How the engine makes watchers; a host replaces it with its own platform watcher.
    nonisolated(unsafe) public static var factory: Factory = { path, debounce, queue, handler in
        FileWatcher(path: path, debounce: debounce, callbackQueue: queue, handler: handler)
    }

    public static func make(path: String, debounce: TimeInterval = 0.2, callbackQueue: DispatchQueue = .main,
                            handler: @escaping ([String]) -> Void) -> FileWatching {
        factory(path, debounce, callbackQueue, handler)
    }

    /// Whether a changed path is inside a `.git` folder, with either separator.
    public static func isInsideGit(_ path: String) -> Bool {
        let p = path.replacingOccurrences(of: "\\", with: "/")
        return p.contains("/.git/") || p.hasSuffix("/.git")
    }
}

#if canImport(CoreServices)
public typealias FileWatcher = FSEventsFileWatcher
#else
public typealias FileWatcher = PollingFileWatcher
#endif

#if canImport(CoreServices)
/// Watches a folder recursively with FSEvents (file-level events) and reports the changed paths
/// once things have been quiet for `debounce` seconds. Paths inside `.git` are ignored.
public final class FSEventsFileWatcher: FileWatching, @unchecked Sendable {
    private let path: String
    private let debounce: TimeInterval
    private let callbackQueue: DispatchQueue
    private let handler: ([String]) -> Void
    private let queue = DispatchQueue(label: "dk.langkilde.kb.fsevents")
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var changed: Set<String> = []

    public init(path: String, debounce: TimeInterval = 0.2, callbackQueue: DispatchQueue = .main, handler: @escaping ([String]) -> Void) {
        self.path = path
        self.debounce = debounce
        self.callbackQueue = callbackQueue
        self.handler = handler
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsFileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var list: [String] = []
            list.reserveCapacity(count)
            for case let p as String in array { list.append(p) }
            watcher.received(list)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
        )
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags
        ) else { return false }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
        queue.sync {
            pending?.cancel()
            pending = nil
        }
    }

    private func received(_ paths: [String]) {
        let relevant = paths.filter { !FileWatchers.isInsideGit($0) }
        guard !relevant.isEmpty else { return }
        changed.formUnion(relevant)
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = Array(self.changed)
            self.changed.removeAll()
            self.callbackQueue.async { self.handler(batch) }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
#endif

/// Watches a folder by comparing snapshots (modification date and size of every file) every `interval` seconds.
/// Plain Foundation, so it works everywhere; slower to notice than a native watcher and costs a walk per poll.
public final class PollingFileWatcher: FileWatching, @unchecked Sendable {
    private let root: URL
    private let debounce: TimeInterval
    private let interval: TimeInterval
    private let callbackQueue: DispatchQueue
    private let handler: ([String]) -> Void
    private let queue = DispatchQueue(label: "dk.langkilde.kb.pollwatch")
    private var timer: DispatchSourceTimer?
    private var snapshot: [String: Stamp] = [:]
    private var pending: DispatchWorkItem?
    private var changed: Set<String> = []

    struct Stamp: Equatable {
        var modified: Date?
        var size: Int?
    }

    public init(path: String, debounce: TimeInterval = 0.2, interval: TimeInterval = 1, callbackQueue: DispatchQueue = .main,
                handler: @escaping ([String]) -> Void) {
        root = URL(fileURLWithPath: path)
        self.debounce = debounce
        self.interval = interval
        self.callbackQueue = callbackQueue
        self.handler = handler
    }

    deinit {
        timer?.cancel()
    }

    @discardableResult
    public func start() -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return false }
        return queue.sync {
            guard timer == nil else { return true }
            snapshot = Self.scan(root)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval)
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            timer = t
            return true
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            pending?.cancel()
            pending = nil
        }
    }

    private func poll() {
        let now = Self.scan(root)
        let diff = Self.changes(from: snapshot, to: now)
        snapshot = now
        guard !diff.isEmpty else { return }
        changed.formUnion(diff)
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = Array(self.changed)
            self.changed.removeAll()
            self.callbackQueue.async { self.handler(batch) }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    static func changes(from old: [String: Stamp], to new: [String: Stamp]) -> Set<String> {
        var out: Set<String> = []
        for (path, stamp) in new where old[path] != stamp { out.insert(path) }
        for path in old.keys where new[path] == nil { out.insert(path) }
        return out
    }

    static func scan(_ root: URL) -> [String: Stamp] {
        var out: [String: Stamp] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return out }
        for case let url as URL in walker {
            if url.lastPathComponent == ".git" {
                walker.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            out[url.path] = Stamp(modified: values?.contentModificationDate, size: values?.fileSize)
        }
        return out
    }
}
