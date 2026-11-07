import Foundation

/// Identifies a supported coding agent. New agents are added as cases plus an adapter;
/// nothing outside `Agents/` may switch on agent-specific storage details.
public enum AgentKind: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case claudeCode = "claude-code"
    case openCode = "opencode"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .openCode: "OpenCode"
        }
    }
}

public enum InstallationStatus: Codable, Hashable, Sendable {
    case available
    case notFound
    case unreadable(String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .available: "Available"
        case .notFound: "Not found"
        case .unreadable: "Unreadable"
        }
    }
}

/// Where an installation's data was found and how that location was chosen.
public enum LocationSource: String, Codable, Sendable, Hashable {
    case defaultLocation = "default"
    case environment = "environment"
    case override = "override"
}

public struct AgentInstallation: Codable, Hashable, Sendable, Identifiable {
    public var id: AgentKind { agent }
    public var agent: AgentKind
    /// Root directory of the agent's data (`~/.claude`, the OpenCode data directory).
    public var rootPath: String?
    /// The concrete store the adapter reads: the `projects/` directory or `opencode.db`.
    public var storePath: String?
    public var status: InstallationStatus
    public var detail: String
    public var version: String?
    public var schemaSummary: String?
    public var sessionCount: Int
    public var projectCount: Int
    public var locationSource: LocationSource
    public var scannedAt: Date?

    public init(
        agent: AgentKind,
        rootPath: String? = nil,
        storePath: String? = nil,
        status: InstallationStatus = .notFound,
        detail: String = "",
        version: String? = nil,
        schemaSummary: String? = nil,
        sessionCount: Int = 0,
        projectCount: Int = 0,
        locationSource: LocationSource = .defaultLocation,
        scannedAt: Date? = nil
    ) {
        self.agent = agent
        self.rootPath = rootPath
        self.storePath = storePath
        self.status = status
        self.detail = detail
        self.version = version
        self.schemaSummary = schemaSummary
        self.sessionCount = sessionCount
        self.projectCount = projectCount
        self.locationSource = locationSource
        self.scannedAt = scannedAt
    }
}

public struct ProjectSummary: Codable, Hashable, Sendable, Identifiable {
    /// Stable id: `<agent>:<sha256(path)[0..<16]>`.
    public var id: String
    public var agent: AgentKind
    public var path: String
    public var name: String
    public var sessionCount: Int
    public var subagentCount: Int
    public var lastActivityAt: Date?
    /// True when the path was reconstructed from a directory name instead of recorded data.
    public var pathIsInferred: Bool
    /// Every agent that has sessions in this directory.
    public var agents: [AgentKind]

    public init(
        id: String,
        agent: AgentKind,
        path: String,
        name: String,
        sessionCount: Int = 0,
        subagentCount: Int = 0,
        lastActivityAt: Date? = nil,
        pathIsInferred: Bool = false,
        agents: [AgentKind]? = nil
    ) {
        self.id = id
        self.agent = agent
        self.path = path
        self.name = name
        self.sessionCount = sessionCount
        self.subagentCount = subagentCount
        self.lastActivityAt = lastActivityAt
        self.pathIsInferred = pathIsInferred
        self.agents = agents ?? [agent]
    }
}
