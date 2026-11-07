import GRDB
import XCTest
@testable import SessionDockCore

final class MigrationEngineTests: XCTestCase {
    struct Harness {
        let home: TempDirectory
        let destinationDirectory: TempDirectory
        let backupRoot: TempDirectory
        let snapshotRoot: TempDirectory
        let destination: URL
        let claudeRoot: URL
        let project: (projects: URL, main: URL, subagent: URL)
        let engine: MigrationEngine
        let index: IndexRepository
        let database: AppDatabase
        let migrations: MigrationRepository
    }

    private func makeHarness(extraMain: Bool = false) async throws -> Harness {
        let home = try TempDirectory()
        let project = try Fixtures.makeClaudeProject(home: home.url)
        if extraMain {
            try Fixtures.writeLines(Fixtures.mainLines, to: project.projects
                .appending(path: "\(Fixtures.encodedProject)/oldorigin-1111.jsonl"))
        }
        let destinationDirectory = try TempDirectory()
        let destination = destinationDirectory.file("opencode.db")
        try Fixtures.makeOpenCodeDatabase(at: destination)

        let environment = Fixtures.environment(home: home.url)
        let database = try AppDatabase.inMemory()
        let index = IndexRepository(database: database)
        let migrations = MigrationRepository(database: database)
        let preferences = PreferenceStore(database: database)
        let indexing = IndexingService(
            registry: AgentRegistry(adapters: [ClaudeCodeAdapter(environment: environment)]),
            index: index,
            preferences: preferences
        )
        _ = await indexing.refresh()

        let snapshotRoot = try TempDirectory()
        let backupRoot = try TempDirectory()
        let engine = MigrationEngine(
            environment: environment,
            paths: AppPaths(root: snapshotRoot.url),
            index: index,
            migrations: migrations,
            preferences: preferences,
            visibility: { nil }
        )
        return Harness(
            home: home,
            destinationDirectory: destinationDirectory,
            backupRoot: backupRoot,
            snapshotRoot: snapshotRoot,
            destination: destination,
            claudeRoot: home.url.appending(path: ".claude"),
            project: project,
            engine: engine,
            index: index,
            database: database,
            migrations: migrations
        )
    }

    private func selection(_ ids: [String]) -> MigrationSelection {
        MigrationSelection(selectedSessionIds: ids.map { id in
            id.hasPrefix("agent-")
                ? ClaudeCodeIdentity.subagentId(scope: Fixtures.encodedProject, parent: Fixtures.mainSessionId, originalId: id)
                : ClaudeCodeIdentity.sessionId(scope: Fixtures.encodedProject, originalId: id)
        })
    }

    func testPlanClosesOverSubagentsAndRequiredParents() async throws {
        let harness = try await makeHarness()
        let plan = try await harness.engine.plan(
            selection: selection([Fixtures.subagentId]),
            sourceRoot: harness.claudeRoot.path,
            destination: harness.destination
        )
        XCTAssertEqual(
            Set(plan.sessionsToMigrate.map(\.originId)),
            [Fixtures.mainSessionId, Fixtures.subagentId],
            "a subagent needs its parent for a valid link"
        )
        XCTAssertEqual(plan.sessionsToMigrate.first { $0.originId == Fixtures.mainSessionId }?.inclusionReason, .requiredParent)
        XCTAssertFalse(plan.issues.contains { $0.severity == .blocker }, "\(plan.issues)")
        XCTAssertTrue(plan.canExecute)
        XCTAssertEqual(plan.expected.sessions, 2)
        XCTAssertEqual(plan.expected.toolCalls, 1)
        XCTAssertEqual(plan.expected.userMessages, 2, "one prompt in the main session and one in the subagent; tool results are folded")
    }

    func testPlanNeverWritesToTheLiveDatabase() async throws {
        let harness = try await makeHarness()
        let store = OpenCodeStore(databaseURL: harness.destination)
        let before = try store.stateSignature(profile: try store.profile())
        let beforeBytes = try Data(contentsOf: harness.destination)

        _ = try await harness.engine.plan(
            selection: selection([Fixtures.mainSessionId]),
            sourceRoot: harness.claudeRoot.path,
            destination: harness.destination
        )

        XCTAssertEqual(try store.stateSignature(profile: try store.profile()), before)
        XCTAssertEqual(try Data(contentsOf: harness.destination), beforeBytes, "the live database file must be byte-identical after planning")
    }

    func testExecuteBacksUpMigratesAndVerifies() async throws {
        let harness = try await makeHarness()
        let plan = try await harness.engine.plan(
            selection: selection([Fixtures.mainSessionId]),
            sourceRoot: harness.claudeRoot.path,
            destination: harness.destination
        )
        let report = try await harness.engine.execute(plan: plan, destination: harness.destination, backupRoot: harness.backupRoot.url)

        let failing = report.validations.filter { !$0.passed }.map { "\($0.check): \($0.detail)" }
        XCTAssertEqual(report.job.status, .succeededWithWarnings, failing.joined(separator: "\n"))
        XCTAssertEqual(failing.count, 1, "the only open item is OpenCode's own v2 projection")
        XCTAssertTrue(failing.first?.contains("openCode.v2Projection") == true)
        XCTAssertEqual(report.mappings.filter { $0.status == .verified }.count, 2)
        let backup = try XCTUnwrap(report.backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.backupPath))
        XCTAssertEqual(backup.integrityResult, "ok")
        XCTAssertEqual(backup.sha256.count, 64)
        XCTAssertTrue(report.validations.allSatisfy { $0.passed || $0.severity != .error })

