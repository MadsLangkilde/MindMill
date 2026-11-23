import CoreServices
import Foundation

/// Watches a folder recursively with FSEvents (file-level events) and reports the changed paths
/// once things have been quiet for `debounce` seconds. Paths inside `.git` are ignored.
public final class FileWatcher: @unchecked Sendable {
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
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
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
        let relevant = paths.filter { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }
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
