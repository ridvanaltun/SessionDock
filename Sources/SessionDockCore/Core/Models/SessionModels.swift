import Foundation

/// Normalised, agent-independent session record. `id` is `<agent>:<originalId>`, which
/// is globally unique and keeps the original id intact for mapping and display.
public struct SessionSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var agent: AgentKind
    public var originalId: String
    public var projectId: String
    public var projectPath: String
    public var parentSessionId: String?
    public var isSubagent: Bool
    public var subagentType: String?
    public var title: String
    public var createdAt: Date?
    public var updatedAt: Date?
    public var messageCount: Int
    public var toolCallCount: Int
    public var model: String?
    public var sourcePath: String?
    /// Source-specific fields that do not have a first-class property. Never discarded.
    public var metadata: [String: JSONValue]
    /// Capped excerpt of conversation text, used only to build the search index.
    public var searchText: String

    public init(
        agent: AgentKind,
        originalId: String,
        projectId: String,
        projectPath: String,
        parentSessionId: String? = nil,
        isSubagent: Bool = false,
        subagentType: String? = nil,
        title: String,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        messageCount: Int = 0,
        toolCallCount: Int = 0,
        model: String? = nil,
        sourcePath: String? = nil,
        metadata: [String: JSONValue] = [:],
        searchText: String = ""
    ) {
        self.searchText = searchText
        self.id = Self.compositeID(agent: agent, originalId: originalId)
        self.agent = agent
        self.originalId = originalId
        self.projectId = projectId
        self.projectPath = projectPath
        self.parentSessionId = parentSessionId
        self.isSubagent = isSubagent
        self.subagentType = subagentType
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.toolCallCount = toolCallCount
        self.model = model
        self.sourcePath = sourcePath
        self.metadata = metadata
    }

    public static func compositeID(agent: AgentKind, originalId: String) -> String {
        "\(agent.rawValue):\(originalId)"
    }
}

public enum MessageRole: String, Codable, Sendable, Hashable {
    case user
    case assistant
    case system
    case tool
    case unknown
}

public struct Message: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sessionId: String
    public var ordinal: Int
    public var role: MessageRole
    public var timestamp: Date?
    public var model: String?
    public var contentParts: [ContentPart]
    public var metadata: [String: JSONValue]

    public init(
        id: String,
        sessionId: String,
        ordinal: Int,
        role: MessageRole,
        timestamp: Date? = nil,
        model: String? = nil,
        contentParts: [ContentPart],
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.sessionId = sessionId
        self.ordinal = ordinal
        self.role = role
        self.timestamp = timestamp
        self.model = model
        self.contentParts = contentParts
        self.metadata = metadata
    }
}

public enum ContentPart: Codable, Hashable, Sendable {
    case text(String)
    case reasoning(String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case fileReference(FileReference)
    case unknown(kind: String, raw: JSONValue)
}

public struct ToolCall: Codable, Hashable, Sendable {
    public var id: String?
    public var name: String
    public var input: JSONValue
    public var status: String?

    public init(id: String?, name: String, input: JSONValue, status: String? = nil) {
        self.id = id
        self.name = name
        self.input = input
        self.status = status
    }
}

public struct ToolResult: Codable, Hashable, Sendable {
    public var callId: String?
    public var output: String
    public var isError: Bool
    public var raw: JSONValue?

    public init(callId: String?, output: String, isError: Bool, raw: JSONValue? = nil) {
        self.callId = callId
        self.output = output
        self.isError = isError
        self.raw = raw
    }
}

public struct FileReference: Codable, Hashable, Sendable {
    public var path: String
    public var kind: String?

    public init(path: String, kind: String? = nil) {
        self.path = path
        self.kind = kind
    }
}

/// A problem found while reading a source. Problems are surfaced, never silently skipped.
public struct SourceIssue: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(byteOffset ?? 0):\(kind)" }
    public var kind: String
    public var detail: String
    public var byteOffset: UInt64?
    public var rawPreview: String?

    public init(kind: String, detail: String, byteOffset: UInt64? = nil, rawPreview: String? = nil) {
        self.kind = kind
        self.detail = detail
        self.byteOffset = byteOffset
        self.rawPreview = rawPreview
    }
}

public struct MessagePage: Sendable {
    public var messages: [Message]
    /// Offset to pass for the next page, or nil when the end was reached.
    public var nextOffset: Int?
    public var issues: [SourceIssue]

    public init(messages: [Message], nextOffset: Int?, issues: [SourceIssue] = []) {
        self.messages = messages
        self.nextOffset = nextOffset
        self.issues = issues
    }
}
