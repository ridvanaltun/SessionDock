import Foundation

/// What the OpenCode database actually contains, discovered at runtime.
///
/// OpenCode 2.x keeps sessions in `session_v2` / `session_message` / `session_part` and
/// still has the legacy `session` / `message` / `part` tables. Readers choose the columns and
/// tables that exist, so a future schema change degrades the view instead of failing silently.
public struct OpenCodeSchemaProfile: Sendable, Hashable {
    public var tables: Set<String>
    public var columns: [String: Set<String>]

    public init(tables: Set<String>, columns: [String: Set<String>]) {
        self.tables = tables
        self.columns = columns
    }

    public func has(table: String) -> Bool { tables.contains(table) }

    public func has(column: String, in table: String) -> Bool {
        columns[table]?.contains(column) ?? false
    }

    public var hasV2Sessions: Bool { has(table: "session_v2") }
    public var hasV2Messages: Bool { has(table: "session_message") }
    public var hasLegacySessions: Bool { has(table: "session") }
    public var hasLegacyMessages: Bool { has(table: "message") && has(table: "part") }

    public var summary: String {
        var parts: [String] = []
        if hasV2Sessions { parts.append("v2 sessions") }
        if hasLegacySessions { parts.append("legacy sessions") }
        if hasV2Messages { parts.append("v2 messages") }
        if hasLegacyMessages { parts.append("legacy messages") }
        return parts.isEmpty ? "No session tables found" : parts.joined(separator: ", ")
    }

    /// Table names that matter to the reader. Everything else is ignored by the summary.
    static let relevantTables: Set<String> = [
        "session_v2", "session_message", "session_part", "session", "message", "part", "project", "migration",
    ]
}