        let store = OpenCodeStore(databaseURL: harness.destination)
        let origins = try store.originMap().map(\.originId)
        XCTAssertTrue(origins.contains(Fixtures.mainSessionId))
        XCTAssertTrue(origins.contains(Fixtures.subagentId))

        let persisted = try harness.migrations.jobs()
        XCTAssertEqual(persisted.first?.id, report.job.id)
        let raw = try await harness.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_mapping WHERE jobId = ?", arguments: [report.job.id]) ?? -1
        }
        XCTAssertEqual(raw, 2, "rows persisted")
        XCTAssertEqual(try harness.migrations.mappings(jobId: report.job.id).count, 2, "rows decoded")
    }

    func testVerificationCountsSessionsWrittenByTheRunAsNew() async throws {
        let harness = try await makeHarness()
        let plan = try await harness.engine.plan(
            selection: selection([Fixtures.mainSessionId]),
            sourceRoot: harness.claudeRoot.path,
            destination: harness.destination
        )
        let report = try await harness.engine.execute(plan: plan, destination: harness.destination, backupRoot: harness.backupRoot.url)
        let check = try XCTUnwrap(report.validations.first { $0.check == "sessions.noUnexpected" })
        XCTAssertTrue(check.passed, check.detail)
        XCTAssertTrue(check.detail.hasPrefix("2 new session(s)"), "the ids before the write must not include the written sessions: \(check.detail)")
    }

    func testVerifyExistingSubagentFindsParentOutsideTheSelection() async throws {
        let harness = try await makeHarness()
        let plan = try await harness.engine.plan(
            selection: selection([Fixtures.mainSessionId]),
            sourceRoot: harness.claudeRoot.path,
            destination: harness.destination
        )
        _ = try await harness.engine.execute(plan: plan, destination: harness.destination, backupRoot: harness.backupRoot.url)

        let results = try await harness.engine.verifyExisting(
            selection: selection([Fixtures.subagentId]),
            destination: harness.destination
        )
        let link = try XCTUnwrap(results.first { $0.check == "subagents.parentLink" })
        XCTAssertTrue(link.passed, link.detail)
        XCTAssertTrue(link.detail.hasPrefix("1 subagent(s)"), link.detail)
    }

    func testStalePlanIsRefusedWhenDestinationChanges() async throws {
        let harness = try await makeHarness()
        let plan = try await harness.engine.plan(
            selection: selection([Fixtures.mainSessionId]),
            sourceRoot: harness.claudeRoot.path,
            destination: harness.destination
        )
        let queue = try DatabaseQueue(path: harness.destination.path)
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg_other', 'ses_legacy1', 1, 1, '{}')")
        }
        do {
            _ = try await harness.engine.execute(plan: plan, destination: harness.destination, backupRoot: harness.backupRoot.url)
            XCTFail("expected a stale plan error")
        } catch MigrationError.planStale {
        }
        XCTAssertEqual(try harness.migrations.jobs().count, 0, "nothing is recorded or written for a refused plan")
    }

    func testStalePlanIsRefusedWhenASourceTranscriptChanges() async throws {
        let harness = try await makeHarness()
        let plan = try await harness.engine.plan(
            selection: selection([Fixtures.mainSessionId]),
            sourceRoot: harness.claudeRoot.path,
            destination: harness.destination
        )
        try Fixtures.append(#"{"type":"assistant","message":{"id":"late","role":"assistant","content":[{"type":"text","text":"new"}]},"uuid":"z"}"# + "\n", to: harness.project.subagent)
        do {
            _ = try await harness.engine.execute(plan: plan, destination: harness.destination, backupRoot: harness.backupRoot.url)
            XCTFail("expected a stale plan error")
        } catch MigrationError.planStale(let detail) {
            XCTAssertTrue(detail.contains("changed"))
        }
    }

    func testExistingCopiesAreReportedAndNeverRewritten() async throws {
        let harness = try await makeHarness(extraMain: true)
        let plan = try await harness.engine.plan(
            selection: selection(["oldorigin-1111"]),
            sourceRoot: harness.claudeRoot.path,
            destination: harness.destination
        )
        XCTAssertEqual(plan.alreadyMigrated.map(\.originId), ["oldorigin-1111"])
        XCTAssertTrue(plan.sessionsToMigrate.isEmpty)
        XCTAssertFalse(plan.canExecute, "a plan with nothing new to write cannot be executed")
    }

    func testSubagentWhoseParentWasAlreadyMigratedIsBlocked() async throws {
        let harness = try await makeHarness()
        let queue = try DatabaseQueue(path: harness.destination.path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO session (id, parent_id, slug, directory, title, version, metadata, agent, time_created, time_updated)
                VALUES ('ses_earlier', NULL, 's', '/Users/test/my-app', 'Earlier', 'x',
                        '{"claude_code_origin":"\(Fixtures.mainSessionId)","is_subagent":false}', 'build', 1, 1)
                """)
        }
        let plan = try await harness.engine.plan(
            selection: selection([Fixtures.subagentId]),
            sourceRoot: harness.claudeRoot.path,
            destination: harness.destination
        )
        XCTAssertTrue(plan.issues.contains { $0.code == "orphan-subagent" && $0.severity == .blocker })
        XCTAssertFalse(plan.canExecute)
    }

    func testPlanRefusesUnknownSessionIds() async throws {
        let harness = try await makeHarness()
        let plan = try await harness.engine.plan(
            selection: selection(["does-not-exist"]),
            sourceRoot: harness.claudeRoot.path,
            destination: harness.destination
        )
        XCTAssertTrue(plan.issues.contains { $0.code == "unknown-session" })
        XCTAssertFalse(plan.canExecute)
    }
}
