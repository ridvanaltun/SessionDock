import Foundation

/// User-supplied locations that override discovery. `nil` means "use discovery".
public struct PathOverrides: Codable, Hashable, Sendable {
    public var claudeCodeRoot: String?
    public var openCodeDatabase: String?

    public init(claudeCodeRoot: String? = nil, openCodeDatabase: String? = nil) {
        self.claudeCodeRoot = claudeCodeRoot
        self.openCodeDatabase = openCodeDatabase
    }
}

/// Resumable per-source-file scan state. Persisted so that unchanged or appended files are
/// not re-read on the next refresh.
public struct SourceScanState: Codable, Hashable, Sendable {
    public var sourcePath: String
    public var sessionId: String
    public var size: Int64
    public var modifiedAt: Date
    public var headDigest: String
    public var offset: UInt64
    /// Adapter-specific reduction state, encoded as JSON.
    public var stateJSON: String

    public init(
        sourcePath: String,
        sessionId: String,
        size: Int64,
        modifiedAt: Date,
        headDigest: String,
        offset: UInt64,
        stateJSON: String
    ) {
        self.sourcePath = sourcePath
        self.sessionId = sessionId
        self.size = size
        self.modifiedAt = modifiedAt
        self.headDigest = headDigest
        self.offset = offset
        self.stateJSON = stateJSON
    }
}

public struct ScanOutcome: Sendable {
    public var sessions: [SessionSummary]
    public var projects: [ProjectSummary]
    public var sourceStates: [SourceScanState]
    public var issues: [SourceIssue]
    public var filesScanned: Int
    public var filesReused: Int

    public init(
        sessions: [SessionSummary] = [],
        projects: [ProjectSummary] = [],
        sourceStates: [SourceScanState] = [],
        issues: [SourceIssue] = [],
        filesScanned: Int = 0,
        filesReused: Int = 0
    ) {
        self.sessions = sessions
        self.projects = projects
        self.sourceStates = sourceStates
        self.issues = issues
        self.filesScanned = filesScanned
        self.filesReused = filesReused
    }
}

public struct ScanProgress: Sendable, Hashable {
    public var completed: Int
    public var total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    public var fraction: Double {
        total == 0 ? 1 : Double(completed) / Double(total)
    }
}

/// Discovers sessions and projects in an installation's native store.
public protocol SessionScanner: Sendable {
    func scan(
        installation: AgentInstallation,
        previousStates: [SourceScanState],
        progress: (@Sendable (ScanProgress) -> Void)?
    ) async throws -> ScanOutcome
}

public extension SessionScanner {
    func scan(installation: AgentInstallation, previousStates: [SourceScanState]) async throws -> ScanOutcome {
        try await scan(installation: installation, previousStates: previousStates, progress: nil)
    }
}

/// Loads a bounded page of conversation messages for one session.
public protocol SessionParser: Sendable {
    func page(for session: SessionSummary, offset: Int, limit: Int) async throws -> MessagePage
}

/// Read-only access to the native store, used to prove that originals were not modified.
public protocol SessionStorage: Sendable {
    /// Content fingerprint of the file that holds the session, or `nil` when the session
    /// lives inside a shared database (fingerprint the database instead).
    func fingerprint(for session: SessionSummary) throws -> FileFingerprint?
}

/// One supported agent: discovery plus read-only access to its sessions.
public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    var scanner: any SessionScanner { get }
    var parser: any SessionParser { get }
    var storage: any SessionStorage { get }

    func discover(overrides: PathOverrides) async -> AgentInstallation
}
