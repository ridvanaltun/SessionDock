import Foundation

/// Verifies a migration by reading the destination directly. The CLI exit status and its text output
/// are recorded, but they never decide success.
public struct MigrationValidator: Sendable {
    public struct Expectations: Sendable {
        public var planned: [PlannedSession]
        public var alreadyMigrated: [AlreadyMigratedSession]
        /// OpenCode session ids present before the run, across both table generations.
        public var preExistingSessionIds: Set<String>
        /// Message-row counts per target session id before the run, to prove existing copies were untouched.
        public var preExistingMessageCounts: [String: Int]
        public var sourceFingerprintsBefore: [String: FileFingerprint]
        /// Session ids that OpenCode's own API reports, or `nil` when the service was not running.
        public var openCodeVisibleIds: Set<String>?

        public init(
            planned: [PlannedSession],
            alreadyMigrated: [AlreadyMigratedSession],
            preExistingSessionIds: Set<String>,
            preExistingMessageCounts: [String: Int],
            sourceFingerprintsBefore: [String: FileFingerprint],
            openCodeVisibleIds: Set<String>?
        ) {
            self.planned = planned
            self.alreadyMigrated = alreadyMigrated
            self.preExistingSessionIds = preExistingSessionIds
            self.preExistingMessageCounts = preExistingMessageCounts
            self.sourceFingerprintsBefore = sourceFingerprintsBefore
            self.openCodeVisibleIds = openCodeVisibleIds
        }
    }

    public struct Outcome: Sendable {
        public var results: [MigrationValidationResult]
        public var mappings: [SessionMapping]

        public var hasErrors: Bool {
            results.contains { $0.severity == .error && !$0.passed }
        }

        public var hasWarnings: Bool {
            results.contains { $0.severity == .warning && !$0.passed }
        }
    }

    public init() {}

