import CryptoKit
import Foundation
import GRDB

/// Writes Claude Code sessions into OpenCode's legacy `project`, `session`, `message` and `part`
/// tables, the same tables OpenCode projects into its v2 store.
///
/// The writer is pure SwiftUI-free Swift with no external tool. Rows are built in memory first, so a
/// preview and an execution use the same mapping, and the database is touched only by `apply`, which
/// runs in a single transaction.
public struct OpenCodeLegacyWriter: Sendable {
    public static let writerVersion = "native-1"
    /// Marks sessions this writer created, so that later runs can recognise them.
    public static let versionTag = "claude-code-migrated"

    private let parser: ClaudeCodeParser

    public init(parser: ClaudeCodeParser = ClaudeCodeParser()) {
        self.parser = parser
    }

    /// Reads the complete conversation of one transcript, page by page, so that memory stays bounded
    /// by the page size plus the converted rows.
    public func readMessages(of session: SessionSummary) async throws -> (messages: [Message], issues: [SourceIssue]) {
        var messages: [Message] = []
        var issues: [SourceIssue] = []
        var offset = 0
        repeat {
            let page = try await parser.page(for: session, offset: offset, limit: 500)
            messages.append(contentsOf: page.messages)
            issues.append(contentsOf: page.issues)
            offset = page.nextOffset ?? -1
        } while offset >= 0
        return (messages, issues)
    }

    // MARK: - Mapping (pure)

    /// One Claude Code session to be written, with the OpenCode parent it links to, if any.
    public struct Input: Sendable {
        public var session: SessionSummary
        public var messages: [Message]
        public var parentOpenCodeId: String?

        public init(session: SessionSummary, messages: [Message], parentOpenCodeId: String?) {
            self.session = session
            self.messages = messages
            self.parentOpenCodeId = parentOpenCodeId
        }
    }

