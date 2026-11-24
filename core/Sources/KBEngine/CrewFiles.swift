import Foundation
import KBCore

/// The crew folder's files (`CrewDir`): the engine writes `state.json` for `kb crew status`, and `kb crew send|start|stop`
/// leaves orders in `orders/` for the engine to carry out, oldest first.
public struct CrewFiles: Sendable {
    public let directory: URL

    public init(directory: URL = CrewDir.url()) {
        self.directory = directory
    }

    public var ordersFolder: URL { directory.appendingPathComponent("orders") }
    public var stateURL: URL { directory.appendingPathComponent("state.json") }

    public func prepare() {
        try? FileManager.default.createDirectory(at: ordersFolder, withIntermediateDirectories: true)
    }

    public func write(_ state: CrewState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: stateURL, options: .atomic)
    }

    /// The waiting orders' contents, oldest first; each file is removed once read.
    public func takeOrders() -> [Data] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: ordersFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return files.compactMap { file in
            let data = try? Data(contentsOf: file)
            try? FileManager.default.removeItem(at: file)
            return data
        }
    }

    /// Whether `state.json` is due: something changed, or it hasn't been written for 30 seconds.
    public static func needsWrite(_ state: CrewState, last: CrewState?, dirty: Bool, written: Date, now: Date = Date()) -> Bool {
        dirty || state.sessions != last?.sessions || now.timeIntervalSince(written) > 30
    }
}
