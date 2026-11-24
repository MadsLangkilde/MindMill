import Foundation

/// Mindmill's own data (never the KB): crew state, scans, remote identity, histories.
/// macOS keeps the folder name from before the rename, `~/Library/Application Support/KB`; Windows uses
/// `%APPDATA%\Mindmill`, the place `kb` (scripts/kb.py) and the engine host's `engine.json` use too.
public enum AppPaths {
    public static var data: URL { data(environment: ProcessInfo.processInfo.environment) }

    public static func data(environment: [String: String]) -> URL {
        #if os(Windows)
        return dataFolder(windows: true, environment: environment, applicationSupport: applicationSupport)
        #else
        return dataFolder(windows: false, environment: environment, applicationSupport: applicationSupport)
        #endif
    }

    /// A file or folder in the data folder.
    public static func file(_ name: String) -> URL { data.appendingPathComponent(name) }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// `MINDMILL_DATA` puts the data folder elsewhere: tests and a second engine next to the Mac app use it.
    static func dataFolder(windows: Bool, environment: [String: String], applicationSupport: URL) -> URL {
        if let custom = environment["MINDMILL_DATA"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        if windows {
            if let appData = environment["APPDATA"], !appData.isEmpty {
                return URL(fileURLWithPath: appData, isDirectory: true).appendingPathComponent("Mindmill", isDirectory: true)
            }
            return applicationSupport.appendingPathComponent("Mindmill", isDirectory: true)
        }
        return applicationSupport.appendingPathComponent("KB", isDirectory: true)
    }
}