    /// Builds every row for the inputs. `existingProjectIds` prevents a second insert of a known project.
    public static func rows(for inputs: [Input], existingProjectIds: Set<String>) -> LegacyRows {
        var rows = LegacyRows()
        var knownProjects = existingProjectIds
        for input in inputs {
            let session = input.session
            let origin = session.originalId
            let openCodeId = identifier(prefix: "ses", seed: "session:\(origin)")
            let projectId = projectIdentifier(worktree: session.projectPath)
            let created = millis(session.createdAt)
            let updated = max(millis(session.updatedAt), created)

            if !knownProjects.contains(projectId) {
                knownProjects.insert(projectId)
                rows.projects.append(LegacyProjectRow(
                    id: projectId,
                    worktree: session.projectPath,
                    name: URL(fileURLWithPath: session.projectPath).lastPathComponent,
                    timeCreated: created,
                    timeUpdated: updated
                ))
            }

            var metadata: [String: JSONValue] = [
                "claude_code_origin": .string(origin),
                "is_subagent": .bool(session.isSubagent),
            ]
            if let parent = session.parentSessionId {
                metadata["claude_code_parent"] = .string(originIdentifier(parent))
            }
            rows.sessions.append(LegacySessionRow(
                id: openCodeId,
                projectId: projectId,
                parentId: input.parentOpenCodeId,
                slug: slug(for: session),
                directory: session.projectPath,
                title: session.title,
                version: versionTag,
                metadata: JSONValue.object(metadata).compactText,
                timeCreated: created,
                timeUpdated: updated
            ))

            var stats = MappingState()
            var built: [BuiltMessage] = []
            var lastUserId: String?
            var pendingResults: [String: ToolOutcome] = [:]

            for (ordinal, message) in input.messages.enumerated() {
                let messageTime = millis(message.timestamp) == 0 ? created : millis(message.timestamp)
                let recordId = recordIdentity(message, fallback: "\(origin):\(ordinal)")
                switch message.role {
                case .user:
                    var texts: [String] = []
                    for part in message.contentParts {
                        switch part {
                        case .text(let text):
                            texts.append(text)
                        case .toolResult(let result):
                            if let callId = result.callId {
                                pendingResults[callId] = ToolOutcome(output: result.output, isError: result.isError)
                            }
                        case .fileReference:
                            stats.skip("file reference")
                        case .toolCall, .reasoning:
                            stats.skip("unexpected part in user record")
                        case .unknown(let kind, _):
                            stats.skip(kind)
                        }
                    }
                    guard !texts.isEmpty else { continue }
                    let id = identifier(prefix: "msg", seed: "message:\(origin):\(ordinal)")
                    built.append(BuiltMessage(
                        id: id,
                        role: .user,
                        created: messageTime,
                        recordId: recordId,
                        parentId: nil,
                        model: nil,
                        tokens: nil,
                        parts: texts.enumerated().map { index, text in
                            PartDraft.text(id: identifier(prefix: "prt", seed: "part:\(origin):\(ordinal):\(index)"), text: text)
                        }
                    ))
                    lastUserId = id

                case .assistant:
                    let id = identifier(prefix: "msg", seed: "message:\(origin):\(ordinal)")
                    var parts: [PartDraft] = []
                    for part in message.contentParts {
                        switch part {
                        case .text(let text):
                            parts.append(.text(id: "", text: text))
                        case .reasoning(let text):
                            parts.append(.reasoning(id: "", text: text))
                        case .toolCall(let call):
                            parts.append(.tool(id: "", callId: call.id ?? "call-\(ordinal)-\(parts.count)", name: call.name, input: call.input, outcome: nil))
                        case .toolResult(let result):
                            if let callId = result.callId {
                                pendingResults[callId] = ToolOutcome(output: result.output, isError: result.isError)
                            }
                        case .fileReference:
                            stats.skip("file reference")
                        case .unknown(let kind, _):
                            stats.skip(kind)
                        }
                    }
                    built.append(BuiltMessage(
                        id: id,
                        role: .assistant,
                        created: messageTime,
                        recordId: recordId,
                        parentId: lastUserId,
                        model: message.model,
                        tokens: tokenUsage(message),
                        parts: parts.enumerated().map { index, draft in
                            draft.withId(identifier(prefix: "prt", seed: "part:\(origin):\(ordinal):\(index)"))
                        }
                    ))

                case .system, .tool, .unknown:
                    stats.skip("\(message.role.rawValue) message")
                }
            }

            // Results arrive in later user records. Attach each one to the call it answers.
            for index in built.indices {
                for partIndex in built[index].parts.indices {
                    guard case .tool(let id, let callId, let name, let input, let existing) = built[index].parts[partIndex],
                          existing == nil else { continue }
                    let outcome = pendingResults[callId] ?? ToolOutcome(output: "", isError: false)
                    built[index].parts[partIndex] = .tool(id: id, callId: callId, name: name, input: input, outcome: outcome)
                    stats.toolCalls += 1
                }
            }

            for message in built {
                let createdAt = message.created
                rows.messages.append(LegacyMessageRow(
                    id: message.id,
                    sessionId: openCodeId,
                    timeCreated: createdAt,
                    data: messageData(message)
                ))
                let parts = message.role == .assistant
                    ? [PartDraft.stepStart(id: identifier(prefix: "prt", seed: "step-start:\(message.id)"))]
                        + message.parts
                        + [PartDraft.stepFinish(id: identifier(prefix: "prt", seed: "step-finish:\(message.id)"), tokens: message.tokens, time: createdAt)]
                    : message.parts
                for part in parts {
                    rows.parts.append(LegacyPartRow(
                        id: part.id,
                        messageId: message.id,
                        sessionId: openCodeId,
                        timeCreated: createdAt,
                        data: part.data(at: createdAt)
                    ))
                }
                rows.counts.messages += 1
                if message.role == .user { rows.counts.userMessages += 1 }
            }
            rows.counts.sessions += 1
            rows.counts.toolCalls += stats.toolCalls
            for (reason, count) in stats.skipped {
                rows.skipped[reason, default: 0] += count
            }
        }
        rows.counts.projects = rows.projects.count
        rows.counts.parts = rows.parts.count
        return rows
    }

    // MARK: - Apply

