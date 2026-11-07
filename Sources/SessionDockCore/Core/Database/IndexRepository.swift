import Foundation
import GRDB

public enum SessionSort: String, Sendable, CaseIterable, Identifiable {
    case recentActivity
    case title
    case messages

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .recentActivity: "Recent activity"
        case .title: "Title"
        case .messages: "Message count"
        }
    }
}

public struct SessionQuery: Sendable {
    public var agent: AgentKind?
    public var projectId: String?
    public var text: String
    public var includeSubagents: Bool
    public var sort: SessionSort
    public var limit: Int

    public init(
        agent: AgentKind? = nil,
        projectId: String? = nil,
        text: String = "",
        includeSubagents: Bool = true,
        sort: SessionSort = .recentActivity,
        limit: Int = 2_000
    ) {
        self.agent = agent
        self.projectId = projectId
        self.text = text
        self.includeSubagents = includeSubagents
        self.sort = sort
        self.limit = limit
    }
}

public struct IndexCounts: Sendable, Hashable {
    public var sessions: Int
    public var mainSessions: Int
    public var subagents: Int
    public var projects: Int
    public var sessionsByAgent: [AgentKind: Int]

    public static let empty = IndexCounts(sessions: 0, mainSessions: 0, subagents: 0, projects: 0, sessionsByAgent: [:])
}

