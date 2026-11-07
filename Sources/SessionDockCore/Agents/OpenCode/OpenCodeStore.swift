import Foundation
import GRDB

/// Read-only access to an OpenCode SQLite database.
///
/// Connections are opened read-only (see `ReadOnlyDatabase`), so this type cannot run DDL or DML.
/// Scanning and inspection never create tables, change journal modes, or checkpoint the WAL.
public struct OpenCodeStore: Sendable {
    public let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public static func openReadOnly(at url: URL) throws -> DatabaseQueue {
        try ReadOnlyDatabase.open(at: url)
    }

    public func openReadOnly() throws -> DatabaseQueue {
        try Self.openReadOnly(at: databaseURL)
    }

    public func profile() throws -> OpenCodeSchemaProfile {
        try openReadOnly().read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
                .filter { OpenCodeSchemaProfile.relevantTables.contains($0) }
            var columns: [String: Set<String>] = [:]
            for table in tables {
                columns[table] = Set(try db.columns(in: table).map(\.name))
            }
            return OpenCodeSchemaProfile(tables: Set(tables), columns: columns)
        }
    }

    public func quickCheck() throws -> String {
        try openReadOnly().read { db in
            try String.fetchOne(db, sql: "PRAGMA quick_check(1)") ?? "unknown"
        }
    }

    // MARK: - Sessions

    /// Sessions from the v2 store, plus legacy sessions that the v2 store does not contain.
    public func sessions(profile: OpenCodeSchemaProfile) throws -> [SessionSummary] {
        try openReadOnly().read { db in
            var result: [SessionSummary] = []
            var seen = Set<String>()

            if profile.hasV2Sessions {
                let v2 = try Row.fetchAll(db, sql: """
                    SELECT \(select(["id", "project_id", "parent_id", "title", "directory", "time_created", "time_updated",
                                     "metadata", "model", "agent", "time_archived", "slug", "version", "workspace_id"],
                                    table: "session_v2", profile: profile)),
                           (SELECT COUNT(*) FROM session_message m
                             WHERE m.session_id = s.id AND m.type IN ('user', 'assistant', 'system', 'synthetic')) AS message_count,
                           (SELECT COUNT(*) FROM session_message m, json_each(m.data, '$.content') j
                             WHERE m.session_id = s.id AND m.type = 'assistant'
                               AND json_extract(j.value, '$.type') = 'tool') AS tool_count
                    FROM session_v2 s
                    """)
                for row in v2 {
                    guard let session = Self.sessionSummary(from: row, source: "session_v2") else { continue }
                    seen.insert(row["id"] ?? "")
                    result.append(session)
                }
            }

            if profile.hasLegacySessions {
                let legacy = try Row.fetchAll(db, sql: """
                    SELECT \(select(["id", "project_id", "parent_id", "title", "directory", "time_created", "time_updated",
                                     "metadata", "agent", "model", "slug", "version", "workspace_id"],
                                    table: "session", profile: profile)),
                           (SELECT COUNT(*) FROM message m WHERE m.session_id = s.id) AS message_count,
                           (SELECT COUNT(*) FROM part p WHERE p.session_id = s.id
                             AND json_extract(p.data, '$.type') = 'tool') AS tool_count
                    FROM session s
                    """)
                for row in legacy {
                    let id: String = row["id"] ?? ""
                    guard !seen.contains(id) else { continue }
                    guard let session = Self.sessionSummary(from: row, source: "session") else { continue }
                    result.append(session)
                }
            }
            return result
        }
    }

    /// Capped user-text excerpts per session, for the search index. Limited in SQL so that whole
    /// conversations are never materialised during indexing.
    public func searchExcerpts(profile: OpenCodeSchemaProfile) throws -> [String: String] {
        try openReadOnly().read { db in
            var excerpts: [String: String] = [:]
            if profile.hasV2Messages {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT session_id AS sid,
                           substr(group_concat(substr(json_extract(data, '$.text'), 1, 1000), char(10)), 1, 12000) AS excerpt
                    FROM session_message
                    WHERE type = 'user' AND json_extract(data, '$.text') IS NOT NULL
                    GROUP BY session_id
                    """)
                for row in rows {
                    let id: String = row["sid"] ?? ""
                    excerpts[id] = (row["excerpt"] as String?) ?? ""
                }
            }
            if profile.hasLegacyMessages {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT session_id AS sid,
                           substr(group_concat(substr(json_extract(data, '$.text'), 1, 1000), char(10)), 1, 12000) AS excerpt
                    FROM part
                    WHERE json_extract(data, '$.type') = 'text' AND json_extract(data, '$.text') IS NOT NULL
                    GROUP BY session_id
                    """)
                for row in rows {
                    let id: String = row["sid"] ?? ""
                    if excerpts[id] == nil { excerpts[id] = (row["excerpt"] as String?) ?? "" }
                }
            }
            return excerpts
        }
    }

    /// Maps OpenCode's `project` table so that session metadata can name the OpenCode project.
    public func openCodeProjectNames() throws -> [String: String] {
        let profile = try profile()
        guard profile.has(table: "project") else { return [:] }
        return try openReadOnly().read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, worktree, name FROM project")
            var names: [String: String] = [:]
            for row in rows {
                let id: String = row["id"] ?? ""
                names[id] = (row["name"] as String?) ?? (row["worktree"] as String?) ?? id
            }
            return names
        }
    }

    /// Looks up which OpenCode sessions were created from a Claude Code origin id.
    /// Used to detect duplicates before migrating and to verify after migrating.
    public func originMap() throws -> [OriginRecord] {
        let profile = try profile()
        return try openReadOnly().read { db in
            var records: [OriginRecord] = []
            for table in ["session_v2", "session"] where profile.has(table: table) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, parent_id, title, metadata,
                           json_extract(metadata, '$.claude_code_origin') AS origin,
                           json_extract(metadata, '$.claude_code_parent') AS origin_parent
                    FROM \(table) WHERE json_extract(metadata, '$.claude_code_origin') IS NOT NULL
                    """)
                for row in rows {
                    let id: String = row["id"] ?? ""
                    let origin: String = row["origin"] ?? ""
                    guard !origin.isEmpty else { continue }
                    records.append(OriginRecord(
                        openCodeSessionId: id,
                        originId: origin,
                        originParentId: row["origin_parent"] as String?,
                        parentOpenCodeSessionId: row["parent_id"] as String?,
                        title: row["title"] as String? ?? "",
                        table: table
                    ))
                }
            }
            return records
        }
    }

    public struct OriginRecord: Sendable, Hashable {
        public var openCodeSessionId: String
        public var originId: String
        public var originParentId: String?
        public var parentOpenCodeSessionId: String?
        public var title: String
        public var table: String
    }

    // MARK: - Counts and identifiers (verification)

    public struct SessionCounts: Sendable, Hashable {
        public var messages: Int
        public var toolCalls: Int
        public var v2Messages: Int
    }

    /// Counts for a session id across both generations of tables.
    public func counts(forSession sessionId: String, profile: OpenCodeSchemaProfile) throws -> SessionCounts {
        try openReadOnly().read { db in
            var legacy = 0
            var legacyTools = 0
            var v2 = 0
            if profile.has(table: "message") {
                legacy = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE session_id = ?", arguments: [sessionId]) ?? 0
            }
            if profile.has(table: "part") {
                legacyTools = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM part WHERE session_id = ? AND json_extract(data, '$.type') = 'tool'
                    """, arguments: [sessionId]) ?? 0
            }
            if profile.has(table: "session_message") {
                v2 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_message WHERE session_id = ?", arguments: [sessionId]) ?? 0
            }
            return SessionCounts(messages: legacy, toolCalls: legacyTools, v2Messages: v2)
        }
    }

    /// Legacy message rows per role for one session, for prompt-level verification.
    public func roleCounts(forSession sessionId: String) throws -> [String: Int] {
        try openReadOnly().read { db in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT json_extract(data, '$.role') AS role, COUNT(*) AS n FROM message
                WHERE session_id = ? GROUP BY role
                """, arguments: [sessionId]) {
                if let role: String = row["role"] { counts[role] = row["n"] }
            }
            return counts
        }
    }

    /// Project ids already in the destination. OpenCode keys projects by the SHA-1 of their worktree.
    public func projectIds() throws -> Set<String> {
        guard try profile().has(table: "project") else { return [] }
        return try openReadOnly().read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM project"))
        }
    }

    public func sessionIDs(profile: OpenCodeSchemaProfile) throws -> Set<String> {
        try openReadOnly().read { db in
            var ids = Set<String>()
            for table in ["session_v2", "session"] where profile.has(table: table) {
                for id in try String.fetchAll(db, sql: "SELECT id FROM \(table)") { ids.insert(id) }
            }
            return ids
        }
    }

    /// Returns a stable description of the rows that matter for migration. Any change to these
    /// rows (new session, new message, edited title) changes the signature, so a plan can detect
    /// that the database moved underneath it.
    public func stateSignature(profile: OpenCodeSchemaProfile) throws -> String {
        try openReadOnly().read { db in
            var pieces: [String] = []
            for table in ["session_v2", "session", "message", "part", "session_message"] where profile.has(table: table) {
                let updated = profile.has(column: "time_updated", in: table) ? "MAX(time_updated)" : "0"
                let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, \(updated) AS latest FROM \(table)")
                pieces.append("\(table):\((row?["n"] as Int?) ?? 0):\((row?["latest"] as Int64?) ?? 0)")
            }
            return Sha256Hex.digest(of: pieces.joined(separator: "|"))
        }
    }

    // MARK: - Messages

    public func messages(
        forSession sessionOriginalId: String,
        profile: OpenCodeSchemaProfile,
        offset: Int,
        limit: Int
    ) throws -> MessagePage {
        try openReadOnly().read { db in
            if profile.hasV2Messages, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_message WHERE session_id = ?",
                                                      arguments: [sessionOriginalId]) ?? 0 > 0 {
                return try v2Messages(db, session: sessionOriginalId, offset: offset, limit: limit)
            }
            if profile.hasLegacyMessages {
                return try legacyMessages(db, session: sessionOriginalId, offset: offset, limit: limit)
            }
            return MessagePage(messages: [], nextOffset: nil)
        }
    }

    private func v2Messages(_ db: Database, session: String, offset: Int, limit: Int) throws -> MessagePage {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, type, seq, time_created, data FROM session_message
            WHERE session_id = ? ORDER BY seq, id LIMIT ? OFFSET ?
            """, arguments: [session, limit + 1, offset])
        let hasMore = rows.count > limit
        var messages: [Message] = []
        for row in rows.prefix(limit) {
            let id: String = row["id"] ?? ""
            let type: String = row["type"] ?? "unknown"
            let seq: Int = row["seq"] ?? 0
            let created: Double? = row["time_created"]
            let data = (row["data"] as String?).flatMap { try? JSONValue.parse(Data($0.utf8)) } ?? .null
            messages.append(OpenCodeMessageMapper.v2Message(
                id: id, sessionId: session, ordinal: seq, type: type,
                timestamp: TimestampParser.fromEpochMilliseconds(created), data: data
            ))
        }
        return MessagePage(messages: messages, nextOffset: hasMore ? offset + limit : nil)
    }

    private func legacyMessages(_ db: Database, session: String, offset: Int, limit: Int) throws -> MessagePage {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, time_created, data FROM message
            WHERE session_id = ? ORDER BY time_created, id LIMIT ? OFFSET ?
            """, arguments: [session, limit + 1, offset])
        let hasMore = rows.count > limit
        var messages: [Message] = []
        for (position, row) in rows.prefix(limit).enumerated() {
            let id: String = row["id"] ?? ""
            let created: Double? = row["time_created"]
            let data = (row["data"] as String?).flatMap { try? JSONValue.parse(Data($0.utf8)) } ?? .null
            let partRows = try Row.fetchAll(db, sql: """
                SELECT data FROM part WHERE message_id = ? ORDER BY time_created, id
                """, arguments: [id])
            let parts = partRows.map { row -> JSONValue in
                (row["data"] as String?).flatMap { try? JSONValue.parse(Data($0.utf8)) } ?? .null
            }
            messages.append(OpenCodeMessageMapper.legacyMessage(
                id: id, sessionId: session, ordinal: offset + position,
                timestamp: TimestampParser.fromEpochMilliseconds(created), data: data, parts: parts
            ))
        }
        return MessagePage(messages: messages, nextOffset: hasMore ? offset + limit : nil)
    }

    // MARK: - Row mapping

    private func select(_ wanted: [String], table: String, profile: OpenCodeSchemaProfile) -> String {
        wanted.map { column in
            profile.has(column: column, in: table) ? "s.\(column)" : "NULL AS \(column)"
        }.joined(separator: ", ")
    }

    private static func sessionSummary(from row: Row, source: String) -> SessionSummary? {
        let id: String = row["id"] ?? ""
        guard !id.isEmpty else { return nil }
        let directory: String = (row["directory"] as String?) ?? ""
        let projectPath = directory.isEmpty ? "/" : directory
        let metadataText: String? = row["metadata"]
        var metadata: [String: JSONValue] = [:]
        if let metadataText, let parsed = try? JSONValue.parse(Data(metadataText.utf8)), let object = parsed.objectValue {
            metadata = object
        } else if let metadataText, !metadataText.isEmpty {
            metadata["rawMetadata"] = .string(metadataText)
        }
        metadata["storageTable"] = .string(source)
        if let projectId: String = row["project_id"] { metadata["openCodeProjectId"] = .string(projectId) }
        if let slug: String = row["slug"] { metadata["slug"] = .string(slug) }
        if let version: String = row["version"] { metadata["openCodeVersion"] = .string(version) }
        if let workspace: String = row["workspace_id"] { metadata["workspaceId"] = .string(workspace) }
        if let archived: Double = row["time_archived"] { metadata["archivedAt"] = .number(archived) }

        let parentId: String? = row["parent_id"]
        let originId = metadata["claude_code_origin"]?.stringValue
        let isSubagent = metadata["is_subagent"]?.boolValue ?? (parentId != nil)

        let modelText = modelDisplayName(row["model"] as String?)
        let title: String = (row["title"] as String?).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled session"

        return SessionSummary(
            agent: .openCode,
            originalId: id,
            projectId: ProjectIdentity.id(for: .openCode, path: projectPath),
            projectPath: projectPath,
            parentSessionId: parentId.map { SessionSummary.compositeID(agent: .openCode, originalId: $0) },
            isSubagent: isSubagent,
            subagentType: (row["agent"] as String?).flatMap { $0.isEmpty ? nil : $0 },
            title: title,
            createdAt: TimestampParser.fromEpochMilliseconds(row["time_created"]),
            updatedAt: TimestampParser.fromEpochMilliseconds(row["time_updated"]),
            messageCount: (row["message_count"] as Int?) ?? 0,
            toolCallCount: (row["tool_count"] as Int?) ?? 0,
            model: modelText,
            sourcePath: nil,
            metadata: metadata.merging(originId.map { ["claude_code_origin": .string($0)] } ?? [:]) { current, _ in current }
        )
    }

    static func modelDisplayName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("{"), let parsed = try? JSONValue.parse(Data(raw.utf8)) {
            let modelId = parsed["id"]?.stringValue ?? ""
            let provider = parsed["providerID"]?.stringValue ?? ""
            if modelId.isEmpty { return nil }
            return provider.isEmpty ? modelId : "\(provider)/\(modelId)"
        }
        return raw
    }
}