    /// Writes all rows in one transaction. If any insert fails, nothing is written.
    public static func apply(_ rows: LegacyRows, to destination: URL) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.label = "opencode-legacy-writer"
        let queue = try DatabaseQueue(path: destination.path, configuration: configuration)
        try queue.write { db in
            for project in rows.projects {
                try db.execute(sql: """
                    INSERT INTO project (id, worktree, name, time_created, time_updated, sandboxes)
                    VALUES (?, ?, ?, ?, ?, '[]')
                    """, arguments: [project.id, project.worktree, project.name, project.timeCreated, project.timeUpdated])
            }
            for session in rows.sessions {
                try db.execute(sql: """
                    INSERT INTO session (id, project_id, parent_id, slug, directory, path, title, version, metadata, agent, time_created, time_updated)
                    VALUES (?, ?, ?, ?, ?, '', ?, ?, ?, 'build', ?, ?)
                    """, arguments: [
                        session.id, session.projectId, session.parentId, session.slug, session.directory,
                        session.title, session.version, session.metadata, session.timeCreated, session.timeUpdated,
                    ])
            }
            for message in rows.messages {
                try db.execute(sql: """
                    INSERT INTO message (id, session_id, time_created, time_updated, data)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [message.id, message.sessionId, message.timeCreated, message.timeCreated, message.data])
            }
            for part in rows.parts {
                try db.execute(sql: """
                    INSERT INTO part (id, message_id, session_id, time_created, time_updated, data)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [part.id, part.messageId, part.sessionId, part.timeCreated, part.timeCreated, part.data])
            }
        }
    }

    /// Checks that the destination has the legacy tables this writer needs.
    public static func writerStatus(store: OpenCodeStore) throws -> WriterStatus {
        let profile = try store.profile()
        let required = ["project", "session", "message", "part"]
        let missing = required.filter { !profile.has(table: $0) }
        if missing.isEmpty {
            return WriterStatus(isReady: true, detail: "Legacy tables present (\(profile.summary)).", writerVersion: writerVersion)
        }
        return WriterStatus(isReady: false, detail: "Missing tables: \(missing.joined(separator: ", ")).", writerVersion: writerVersion)
    }

    // MARK: - Identifiers

    /// `ses_`, `msg_` and `prt_` identifiers in the format OpenCode uses: a prefix and 26 alphanumerics.
    /// They are derived from the source identity, so the same transcript always maps to the same ids.
    public static func identifier(prefix: String, seed: String) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        let body = (0..<26).map { alphabet[Int(digest[$0 % digest.count]) % alphabet.count] }
        return "\(prefix)_\(String(body))"
    }

    /// OpenCode project ids are the SHA-1 of the worktree path, as hex.
    public static func projectIdentifier(worktree: String) -> String {
        Insecure.SHA1.hash(data: Data(worktree.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The bare origin id from a SessionDock composite id (`claude-code:<scope>/<uuid>`).
    public static func originIdentifier(_ compositeId: String) -> String {
        if let slash = compositeId.lastIndex(of: "/") {
            return String(compositeId[compositeId.index(after: slash)...])
        }
        return compositeId
    }

    // MARK: - Helpers

    private static func millis(_ date: Date?) -> Int64 {
        guard let date else { return 0 }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func recordIdentity(_ message: Message, fallback: String) -> String {
        if case .array(let ids)? = message.metadata["recordIds"], let first = ids.first?.stringValue {
            return first
        }
        return fallback
    }

    private static func tokenUsage(_ message: Message) -> TokenUsage? {
        guard let usage = message.metadata["usage"] else { return nil }
        return TokenUsage(
            input: Int(usage["input_tokens"]?.numberValue ?? 0),
            output: Int(usage["output_tokens"]?.numberValue ?? 0),
            cacheRead: Int(usage["cache_read_input_tokens"]?.numberValue ?? 0),
            cacheWrite: Int(usage["cache_creation_input_tokens"]?.numberValue ?? 0)
        )
    }

    private static func slug(for session: SessionSummary) -> String {
        let hash = Sha256Hex.digest(of: session.id).prefix(8)
        let words = session.title.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .prefix(6)
            .joined(separator: "-")
        return "\(hash)-\(String(words.prefix(30)))"
    }

    private static func messageData(_ message: BuiltMessage) -> String {
        var object: [String: JSONValue] = [
            "agent": .string("build"),
            "ccOriginID": .string(message.recordId),
        ]
        switch message.role {
        case .user:
            object["role"] = .string("user")
            object["model"] = .object(["modelID": .string(""), "providerID": .string(""), "variant": .string("thinking")])
            object["summary"] = .object(["diffs": .array([])])
            object["time"] = .object(["created": .number(Double(message.created))])
        default:
            let model = message.model ?? ""
            let provider = model.hasPrefix("claude") ? "anthropic" : ""
            object["role"] = .string("assistant")
            object["mode"] = .string("build")
            object["cost"] = .number(0)
            object["modelID"] = .string(model)
            object["providerID"] = .string(provider)
            object["path"] = .object(["cwd": .string(""), "root": .string("/")])
            object["serviceTier"] = .string("standard")
            object["speed"] = .string("standard")
            object["variant"] = .string("thinking")
            object["time"] = .object(["created": .number(Double(message.created))])
            let tokens = message.tokens ?? TokenUsage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
            object["tokens"] = .object([
                "input": .number(Double(tokens.input)),
                "output": .number(Double(tokens.output)),
                "reasoning": .number(0),
                "cache": .object(["read": .number(Double(tokens.cacheRead)), "write": .number(Double(tokens.cacheWrite))]),
            ])
            if let parent = message.parentId {
                object["parentID"] = .string(parent)
            }
        }
        return JSONValue.object(object).compactText
    }

    struct ToolOutcome {
        var output: String
        var isError: Bool
    }

    struct TokenUsage {
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
    }

    struct BuiltMessage {
        var id: String
        var role: MessageRole
        var created: Int64
        var recordId: String
        var parentId: String?
        var model: String?
        var tokens: TokenUsage?
        var parts: [PartDraft]
    }

    private struct MappingState {
        var skipped: [String: Int] = [:]
        var toolCalls = 0

        mutating func skip(_ reason: String) {
            skipped[reason, default: 0] += 1
        }
    }
}

/// A part before it is serialised. Tool parts carry their result once it is known.
enum PartDraft: Sendable {
    case text(id: String, text: String)
    case reasoning(id: String, text: String)
    case tool(id: String, callId: String, name: String, input: JSONValue, outcome: OpenCodeLegacyWriter.ToolOutcome?)
    case stepStart(id: String)
    case stepFinish(id: String, tokens: OpenCodeLegacyWriter.TokenUsage?, time: Int64)

    var id: String {
        switch self {
        case .text(let id, _), .reasoning(let id, _), .tool(let id, _, _, _, _), .stepStart(let id), .stepFinish(let id, _, _):
            id
        }
    }

    func withId(_ newId: String) -> PartDraft {
        switch self {
        case .text(_, let text): .text(id: newId, text: text)
        case .reasoning(_, let text): .reasoning(id: newId, text: text)
        case .tool(_, let callId, let name, let input, let outcome): .tool(id: newId, callId: callId, name: name, input: input, outcome: outcome)
        case .stepStart: .stepStart(id: newId)
        case .stepFinish(_, let tokens, let time): .stepFinish(id: newId, tokens: tokens, time: time)
        }
    }

    /// The JSON stored in `part.data`. Renderer requirements are satisfied here: step parts carry their
    /// native fields, step-start has a time, and every tool state has a time block.
    func data(at time: Int64) -> String {
        let object: JSONValue
        switch self {
        case .text(_, let text):
            object = .object(["type": .string("text"), "text": .string(text)])
        case .reasoning(_, let text):
            object = .object(["type": .string("reasoning"), "text": .string(text)])
        case .tool(_, let callId, let name, let input, let outcome):
            let status = outcome.map { $0.isError ? "error" : "completed" } ?? "completed"
            object = .object([
                "type": .string("tool"),
                "tool": .string(name),
                "callID": .string(callId),
                "state": .object([
                    "status": .string(status),
                    "input": input,
                    "output": .string(outcome?.output ?? ""),
                    "title": .string(name),
                    "time": .object(["compacted": .bool(false)]),
                ]),
            ])
        case .stepStart:
            object = .object([
                "type": .string("step-start"),
                "snapshot": .string(""),
                "time": .object(["created": .number(Double(time)), "completed": .number(Double(time))]),
            ])
        case .stepFinish(_, let tokens, _):
            let usage = tokens ?? OpenCodeLegacyWriter.TokenUsage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
            object = .object([
                "type": .string("step-finish"),
                "reason": .string("stop"),
                "snapshot": .string(""),
                "cost": .number(0),
                "files": .object([:]),
                "hash": .object([:]),
                "metadata": .object([:]),
                "time": .object(["created": .number(Double(time)), "completed": .number(Double(time))]),
                "tokens": .object([
                    "total": .number(Double(usage.input + usage.output)),
                    "input": .number(Double(usage.input)),
                    "output": .number(Double(usage.output)),
                    "reasoning": .number(0),
                    "cache": .object(["read": .number(Double(usage.cacheRead)), "write": .number(Double(usage.cacheWrite))]),
                ]),
            ])
        }
        return object.compactText
    }
}

/// Rows ready to insert, plus the counts shown in the preview.
public struct LegacyRows: Sendable {
    public var projects: [LegacyProjectRow] = []
    public var sessions: [LegacySessionRow] = []
    public var messages: [LegacyMessageRow] = []
    public var parts: [LegacyPartRow] = []
    public var counts = LegacyCounts()
    /// Source records that have no OpenCode equivalent. They are reported, never silently dropped.
    public var skipped: [String: Int] = [:]

    public init() {}
}

public struct LegacyCounts: Codable, Sendable, Hashable {
    public var projects = 0
    public var sessions = 0
    public var messages = 0
    public var userMessages = 0
    public var parts = 0
    public var toolCalls = 0

    public init() {}
}

public struct LegacyProjectRow: Sendable {
    public var id: String
    public var worktree: String
    public var name: String
    public var timeCreated: Int64
    public var timeUpdated: Int64
}

public struct LegacySessionRow: Sendable {
    public var id: String
    public var projectId: String
    public var parentId: String?
    public var slug: String
    public var directory: String
    public var title: String
    public var version: String
    public var metadata: String
    public var timeCreated: Int64
    public var timeUpdated: Int64
}

public struct LegacyMessageRow: Sendable {
    public var id: String
    public var sessionId: String
    public var timeCreated: Int64
    public var data: String
}

public struct LegacyPartRow: Sendable {
    public var id: String
    public var messageId: String
    public var sessionId: String
    public var timeCreated: Int64
    public var data: String
}

public struct WriterStatus: Sendable, Hashable {
    public var isReady: Bool
    public var detail: String
    public var writerVersion: String
}