/// Read and write access to the local index. All writes for one agent happen in one transaction,
/// so the UI never observes a half-updated agent.
public struct IndexRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Installations

    public func saveInstallations(_ installations: [AgentInstallation]) throws {
        let encoder = JSONEncoder()
        try database.writer.write { db in
            for installation in installations {
                let json = String(decoding: try encoder.encode(installation), as: UTF8.self)
                try db.execute(
                    sql: "INSERT OR REPLACE INTO installation (agent, json) VALUES (?, ?)",
                    arguments: [installation.agent.rawValue, json]
                )
            }
        }
    }

    public func installations() throws -> [AgentInstallation] {
        try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT json FROM installation ORDER BY agent").compactMap { json in
                try? JSONDecoder().decode(AgentInstallation.self, from: Data(json.utf8))
            }
        }
    }

    // MARK: - Agent index replacement

    /// Replaces everything indexed for `agent` with a fresh scan result.
    public func replaceIndex(
        agent: AgentKind,
        sessions: [SessionSummary],
        sourceStates: [SourceScanState],
        indexedAt: Date = Date()
    ) throws {
        let encoder = JSONEncoder()
        try database.writer.write { db in
            try db.execute(sql: """
                DELETE FROM session_search WHERE sessionId IN (SELECT id FROM session WHERE agent = ?)
                """, arguments: [agent.rawValue])
            try db.execute(sql: "DELETE FROM session WHERE agent = ?", arguments: [agent.rawValue])
            try db.execute(sql: "DELETE FROM source_state WHERE agent = ?", arguments: [agent.rawValue])

            for session in sessions {
                let metadata = String(decoding: try encoder.encode(session.metadata), as: UTF8.self)
                try db.execute(sql: """
                    INSERT INTO session (
                        id, agent, originalId, projectId, projectPath, parentSessionId, isSubagent, subagentType,
                        title, createdAt, updatedAt, messageCount, toolCallCount, model, sourcePath, metadataJSON, indexedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        session.id, session.agent.rawValue, session.originalId, session.projectId, session.projectPath,
                        session.parentSessionId, session.isSubagent, session.subagentType, session.title,
                        session.createdAt, session.updatedAt, session.messageCount, session.toolCallCount,
                        session.model, session.sourcePath, metadata, indexedAt,
                    ])
                try db.execute(sql: """
                    INSERT INTO session_search (sessionId, title, projectPath, body) VALUES (?, ?, ?, ?)
                    """, arguments: [session.id, session.title, session.projectPath, session.searchText])
            }

            for state in sourceStates {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO source_state (sourcePath, agent, sessionId, size, modifiedAt, headDigest, offset, stateJSON)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        state.sourcePath, agent.rawValue, state.sessionId, state.size, state.modifiedAt,
                        state.headDigest, Int64(bitPattern: state.offset), state.stateJSON,
                    ])
            }
        }
    }

    public func sourceStates(agent: AgentKind) throws -> [SourceScanState] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM source_state WHERE agent = ?", arguments: [agent.rawValue]).map { row in
                SourceScanState(
                    sourcePath: row["sourcePath"],
                    sessionId: row["sessionId"],
                    size: row["size"],
                    modifiedAt: row["modifiedAt"],
                    headDigest: row["headDigest"],
                    offset: UInt64(bitPattern: row["offset"] as Int64),
                    stateJSON: row["stateJSON"]
                )
            }
        }
    }

    // MARK: - Queries

    public func sessions(_ query: SessionQuery) throws -> [SessionSummary] {
        try database.writer.read { db in
            var clauses: [String] = []
            var arguments: [any DatabaseValueConvertible] = []

            if let agent = query.agent {
                clauses.append("agent = ?")
                arguments.append(agent.rawValue)
            }
            if let projectId = query.projectId {
                clauses.append("projectId = ?")
                arguments.append(projectId)
            }
            if !query.includeSubagents {
                clauses.append("isSubagent = 0")
            }
            if let match = Self.ftsQuery(query.text) {
                clauses.append("id IN (SELECT sessionId FROM session_search WHERE session_search MATCH ?)")
                arguments.append(match)
            }

            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let order: String
            switch query.sort {
            case .recentActivity: order = "updatedAt DESC, id"
            case .title: order = "title COLLATE NOCASE, id"
            case .messages: order = "messageCount DESC, id"
            }
            arguments.append(query.limit)

            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM session \(whereSQL) ORDER BY \(order) LIMIT ?
                """, arguments: StatementArguments(arguments))
            return rows.compactMap(Self.session(from:))
        }
    }

    public func session(id: String) throws -> SessionSummary? {
        try database.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM session WHERE id = ?", arguments: [id]).flatMap(Self.session(from:))
        }
    }

    public func children(of sessionId: String) throws -> [SessionSummary] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM session WHERE parentSessionId = ? ORDER BY createdAt, id
                """, arguments: [sessionId]).compactMap(Self.session(from:))
        }
    }

    /// Projects are derived from sessions, so they always reflect every agent's current index.
    public func projects(agent: AgentKind? = nil) throws -> [ProjectSummary] {
        try database.writer.read { db in
            let filter = agent == nil ? "" : "WHERE agent = ?"
            let arguments: StatementArguments = agent.map { [$0.rawValue] } ?? []
            let rows = try Row.fetchAll(db, sql: """
                SELECT projectId, projectPath,
                       MAX(updatedAt) AS lastActivity,
                       SUM(CASE WHEN isSubagent = 0 THEN 1 ELSE 0 END) AS mainCount,
                       SUM(CASE WHEN isSubagent = 1 THEN 1 ELSE 0 END) AS subCount,
                       MAX(json_extract(metadataJSON, '$.projectPathInferred')) AS inferred,
                       GROUP_CONCAT(DISTINCT agent) AS agents
                FROM session \(filter)
                GROUP BY projectId
                ORDER BY lastActivity DESC
                """, arguments: arguments)
            return rows.map { row in
                let path: String = row["projectPath"]
                let agentNames: String = row["agents"] ?? ""
                let agents = agentNames.split(separator: ",").compactMap { AgentKind(rawValue: String($0)) }
                return ProjectSummary(
                    id: row["projectId"],
                    agent: agents.first ?? .claudeCode,
                    path: path,
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    sessionCount: row["mainCount"] ?? 0,
                    subagentCount: row["subCount"] ?? 0,
                    lastActivityAt: row["lastActivity"],
                    pathIsInferred: (row["inferred"] as Int?) == 1,
                    agents: agents
                )
            }
        }
    }

    public func counts() throws -> IndexCounts {
        try database.writer.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session") ?? 0
            let subagents = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session WHERE isSubagent = 1") ?? 0
            let projects = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT projectId) FROM session") ?? 0
            var byAgent: [AgentKind: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT agent, COUNT(*) AS n FROM session GROUP BY agent") {
                if let agent = AgentKind(rawValue: row["agent"]) { byAgent[agent] = row["n"] }
            }
            return IndexCounts(
                sessions: total,
                mainSessions: total - subagents,
                subagents: subagents,
                projects: projects,
                sessionsByAgent: byAgent
            )
        }
    }

    /// Builds a safe FTS5 expression: each token is quoted and treated as a prefix.
    static func ftsQuery(_ text: String) -> String? {
        let tokens = text.split(whereSeparator: \.isWhitespace).map { token -> String in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }
        return tokens.isEmpty ? nil : tokens.joined(separator: " ")
    }

    private static func session(from row: Row) -> SessionSummary? {
        guard let agent = AgentKind(rawValue: row["agent"]) else { return nil }
        let metadataText: String = row["metadataJSON"]
        let metadata = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(metadataText.utf8))) ?? [:]
        var summary = SessionSummary(
            agent: agent,
            originalId: row["originalId"],
            projectId: row["projectId"],
            projectPath: row["projectPath"],
            parentSessionId: row["parentSessionId"],
            isSubagent: row["isSubagent"],
            subagentType: row["subagentType"],
            title: row["title"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"],
            messageCount: row["messageCount"],
            toolCallCount: row["toolCallCount"],
            model: row["model"],
            sourcePath: row["sourcePath"],
            metadata: metadata
        )
        summary.id = row["id"]
        return summary
    }
}
