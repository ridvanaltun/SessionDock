import Foundation
import GRDB

public enum ThemePreference: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public enum LogLevelPreference: String, Codable, CaseIterable, Sendable, Identifiable {
    case error
    case warning
    case info
    case debug

    public var id: String { rawValue }
}

public struct AppPreferences: Codable, Hashable, Sendable {
    public var theme: ThemePreference = .system
    public var autoScanEnabled: Bool = true
    public var scanIntervalMinutes: Int = 5
    /// Custom backup folder. `nil` means `~/Library/Application Support/SessionDock/Backups`.
    public var backupDirectory: String?
    public var backupRetentionCount: Int = 10
    public var logLevel: LogLevelPreference = .info
    public var showSubagentsInExplorer: Bool = true
    public var pathOverrides = PathOverrides()

    public init() {}
}

/// Application preferences, stored as one JSON document in the local index database.
public struct PreferenceStore: Sendable {
    private static let key = "app"
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func load() throws -> AppPreferences {
        let text = try database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM preference WHERE key = ?", arguments: [Self.key])
        }
        guard let text, let data = text.data(using: .utf8) else { return AppPreferences() }
        return (try? JSONDecoder().decode(AppPreferences.self, from: data)) ?? AppPreferences()
    }

    public func save(_ preferences: AppPreferences) throws {
        let text = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
        try database.writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO preference (key, value) VALUES (?, ?)", arguments: [Self.key, text])
        }
    }
}
