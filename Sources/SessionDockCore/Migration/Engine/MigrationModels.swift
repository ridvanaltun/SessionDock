import Foundation

/// The user's choice. Ids are composite source ids (`claude-code:<uuid>`).
public struct MigrationSelection: Codable, Hashable, Sendable {
    public var sourceAgent: AgentKind
    public var targetAgent: AgentKind
    public var selectedSessionIds: [String]

    public init(sourceAgent: AgentKind = .claudeCode, targetAgent: AgentKind = .openCode, selectedSessionIds: [String]) {
        self.sourceAgent = sourceAgent
        self.targetAgent = targetAgent
        self.selectedSessionIds = selectedSessionIds
    }
}

public struct PlannedSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var originId: String
    public var title: String
    public var projectPath: String
    public var isSubagent: Bool
    public var parentSourceId: String?
    /// Why the session is in the plan: chosen directly, or pulled in as a subagent or parent.
    public var inclusionReason: InclusionReason
    public var expectedMessageCount: Int
    public var expectedUserPromptCount: Int
    public var expectedToolCallCount: Int
    public var sourcePath: String

    public init(
        id: String,
        originId: String,
        title: String,
        projectPath: String,
        isSubagent: Bool,
        parentSourceId: String?,
        inclusionReason: InclusionReason,
        expectedMessageCount: Int,
        expectedUserPromptCount: Int,
        expectedToolCallCount: Int,
        sourcePath: String
    ) {
        self.expectedUserPromptCount = expectedUserPromptCount
        self.id = id
        self.originId = originId
        self.title = title
        self.projectPath = projectPath
        self.isSubagent = isSubagent
        self.parentSourceId = parentSourceId
        self.inclusionReason = inclusionReason
        self.expectedMessageCount = expectedMessageCount
        self.expectedToolCallCount = expectedToolCallCount
        self.sourcePath = sourcePath
    }
}

public enum InclusionReason: String, Codable, Sendable, Hashable {
    case selected
    case subagentOfSelected
    case requiredParent
}

public struct AlreadyMigratedSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var originId: String
    public var title: String
    public var targetSessionId: String
    public var sourceMessageCount: Int
    public var targetMessageCount: Int

    public init(
        id: String,
        originId: String,
        title: String,
        targetSessionId: String,
        sourceMessageCount: Int,
        targetMessageCount: Int
    ) {
        self.id = id
        self.originId = originId
        self.title = title
        self.targetSessionId = targetSessionId
        self.sourceMessageCount = sourceMessageCount
        self.targetMessageCount = targetMessageCount
    }

    /// The source has more messages than the copy in OpenCode. Existing copies are never updated.
    public var sourceIsNewer: Bool { sourceMessageCount > targetMessageCount }
}

public enum PlanIssueSeverity: String, Codable, Sendable, Hashable {
    case info
    case warning
    case blocker
}

public struct PlanIssue: Codable, Hashable, Sendable, Identifiable {
    public var id: String { code }
    public var severity: PlanIssueSeverity
    public var code: String
    public var message: String

    public init(severity: PlanIssueSeverity, code: String, message: String) {
        self.severity = severity
        self.code = code
        self.message = message
    }
}

public struct MigrationPlan: Codable, Identifiable, Sendable {
    public var id: String
    public var createdAt: Date
    public var selection: MigrationSelection
    public var sessionsToMigrate: [PlannedSession]
    public var alreadyMigrated: [AlreadyMigratedSession]
    public var issues: [PlanIssue]
    public var sourceRoot: String
    public var destinationDatabase: String
    /// Fingerprint of the destination rows at planning time. Execution refuses a plan whose
    /// destination has changed since.
    public var destinationSignature: String
    public var sourceFingerprints: [String: FileFingerprint]
    /// Rows that will be written, counted from the in-memory mapping.
    public var expected: LegacyCounts
    /// Source records with no OpenCode equivalent, by kind.
    public var skipped: [String: Int]

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        selection: MigrationSelection,
        sessionsToMigrate: [PlannedSession],
        alreadyMigrated: [AlreadyMigratedSession],
        issues: [PlanIssue],
        sourceRoot: String,
        destinationDatabase: String,
        destinationSignature: String,
        sourceFingerprints: [String: FileFingerprint],
        expected: LegacyCounts,
        skipped: [String: Int]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.selection = selection
        self.sessionsToMigrate = sessionsToMigrate
        self.alreadyMigrated = alreadyMigrated
        self.issues = issues
        self.sourceRoot = sourceRoot
        self.destinationDatabase = destinationDatabase
        self.destinationSignature = destinationSignature
        self.sourceFingerprints = sourceFingerprints
        self.expected = expected
        self.skipped = skipped
    }

    public var canExecute: Bool {
        !sessionsToMigrate.isEmpty && !issues.contains { $0.severity == .blocker }
    }
}

