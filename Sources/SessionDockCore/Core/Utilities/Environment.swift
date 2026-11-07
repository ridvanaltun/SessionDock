import Foundation

/// Injected view of the host: home directory and environment variables.
/// Adapters receive this instead of reading globals so tests can use fixtures.
public struct HostEnvironment: Sendable {
    public var homeDirectory: URL
    public var variables: [String: String]

    public init(homeDirectory: URL, variables: [String: String] = [:]) {
        self.homeDirectory = homeDirectory
        self.variables = variables
    }

    /// The real host, unless `SESSIONDOCK_HOME` points at another home. In that mode the data-location
    /// variables are dropped too, so that nothing from the real machine is read. Used for demos,
    /// screenshots and automated smoke tests.
    public static var current: HostEnvironment {
        var variables = ProcessInfo.processInfo.environment
        guard let override = variables["SESSIONDOCK_HOME"], !override.isEmpty else {
            return HostEnvironment(homeDirectory: FileManager.default.homeDirectoryForCurrentUser, variables: variables)
        }
        for name in ["CLAUDE_CONFIG_DIR", "CLAUDE_CODE_HOME", "OPENCODE_DATA_HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME"] {
            variables.removeValue(forKey: name)
        }
        return HostEnvironment(
            homeDirectory: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true),
            variables: variables
        )
    }

    /// Returns an absolute directory URL for an environment variable, if set and non-empty.
    public func directory(forVariable name: String) -> URL? {
        guard let value = variables[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
    }

    public func expandingTilde(_ path: String) -> URL {
        if path.hasPrefix("~") {
            let rest = path.dropFirst()
            return homeDirectory.appending(path: rest.hasPrefix("/") ? String(rest.dropFirst()) : String(rest))
        }
        return URL(fileURLWithPath: path)
    }
}

/// Application-owned locations inside `~/Library/Application Support/SessionDock`.
public struct AppPaths: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func standard(in environment: HostEnvironment) -> AppPaths {
        AppPaths(root: environment.homeDirectory
            .appending(path: "Library/Application Support/SessionDock", directoryHint: .isDirectory))
    }

    public var indexDatabase: URL { root.appending(path: "sessiondock.sqlite") }
    public var defaultBackups: URL { root.appending(path: "Backups", directoryHint: .isDirectory) }
    public var snapshots: URL { root.appending(path: "Snapshots", directoryHint: .isDirectory) }
    public var logs: URL { root.appending(path: "Logs", directoryHint: .isDirectory) }
}