    public func verify(
        jobId: String,
        expectations: Expectations,
        store: OpenCodeStore,
        now: Date = Date()
    ) throws -> Outcome {
        var results: [MigrationValidationResult] = []
        func record(_ check: String, _ severity: ValidationSeverity, _ passed: Bool, _ detail: String) {
            results.append(MigrationValidationResult(jobId: jobId, check: check, severity: severity, passed: passed, detail: detail))
        }

        let integrity = (try? store.quickCheck()) ?? "unreadable"
        record("database.integrity", .error, integrity == "ok", "PRAGMA quick_check returned \(integrity).")

        var changedSources: [String] = []
        for (path, before) in expectations.sourceFingerprintsBefore {
            let after = try? FileFingerprinting.sha256(of: URL(fileURLWithPath: path))
            if after != before.sha256 { changedSources.append(URL(fileURLWithPath: path).lastPathComponent) }
        }
        record(
            "source.unchanged",
            .error,
            changedSources.isEmpty,
            changedSources.isEmpty
                ? "\(expectations.sourceFingerprintsBefore.count) Claude Code transcripts are byte-identical to the plan."
                : "These transcripts changed during migration: \(changedSources.joined(separator: ", "))."
        )

        let profile = try store.profile()
        let originRecords = try store.originMap()
        let legacyByOrigin = Dictionary(
            originRecords.filter { $0.table == "session" }.map { ($0.originId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let v2ByOrigin = Dictionary(
            originRecords.filter { $0.table == "session_v2" }.map { ($0.originId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentIds = try store.sessionIDs(profile: profile)
        let newIds = currentIds.subtracting(expectations.preExistingSessionIds)

        let plannedOriginIds = Set(expectations.planned.map(\.originId))
        var openCodeIdByOrigin: [String: String] = [:]
        for session in expectations.planned {
            if let record = legacyByOrigin[session.originId] {
                openCodeIdByOrigin[session.originId] = record.openCodeSessionId
            }
        }
        for session in expectations.alreadyMigrated {
            if let record = legacyByOrigin[session.originId] ?? v2ByOrigin[session.originId] {
                openCodeIdByOrigin[session.originId] = record.openCodeSessionId
            }
        }

        var missing: [String] = []
        for session in expectations.planned where openCodeIdByOrigin[session.originId] == nil {
            missing.append(session.title)
        }
        record(
            "sessions.present",
            .error,
            missing.isEmpty,
            missing.isEmpty
                ? "All \(expectations.planned.count) planned sessions exist in OpenCode with their Claude Code origin."
                : "Missing from OpenCode: \(missing.joined(separator: "; "))."
        )

        let expectedNew = Set(openCodeIdByOrigin.filter { plannedOriginIds.contains($0.key) && !expectations.preExistingSessionIds.contains($0.value) }.values)
        let unexpected = newIds.subtracting(expectedNew)
        record(
            "sessions.noUnexpected",
            .error,
            unexpected.isEmpty,
            unexpected.isEmpty
                ? "\(newIds.count) new session(s) appeared, all of them planned."
                : "\(unexpected.count) session(s) appeared that were not in the plan."
        )

        var sessionOK: [String: Bool] = [:]
        for session in expectations.planned {
            sessionOK[session.id] = openCodeIdByOrigin[session.originId] != nil
        }

        var orphaned: [String] = []
        var parentChecked = 0
        for session in expectations.planned where session.isSubagent {
            guard let parentSource = session.parentSourceId,
                  openCodeIdByOrigin[session.originId] != nil else { continue }
            parentChecked += 1
            let parentOrigin = Self.originId(fromCompositeId: parentSource)
            let parentOpenCodeId = openCodeIdByOrigin[parentOrigin]
            let storedParent = legacyByOrigin[session.originId]?.parentOpenCodeSessionId
                ?? v2ByOrigin[session.originId]?.parentOpenCodeSessionId
            if parentOpenCodeId == nil || storedParent != parentOpenCodeId {
                orphaned.append(session.title)
                sessionOK[session.id] = false
            }
        }
        record(
            "subagents.parentLink",
            .error,
            orphaned.isEmpty,
            orphaned.isEmpty
                ? "\(parentChecked) subagent(s) are linked to their parent session."
                : "Subagents without a parent link: \(orphaned.joined(separator: "; "))."
        )

        var empty: [String] = []
        var promptMismatch: [String] = []
        var toolMismatch: [String] = []
        var totalNotes: [String] = []
        var checkedCounts = 0
        for session in expectations.planned {
            guard let openCodeId = openCodeIdByOrigin[session.originId] else { continue }
            let counts = try store.counts(forSession: openCodeId, profile: profile)
            let roles = try store.roleCounts(forSession: openCodeId)
            checkedCounts += 1
            let stored = counts.messages + counts.v2Messages
            if session.expectedMessageCount > 0 && stored == 0 {
                empty.append(session.title)
                sessionOK[session.id] = false
            }
            let userRows = roles["user"] ?? 0
            if userRows != session.expectedUserPromptCount {
                promptMismatch.append("\(session.title) (\(userRows) of \(session.expectedUserPromptCount))")
            }
            if session.expectedToolCallCount != counts.toolCalls {
                toolMismatch.append("\(session.title) (\(counts.toolCalls) of \(session.expectedToolCallCount))")
            }
            totalNotes.append("\(session.title): \(counts.messages) rows for \(session.expectedMessageCount) grouped messages")
        }
        record(
            "messages.present",
            .error,
            empty.isEmpty,
            empty.isEmpty
                ? "\(checkedCounts) migrated session(s) contain messages."
                : "No messages were written for: \(empty.joined(separator: "; "))."
        )
        record(
            "messages.userPrompts",
            .warning,
            promptMismatch.isEmpty,
            promptMismatch.isEmpty
                ? "User prompts match the source for every migrated session."
                : "User prompt counts differ: \(promptMismatch.joined(separator: "; "))."
        )
        record(
            "messages.total",
            .info,
            true,
            "Row counts (informational): " + totalNotes.joined(separator: "; ") + ". Assistant turns are grouped per response, so totals are not compared."
        )
        record(
            "toolCalls.parity",
            .warning,
            toolMismatch.isEmpty,
            toolMismatch.isEmpty
                ? "Tool-call counts match the source for every migrated session."
                : "Tool-call counts differ: \(toolMismatch.joined(separator: "; "))."
        )

        var changedExisting: [String] = []
        for session in expectations.alreadyMigrated {
            guard let openCodeId = openCodeIdByOrigin[session.originId] else { continue }
            let now = try store.counts(forSession: openCodeId, profile: profile).messages
            if let before = expectations.preExistingMessageCounts[openCodeId], before != now {
                changedExisting.append(session.title)
            }
        }
        record(
            "alreadyMigrated.untouched",
            .error,
            changedExisting.isEmpty,
            changedExisting.isEmpty
                ? "\(expectations.alreadyMigrated.count) existing copies were not modified."
                : "Existing copies were modified: \(changedExisting.joined(separator: "; "))."
        )

        if profile.hasV2Sessions {
            let projected = plannedOriginIds.filter { v2ByOrigin[$0] == nil }
            record(
                "openCode.v2Projection",
                .warning,
                projected.isEmpty,
                projected.isEmpty
                    ? "Every migrated session is also present in OpenCode's v2 session store."
                    : "\(projected.count) migrated session(s) are not yet in the v2 session store. OpenCode may project them on next start."
            )
        }

        if let visible = expectations.openCodeVisibleIds {
            let notVisible = openCodeIdByOrigin.filter { plannedOriginIds.contains($0.key) && !visible.contains($0.value) }
            record(
                "openCode.visible",
                .warning,
                notVisible.isEmpty,
                notVisible.isEmpty
                    ? "OpenCode's API lists every migrated session."
                    : "OpenCode's API does not list \(notVisible.count) migrated session(s). Reload OpenCode to see them."
            )
        } else {
            record("openCode.visible", .info, true, "OpenCode was not running, so API visibility was not checked. Database checks passed independently.")
        }

        let mappings = expectations.planned.map { session -> SessionMapping in
            let openCodeId = openCodeIdByOrigin[session.originId]
            let verified = sessionOK[session.id] ?? false
            return SessionMapping(
                jobId: jobId,
                sourceAgent: .claudeCode,
                sourceSessionId: session.id,
                targetAgent: .openCode,
                targetSessionId: openCodeId,
                status: verified ? .verified : .failed,
                verifiedAt: verified ? now : nil
            )
        }
        return Outcome(results: results, mappings: mappings)
    }

    /// Claude ids are `claude-code:<project-dir>/<uuid>`. OpenCode ids are `opencode:<id>`.
    /// The origin id is the key that links an OpenCode row back to its transcript.
    static func originId(fromCompositeId id: String) -> String {
        if let slash = id.lastIndex(of: "/") {
            return String(id[id.index(after: slash)...])
        }
        guard let separator = id.firstIndex(of: ":") else { return id }
        return String(id[id.index(after: separator)...])
    }
}
