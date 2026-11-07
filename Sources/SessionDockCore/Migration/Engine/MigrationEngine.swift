import Foundation

/// Orchestrates Claude Code → OpenCode migrations: plan, back up, write, verify, record.
///
/// Safety rules enforced here, not in the UI:
/// 1. Planning never writes. It reads the transcripts and the destination and builds the rows in memory.
/// 2. Execution refuses a plan whose destination or source files changed after planning.
/// 3. A verified backup is created before any write.
/// 4. Success is decided by `MigrationValidator`, reading the destination directly.
public actor MigrationEngine {
    public typealias Progress = @Sendable (MigrationJobStatus) -> Void

    private let environment: HostEnvironment
    private let paths: AppPaths
    private let index: IndexRepository
    private let migrations: MigrationRepository
    private let preferences: PreferenceStore
    private let visibility: @Sendable () async -> Set<String>?
    private let writer = OpenCodeLegacyWriter()
    private let backups = BackupManager()
    private let validator = MigrationValidator()

    /// `visibility` reports which sessions the running OpenCode service lists. The default asks the
    /// OpenCode CLI when it is installed, and returns nil otherwise. Tests replace it.
    public init(
        environment: HostEnvironment,
        paths: AppPaths,
        index: IndexRepository,
        migrations: MigrationRepository,
        preferences: PreferenceStore,
        visibility: (@Sendable () async -> Set<String>?)? = nil
    ) {
        self.environment = environment
        self.paths = paths
        self.index = index
        self.migrations = migrations
        self.preferences = preferences
        self.visibility = visibility ?? { await OpenCodeVisibility.visibleSessionIds(environment: .current) }
    }

    public func writerStatus(destination: URL) throws -> WriterStatus {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return WriterStatus(isReady: false, detail: "No OpenCode database at \(destination.path).", writerVersion: OpenCodeLegacyWriter.writerVersion)
        }
        return try OpenCodeLegacyWriter.writerStatus(store: OpenCodeStore(databaseURL: destination))
    }

    public func recentJobs(limit: Int = 50) throws -> [MigrationJob] {
        try migrations.jobs(limit: limit)
    }

    public func backupRecords() throws -> [BackupRecord] {
        try migrations.backups()
    }

    public func mappings(jobId: String) throws -> [SessionMapping] {
        try migrations.mappings(jobId: jobId)
    }

    public func validations(jobId: String) throws -> [MigrationValidationResult] {
        try migrations.validations(jobId: jobId)
    }

    // MARK: - Planning

    /// Builds a plan without writing anything. Safe to call repeatedly.
    public func plan(selection: MigrationSelection, sourceRoot: String, destination: URL) async throws -> MigrationPlan {
        var issues: [PlanIssue] = []
        if !FileManager.default.fileExists(atPath: URL(fileURLWithPath: sourceRoot).appending(path: "projects").path) {
            issues.append(PlanIssue(
                severity: .blocker,
                code: "bad-source-root",
                message: "\(sourceRoot) has no projects folder. Use the Claude Code home directory, the one that contains projects/."
            ))
        }

        let allSources = try index.sessions(SessionQuery(
            agent: selection.sourceAgent,
            includeSubagents: true,
            sort: .title,
            limit: 1_000_000
        ))
        let sourcesById = Dictionary(allSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let childrenByParent = Dictionary(grouping: allSources.compactMap { session -> (String, SessionSummary)? in
            guard let parent = session.parentSessionId else { return nil }
            return (parent, session)
        }, by: \.0).mapValues { $0.map(\.1) }

        let selectedIds = Array(Set(selection.selectedSessionIds)).sorted()
        var reasons: [String: InclusionReason] = [:]
        for id in selectedIds {
            guard let session = sourcesById[id] else {
                issues.append(PlanIssue(severity: .blocker, code: "unknown-session", message: "\(id) is not in the index. Refresh and select again."))
                continue
            }
            if !session.isSubagent { reasons[id] = .selected }
        }
        for id in selectedIds {
            guard let session = sourcesById[id], session.isSubagent else { continue }
            if reasons[id] == nil { reasons[id] = .selected }
            guard let parent = session.parentSessionId else { continue }
            if reasons[parent] == nil, sourcesById[parent] != nil {
                reasons[parent] = .requiredParent
            } else if sourcesById[parent] == nil {
                issues.append(PlanIssue(severity: .blocker, code: "missing-parent", message: "\(session.title) belongs to a parent session that is not in the index."))
            }
        }
        for parentId in Array(reasons.keys) {
            for child in childrenByParent[parentId] ?? [] where reasons[child.id] == nil {
                reasons[child.id] = .subagentOfSelected
            }
        }

        let destinationExists = FileManager.default.fileExists(atPath: destination.path)
        var originRecords: [OpenCodeStore.OriginRecord] = []
        var destinationSignature = ""
        var destinationProfile: OpenCodeSchemaProfile?
        var projectIds = Set<String>()
        let store = OpenCodeStore(databaseURL: destination)
        if destinationExists {
            let status = try OpenCodeLegacyWriter.writerStatus(store: store)
            if !status.isReady {
                issues.append(PlanIssue(severity: .blocker, code: "writer-not-ready", message: status.detail))
            }
            let profile = try store.profile()
            destinationProfile = profile
            originRecords = try store.originMap()
            destinationSignature = try store.stateSignature(profile: profile)
            projectIds = try store.projectIds()
        } else {
            issues.append(PlanIssue(severity: .blocker, code: "no-destination", message: "The OpenCode database was not found at \(destination.path)."))
        }
        let anyByOrigin = Dictionary(originRecords.map { ($0.originId, $0) }, uniquingKeysWith: { first, _ in first })

        var toMigrate: [PlannedSession] = []
        var alreadyMigrated: [AlreadyMigratedSession] = []
        for (id, reason) in reasons.sorted(by: { lhs, rhs in
            let left = sourcesById[lhs.key]
            let right = sourcesById[rhs.key]
            return (left?.projectPath ?? "", left?.title ?? "") < (right?.projectPath ?? "", right?.title ?? "")
        }) {
            guard let session = sourcesById[id] else { continue }
            if let existing = anyByOrigin[session.originalId], let destinationProfile {
                let targetCount = try store.counts(forSession: existing.openCodeSessionId, profile: destinationProfile).messages
                alreadyMigrated.append(AlreadyMigratedSession(
                    id: id,
                    originId: session.originalId,
                    title: session.title,
                    targetSessionId: existing.openCodeSessionId,
                    sourceMessageCount: session.messageCount,
                    targetMessageCount: targetCount
                ))
            } else {
                toMigrate.append(PlannedSession(
                    id: id,
                    originId: session.originalId,
                    title: session.title,
                    projectPath: session.projectPath,
                    isSubagent: session.isSubagent,
                    parentSourceId: session.parentSessionId,
                    inclusionReason: reason,
                    expectedMessageCount: session.messageCount,
                    expectedUserPromptCount: (session.metadata["userPromptCount"]?.numberValue).map { Int($0) } ?? 0,
                    expectedToolCallCount: session.toolCallCount,
                    sourcePath: session.sourcePath ?? ""
                ))
            }
        }

        // Several transcripts with one origin id would make origin-based duplicate detection ambiguous.
        let sourceCounts = Dictionary(grouping: allSources, by: \.originalId).mapValues(\.count)
        for session in toMigrate where (sourceCounts[session.originId] ?? 0) > 1 {
            issues.append(PlanIssue(
                severity: .blocker,
                code: "duplicate-origin",
                message: "\(session.title) has the same id (\(session.originId)) as another transcript. The session would be written ambiguously. Resolve the duplicate first."
            ))
        }

        // A subagent whose parent already exists elsewhere cannot be linked correctly by a plain insert.
        let migratedParentOrigins = Set(alreadyMigrated.map(\.originId))
        for session in toMigrate where session.isSubagent {
            guard let parent = session.parentSourceId else { continue }
            if migratedParentOrigins.contains(MigrationValidator.originId(fromCompositeId: parent)) {
                issues.append(PlanIssue(
                    severity: .blocker,
                    code: "orphan-subagent",
                    message: "\(session.title) would be written without its parent link, because its parent already exists in OpenCode from an earlier run. Migrate these subagents with a fresh parent in a separate run or leave them out."
                ))
            }
        }

        for session in alreadyMigrated where session.sourceIsNewer {
            issues.append(PlanIssue(
                severity: .warning,
                code: "stale-copy",
                message: "\(session.title) has \(session.sourceMessageCount) messages in Claude Code but only \(session.targetMessageCount) in OpenCode. Existing copies are never updated, so the copy stays as it is."
            ))
        }
        if toMigrate.isEmpty && !alreadyMigrated.isEmpty {
            issues.append(PlanIssue(severity: .info, code: "all-migrated", message: "Every selected session is already in OpenCode. Nothing will be written."))
        }
        if selectedIds.isEmpty {
            issues.append(PlanIssue(severity: .info, code: "nothing-selected", message: "Select at least one session."))
        }

        let running = await OpenCodeProcessDetector.runningProcesses()
        if !running.isEmpty {
            issues.append(PlanIssue(
                severity: .warning,
                code: "opencode-running",
                message: "OpenCode is running (\(running.joined(separator: "; "))). It may write to the database during migration. SessionDock backs up first and verifies afterwards."
            ))
        }

        var sourceFingerprints: [String: FileFingerprint] = [:]
        for session in toMigrate where !session.sourcePath.isEmpty && sourceFingerprints[session.sourcePath] == nil {
            sourceFingerprints[session.sourcePath] = try FileFingerprinting.fingerprint(of: URL(fileURLWithPath: session.sourcePath))
        }

        // Build the rows in memory to show exactly what would be written. Nothing is persisted.
        var expected = LegacyCounts()
        var skipped: [String: Int] = [:]
        if !toMigrate.isEmpty {
            let inputs = try await buildInputs(for: toMigrate, alreadyMigrated: alreadyMigrated)
            let rows = OpenCodeLegacyWriter.rows(for: inputs, existingProjectIds: projectIds)
            expected = rows.counts
            skipped = rows.skipped
        }

        return MigrationPlan(
            selection: MigrationSelection(
                sourceAgent: selection.sourceAgent,
                targetAgent: selection.targetAgent,
                selectedSessionIds: selectedIds
            ),
            sessionsToMigrate: toMigrate,
            alreadyMigrated: alreadyMigrated,
            issues: issues,
            sourceRoot: sourceRoot,
            destinationDatabase: destination.path,
            destinationSignature: destinationSignature,
            sourceFingerprints: sourceFingerprints,
            expected: expected,
            skipped: skipped
        )
    }

    // MARK: - Execution

    public func execute(
        plan: MigrationPlan,
        destination: URL,
        backupRoot: URL,
        progress: Progress = { _ in }
    ) async throws -> MigrationReport {
        let blockers = plan.issues.filter { $0.severity == .blocker }.map(\.message)
        guard plan.canExecute else {
            throw MigrationError.planBlocked(blockers.isEmpty ? ["Nothing to migrate."] : blockers)
        }
        let prefs = try preferences.load()

        let store = OpenCodeStore(databaseURL: destination)
        let profile = try store.profile()
        guard try store.stateSignature(profile: profile) == plan.destinationSignature else {
            throw MigrationError.planStale("OpenCode's database changed since the preview.")
        }
        for (path, before) in plan.sourceFingerprints {
            let current = try FileFingerprinting.sha256(of: URL(fileURLWithPath: path))
            guard current == before.sha256 else {
                throw MigrationError.planStale("\(URL(fileURLWithPath: path).lastPathComponent) changed since the preview.")
            }
        }

        var job = MigrationJob(
            status: .backingUp,
            selection: plan.selection,
            planId: plan.id,
            sessionCount: plan.sessionsToMigrate.count,
            writerVersion: OpenCodeLegacyWriter.writerVersion,
            operation: "",
            stdoutExcerpt: "",
            stderrExcerpt: "",
            backupId: nil,
            summary: "Creating a verified backup of the OpenCode database."
        )
        try migrations.save(job: job)
        progress(.backingUp)

        let backup: BackupRecord
        do {
            backup = try backups.createBackup(of: destination, backupRoot: backupRoot, jobId: job.id, label: "pre-migration")
        } catch {
            job.status = .failed
            job.finishedAt = Date()
            job.summary = "Backup failed, so nothing was written. \(error.localizedDescription)"
            try migrations.save(job: job)
            throw error
        }
        try migrations.save(backup: backup)
        job.backupId = backup.id
        try? backups.prune(backupRoot: backupRoot, keep: prefs.backupRetentionCount)

        job.status = .migrating
        job.summary = "Writing \(plan.sessionsToMigrate.count) session(s) to OpenCode in one transaction."
        try migrations.save(job: job)
        progress(.migrating)

        let inputs = try await buildInputs(for: plan.sessionsToMigrate, alreadyMigrated: plan.alreadyMigrated)
        let existingProjects = try store.projectIds()
        let rows = OpenCodeLegacyWriter.rows(for: inputs, existingProjectIds: existingProjects)
        let sessionIdsBeforeWrite = try store.sessionIDs(profile: profile)
        do {
            try OpenCodeLegacyWriter.apply(rows, to: destination)
            job.operation = "Wrote \(rows.counts.sessions) session(s), \(rows.counts.messages) message(s), \(rows.counts.parts) part(s), \(rows.counts.projects) new project(s)."
        } catch {
            job.status = .failed
            job.finishedAt = Date()
            job.stderrExcerpt = Self.excerpt(error.localizedDescription)
            job.summary = "The write was rolled back, so OpenCode is unchanged. \(error.localizedDescription)"
            try migrations.save(job: job)
            progress(.failed)
            throw error
        }

        job.status = .verifying
        job.summary = "Verifying the written sessions against the database."
        try migrations.save(job: job)
        progress(.verifying)

        let visible = await visibility()
        let expectations = MigrationValidator.Expectations(
            planned: plan.sessionsToMigrate,
            alreadyMigrated: plan.alreadyMigrated,
            preExistingSessionIds: sessionIdsBeforeWrite,
            preExistingMessageCounts: Dictionary(
                plan.alreadyMigrated.map { ($0.targetSessionId, $0.targetMessageCount) },
                uniquingKeysWith: { first, _ in first }
            ),
            sourceFingerprintsBefore: plan.sourceFingerprints,
            openCodeVisibleIds: visible
        )
        var outcome = try validator.verify(jobId: job.id, expectations: expectations, store: store)
        outcome.results.append(Self.skippedRecordsResult(jobId: job.id, skipped: plan.skipped))

        let mappings = outcome.mappings + plan.alreadyMigrated.map { existing in
            SessionMapping(
                jobId: job.id,
                sourceAgent: .claudeCode,
                sourceSessionId: existing.id,
                targetAgent: .openCode,
                targetSessionId: existing.targetSessionId,
                status: .verified,
                verifiedAt: Date()
            )
        }
        try migrations.save(mappings: mappings)
        try migrations.save(validations: outcome.results)

        let verified = outcome.mappings.filter { $0.status == .verified }.count
        let failedErrors = outcome.results.filter { $0.severity == .error && !$0.passed }.count
        if failedErrors > 0 {
            job.status = .failedVerification
            job.summary = "Verification found \(failedErrors) error(s). \(verified) of \(plan.sessionsToMigrate.count) session(s) verified. Restore the backup if the result is not usable."
        } else if outcome.hasWarnings {
            job.status = .succeededWithWarnings
            job.summary = "\(verified) of \(plan.sessionsToMigrate.count) session(s) verified, with warnings. \(job.operation)"
        } else {
            job.status = .succeeded
            job.summary = plan.sessionsToMigrate.isEmpty
                ? "No new sessions were needed."
                : "\(verified) session(s) written and verified. \(job.operation)"
        }
        job.finishedAt = Date()
        try migrations.save(job: job)
        progress(job.status)

        return MigrationReport(job: job, mappings: mappings, validations: outcome.results, backup: backup)
    }

    // MARK: - Verification of existing copies

    /// Checks copies that already exist in OpenCode against the current Claude Code transcripts.
    /// Read-only: nothing is written, no job is recorded, and no backup is taken.
    public func verifyExisting(selection: MigrationSelection, destination: URL) async throws -> [MigrationValidationResult] {
        let allSources = try index.sessions(SessionQuery(agent: selection.sourceAgent, includeSubagents: true, sort: .title, limit: 1_000_000))
        let selected = allSources.filter { selection.selectedSessionIds.contains($0.id) }
        let store = OpenCodeStore(databaseURL: destination)
        let profile = try store.profile()
        let origins = Dictionary(try store.originMap().map { ($0.originId, $0) }, uniquingKeysWith: { first, _ in first })

        var planned: [PlannedSession] = []
        var fingerprints: [String: FileFingerprint] = [:]
        var preCounts: [String: Int] = [:]
        for session in selected {
            guard let existing = origins[session.originalId] else { continue }
            let counts = try store.counts(forSession: existing.openCodeSessionId, profile: profile)
            preCounts[existing.openCodeSessionId] = counts.messages
            planned.append(PlannedSession(
                id: session.id,
                originId: session.originalId,
                title: session.title,
                projectPath: session.projectPath,
                isSubagent: session.isSubagent,
                parentSourceId: session.parentSessionId,
                inclusionReason: .selected,
                expectedMessageCount: session.messageCount,
                expectedUserPromptCount: (session.metadata["userPromptCount"]?.numberValue).map { Int($0) } ?? 0,
                expectedToolCallCount: session.toolCallCount,
                sourcePath: session.sourcePath ?? ""
            ))
            if let path = session.sourcePath, fingerprints[path] == nil {
                fingerprints[path] = try FileFingerprinting.fingerprint(of: URL(fileURLWithPath: path))
            }
        }
        // Every selected session here already exists, so each is checked as expected and nothing may be new.
        let expectations = MigrationValidator.Expectations(
            planned: planned,
            alreadyMigrated: [],
            preExistingSessionIds: try store.sessionIDs(profile: profile),
            preExistingMessageCounts: preCounts,
            sourceFingerprintsBefore: fingerprints,
            openCodeVisibleIds: await visibility()
        )
        return try validator.verify(jobId: "verify-existing", expectations: expectations, store: store).results
    }

    // MARK: - Restore

    /// Restores a backup over the live database. Refused while OpenCode is running. A pre-restore copy
    /// of the current state is always taken first.
    public func restore(backupId: String, destination: URL, backupRoot: URL) async throws -> MigrationJob {
        guard let record = try migrations.backup(id: backupId) else { throw MigrationError.backupNotFound }
        let running = await OpenCodeProcessDetector.runningProcesses()
        guard running.isEmpty else { throw MigrationError.openCodeRunning(running) }

        let preRestore = try backups.createBackup(of: destination, backupRoot: backupRoot, jobId: nil, label: "pre-restore")
        try backups.restore(backupFile: URL(fileURLWithPath: record.backupPath), over: destination)

        var restored = record
        restored.restoredAt = Date()
        try migrations.save(backup: restored)

        let job = MigrationJob(
            finishedAt: Date(),
            status: .restored,
            selection: MigrationSelection(selectedSessionIds: []),
            planId: "",
            sessionCount: 0,
            writerVersion: OpenCodeLegacyWriter.writerVersion,
            operation: "",
            stdoutExcerpt: "",
            stderrExcerpt: "",
            backupId: record.id,
            summary: "Restored \(URL(fileURLWithPath: record.backupPath).lastPathComponent). The state before restore is kept at \(preRestore.backupPath)."
        )
        try migrations.save(job: job)
        return job
    }

    // MARK: - Helpers

    /// Reads each transcript and resolves its OpenCode parent: a session written in this run, or an
    /// existing copy of the parent. The OpenCode session id is deterministic, so a parent written in this
    /// run is known before the write.
    private func buildInputs(
        for sessions: [PlannedSession],
        alreadyMigrated: [AlreadyMigratedSession]
    ) async throws -> [OpenCodeLegacyWriter.Input] {
        let plannedOrigins = Set(sessions.map(\.originId))
        let existingByOrigin = Dictionary(alreadyMigrated.map { ($0.originId, $0.targetSessionId) }, uniquingKeysWith: { first, _ in first })
        var inputs: [OpenCodeLegacyWriter.Input] = []
        for planned in sessions {
            guard let summary = try index.session(id: planned.id) else {
                throw MigrationError.planStale("\(planned.title) is no longer in the index. Refresh and plan again.")
            }
            let messages = try await writer.readMessages(of: summary).messages
            var parentId: String?
            if let parent = planned.parentSourceId {
                let parentOrigin = MigrationValidator.originId(fromCompositeId: parent)
                if plannedOrigins.contains(parentOrigin) {
                    parentId = OpenCodeLegacyWriter.identifier(prefix: "ses", seed: "session:\(parentOrigin)")
                } else {
                    parentId = existingByOrigin[parentOrigin]
                }
            }
            inputs.append(OpenCodeLegacyWriter.Input(session: summary, messages: messages, parentOpenCodeId: parentId))
        }
        return inputs
    }

    static func skippedRecordsResult(jobId: String, skipped: [String: Int]) -> MigrationValidationResult {
        let total = skipped.values.reduce(0, +)
        let detail = total == 0
            ? "Every conversation record was mapped."
            : "Not written because OpenCode has no equivalent: " + skipped.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ") + ". They remain in the Claude Code transcript."
        return MigrationValidationResult(jobId: jobId, check: "records.unmapped", severity: .warning, passed: total == 0, detail: detail)
    }

    static func excerpt(_ text: String, limit: Int = 8_000) -> String {
        text.count <= limit ? text : String(text.suffix(limit))
    }
}