public enum MigrationJobStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case backingUp
    case migrating
    case verifying
    case succeeded
    case succeededWithWarnings
    case failed
    case failedVerification
    case restored

    public var isTerminal: Bool {
        switch self {
        case .backingUp, .migrating, .verifying: false
        default: true
        }
    }

    public var label: String {
        switch self {
        case .backingUp: "Backing up"
        case .migrating: "Migrating"
        case .verifying: "Verifying"
        case .succeeded: "Succeeded"
        case .succeededWithWarnings: "Succeeded with warnings"
        case .failed: "Failed"
        case .failedVerification: "Failed verification"
        case .restored: "Restored from backup"
        }
    }
}

public enum ValidationSeverity: String, Codable, Sendable, Hashable {
    case error
    case warning
    case info
}

public struct MigrationValidationResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var jobId: String
    public var check: String
    public var severity: ValidationSeverity
    public var passed: Bool
    public var detail: String

    public init(id: String = UUID().uuidString, jobId: String, check: String, severity: ValidationSeverity, passed: Bool, detail: String) {
        self.id = id
        self.jobId = jobId
        self.check = check
        self.severity = severity
        self.passed = passed
        self.detail = detail
    }
}

public enum MappingStatus: String, Codable, Sendable, Hashable {
    case verified
    case unverified
    case failed
}

public struct SessionMapping: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var jobId: String
    public var sourceAgent: AgentKind
    public var sourceSessionId: String
    public var targetAgent: AgentKind
    public var targetSessionId: String?
    public var status: MappingStatus
    public var verifiedAt: Date?

    public init(
        id: String = UUID().uuidString,
        jobId: String,
        sourceAgent: AgentKind,
        sourceSessionId: String,
        targetAgent: AgentKind,
        targetSessionId: String?,
        status: MappingStatus,
        verifiedAt: Date? = nil
    ) {
        self.id = id
        self.jobId = jobId
        self.sourceAgent = sourceAgent
        self.sourceSessionId = sourceSessionId
        self.targetAgent = targetAgent
        self.targetSessionId = targetSessionId
        self.status = status
        self.verifiedAt = verifiedAt
    }
}

public struct BackupRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var originalPath: String
    public var backupPath: String
    public var sizeBytes: Int64
    public var sha256: String
    public var integrityResult: String
    public var sessionCount: Int
    public var messageCount: Int
    public var jobId: String?
    public var restoredAt: Date?

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        originalPath: String,
        backupPath: String,
        sizeBytes: Int64,
        sha256: String,
        integrityResult: String,
        sessionCount: Int,
        messageCount: Int,
        jobId: String? = nil,
        restoredAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.originalPath = originalPath
        self.backupPath = backupPath
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.integrityResult = integrityResult
        self.sessionCount = sessionCount
        self.messageCount = messageCount
        self.jobId = jobId
        self.restoredAt = restoredAt
    }
}

public struct MigrationJob: Codable, Identifiable, Sendable {
    public var id: String
    public var createdAt: Date
    public var finishedAt: Date?
    public var status: MigrationJobStatus
    public var selection: MigrationSelection
    public var planId: String
    public var sessionCount: Int
    public var writerVersion: String?
    public var operation: String
    public var stdoutExcerpt: String
    public var stderrExcerpt: String
    public var backupId: String?
    public var summary: String

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        finishedAt: Date? = nil,
        status: MigrationJobStatus,
        selection: MigrationSelection,
        planId: String,
        sessionCount: Int,
        writerVersion: String?,
        operation: String,
        stdoutExcerpt: String,
        stderrExcerpt: String,
        backupId: String?,
        summary: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.status = status
        self.selection = selection
        self.planId = planId
        self.sessionCount = sessionCount
        self.writerVersion = writerVersion
        self.operation = operation
        self.stdoutExcerpt = stdoutExcerpt
        self.stderrExcerpt = stderrExcerpt
        self.backupId = backupId
        self.summary = summary
    }
}

/// The result of an execution, returned to the UI and persisted as a job.
public struct MigrationReport: Sendable {
    public var job: MigrationJob
    public var mappings: [SessionMapping]
    public var validations: [MigrationValidationResult]
    public var backup: BackupRecord?

    public init(job: MigrationJob, mappings: [SessionMapping], validations: [MigrationValidationResult], backup: BackupRecord?) {
        self.job = job
        self.mappings = mappings
        self.validations = validations
        self.backup = backup
    }
}

public enum MigrationError: LocalizedError {
    case planStale(String)
    case planBlocked([String])
    case backupFailed(String)
    case backupNotFound
    case openCodeRunning([String])
    case restoreRefused(String)
    case destinationMissing(String)

    public var errorDescription: String? {
        switch self {
        case .planStale(let detail): "The plan is out of date. \(detail) Plan again before running."
        case .planBlocked(let reasons): "The migration is blocked: " + reasons.joined(separator: " ")
        case .backupFailed(let detail): "Backup failed; nothing was written. \(detail)"
        case .backupNotFound: "The backup file is missing."
        case .openCodeRunning(let processes): "OpenCode appears to be running (\(processes.joined(separator: ", "))). Close it before restoring a backup."
        case .restoreRefused(let detail): "Restore refused. \(detail)"
        case .destinationMissing(let path): "The OpenCode database was not found at \(path)."
        }
    }
}
