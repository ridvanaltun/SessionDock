import GRDB
import XCTest
@testable import SessionDockCore

/// Runs against the real `~/.claude` and OpenCode database on this Mac. Opt-in with
/// `SESSIONDOCK_REAL_TESTS=1`, so CI and other machines never depend on personal data.
/// Everything here is read-only.
final class RealDataTests: XCTestCase {
    private func requireOptIn() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SESSIONDOCK_REAL_TESTS"] == "1",
                          "Set SESSIONDOCK_REAL_TESTS=1 to read real local data.")
    }

    func testChronomapTranscriptsAreDiscoveredWithRelationships() async throws {
        try requireOptIn()
        let real = HostEnvironment.current.homeDirectory.appending(path: ".claude/projects/-Users-ridvanaltun-Desktop-evincadde-chronomap")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: real.path), "The Chronomap project is not present.")

        // Copy only the Chronomap project into a temporary home, so the test never scans other projects.
        let home = try TempDirectory()
        let projects = home.url.appending(path: ".claude/projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: real, to: projects.appending(path: real.lastPathComponent))

        let installation = await ClaudeCodeAdapter(environment: Fixtures.environment(home: home.url)).discover(overrides: PathOverrides())
        XCTAssertEqual(installation.status, .available)
        let outcome = try await ClaudeCodeScanner().scan(installation: installation, previousStates: [])
        let chronomap = outcome.sessions.filter { $0.projectPath.hasSuffix("/evincadde/chronomap") }
        XCTAssertEqual(chronomap.count, 5, "two main sessions and three subagents")
        XCTAssertEqual(chronomap.filter(\.isSubagent).count, 3)

        let mainId = ClaudeCodeIdentity.sessionId(scope: "-Users-ridvanaltun-Desktop-evincadde-chronomap", originalId: "333d717b-7fe5-4237-bc4e-649561cc9c26")
        let children = chronomap.filter { $0.parentSessionId == mainId }
        XCTAssertEqual(children.count, 3, "all subagents link to the Chronomap main session")
        XCTAssertTrue(chronomap.contains { $0.title == "Chronomap geospatial platform" })
        XCTAssertTrue(chronomap.allSatisfy { $0.projectPath == "/Users/ridvanaltun/Desktop/evincadde/chronomap" })
    }

    func testLiveOpenCodeDatabaseIsReadableWithoutWriting() async throws {
        try requireOptIn()
        let environment = HostEnvironment.current
        let installation = await OpenCodeAdapter(environment: environment).discover(overrides: PathOverrides())
        try XCTSkipUnless(installation.status.isAvailable, "No OpenCode database on this machine.")
        let store = OpenCodeStore(databaseURL: URL(fileURLWithPath: try XCTUnwrap(installation.storePath)))
        let profile = try store.profile()
        XCTAssertTrue(profile.hasV2Sessions)
        let sessions = try store.sessions(profile: profile)
        XCTAssertFalse(sessions.isEmpty)
        XCTAssertEqual(try store.quickCheck(), "ok")
    }

    func testChronomapRelationshipsMatchExistingOpenCodeCopies() async throws {
        try requireOptIn()
        let environment = HostEnvironment.current
        let installation = await OpenCodeAdapter(environment: environment).discover(overrides: PathOverrides())
        try XCTSkipUnless(installation.status.isAvailable, "No OpenCode database on this machine.")
        let store = OpenCodeStore(databaseURL: URL(fileURLWithPath: try XCTUnwrap(installation.storePath)))
        let origins = try store.originMap().map(\.originId)
        XCTAssertTrue(origins.contains("333d717b-7fe5-4237-bc4e-649561cc9c26"), "the earlier migration is detected as a duplicate")
    }
}

extension RealDataTests {
    /// Verifies the Chronomap copies that already exist in the live OpenCode database. Read-only.
    /// The results are written to `SESSIONDOCK_REPORT_PATH` when set, so they can be reviewed.
    func testVerifyExistingChronomapCopiesInLiveDatabase() async throws {
        try requireOptIn()
        let real = HostEnvironment.current.homeDirectory.appending(path: ".claude/projects/-Users-ridvanaltun-Desktop-evincadde-chronomap")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: real.path), "The Chronomap project is not present.")
        let liveDatabase = HostEnvironment.current.homeDirectory.appending(path: ".local/share/opencode/opencode.db")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: liveDatabase.path), "No OpenCode database.")

        let home = try TempDirectory()
        let projects = home.url.appending(path: ".claude/projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: real, to: projects.appending(path: real.lastPathComponent))
        let environment = Fixtures.environment(home: home.url)

        let database = try AppDatabase.inMemory()
        let index = IndexRepository(database: database)
        let preferences = PreferenceStore(database: database)
        _ = await IndexingService(
            registry: AgentRegistry(adapters: [ClaudeCodeAdapter(environment: environment)]),
            index: index,
            preferences: preferences
        ).refresh()

        let engine = MigrationEngine(
            environment: environment,
            paths: AppPaths(root: home.url),
            index: index,
            migrations: MigrationRepository(database: database),
            preferences: preferences
        )
        let chronomapIds = try index.sessions(SessionQuery(agent: .claudeCode, sort: .title, limit: 1000))
            .filter { $0.projectPath.hasSuffix("/evincadde/chronomap") }
            .map(\.id)
        XCTAssertEqual(chronomapIds.count, 5)

        let results = try await engine.verifyExisting(
            selection: MigrationSelection(selectedSessionIds: chronomapIds),
            destination: liveDatabase
        )
        let report = results.map { "[\($0.passed ? "PASS" : "FAIL")][\($0.severity.rawValue)] \($0.check): \($0.detail)" }
        if let path = ProcessInfo.processInfo.environment["SESSIONDOCK_REPORT_PATH"] {
            try report.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        let errors = results.filter { $0.severity == .error && !$0.passed }
        XCTAssertTrue(errors.isEmpty, report.joined(separator: "\n"))
    }
}

extension RealDataTests {
    /// Full rehearsal on a COPY of the live database. The Chronomap rows are removed from the copy, and
    /// the complete plan → backup → write → verify flow runs against it. The live file is never opened
    /// for writing. Opt-in with `SESSIONDOCK_REHEARSE=1`.
    func testRehearsalOfFullMigrationOnSnapshot() async throws {
        try requireOptIn()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SESSIONDOCK_REHEARSE"] == "1", "Set SESSIONDOCK_REHEARSE=1 to run the rehearsal.")
        let real = HostEnvironment.current.homeDirectory.appending(path: ".claude/projects/-Users-ridvanaltun-Desktop-evincadde-chronomap")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: real.path), "The Chronomap project is not present.")
        let liveDatabase = HostEnvironment.current.homeDirectory.appending(path: ".local/share/opencode/opencode.db")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: liveDatabase.path), "No OpenCode database.")

        let work = try TempDirectory()
        let destination = work.file("opencode-rehearsal.db")
        try BackupManager().copyDatabase(from: liveDatabase, to: destination)
        do {
            let queue = try DatabaseQueue(path: destination.path)
            try await queue.write { db in
                let origin = "json_extract(metadata, '$.claude_code_origin') IS NOT NULL"
                try db.execute(sql: "DELETE FROM part WHERE session_id IN (SELECT id FROM session WHERE \(origin))")
                try db.execute(sql: "DELETE FROM message WHERE session_id IN (SELECT id FROM session WHERE \(origin))")
                try db.execute(sql: "DELETE FROM session WHERE \(origin)")
                try db.execute(sql: "DELETE FROM session_part WHERE session_id IN (SELECT id FROM session_v2 WHERE \(origin))")
                try db.execute(sql: "DELETE FROM session_message WHERE session_id IN (SELECT id FROM session_v2 WHERE \(origin))")
                try db.execute(sql: "DELETE FROM session_v2 WHERE \(origin)")
            }
        }

        let home = try TempDirectory()
        let projects = home.url.appending(path: ".claude/projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: real, to: projects.appending(path: real.lastPathComponent))
        let environment = Fixtures.environment(home: home.url)

        let database = try AppDatabase.inMemory()
        let index = IndexRepository(database: database)
        let preferences = PreferenceStore(database: database)
        _ = await IndexingService(
            registry: AgentRegistry(adapters: [ClaudeCodeAdapter(environment: environment)]),
            index: index,
            preferences: preferences
        ).refresh()
        let ids = try index.sessions(SessionQuery(agent: .claudeCode, sort: .title, limit: 1000))
            .filter { $0.projectPath.hasSuffix("/evincadde/chronomap") }
            .map(\.id)

        let engine = MigrationEngine(
            environment: environment,
            paths: AppPaths(root: work.url.appending(path: "app", directoryHint: .isDirectory)),
            index: index,
            migrations: MigrationRepository(database: database),
            preferences: preferences,
            visibility: { nil }
        )
        let selection = MigrationSelection(selectedSessionIds: ids)
        let sourceRoot = home.url.appending(path: ".claude").path
        let plan = try await engine.plan(selection: selection, sourceRoot: sourceRoot, destination: destination)
        let planLines = plan.issues.map { "\($0.severity.rawValue) \($0.code): \($0.message)" }
            + ["expected: \(plan.expected)", "skipped: \(plan.skipped)"]
        XCTAssertEqual(plan.sessionsToMigrate.count, 5, planLines.joined(separator: "\n"))
        XCTAssertTrue(plan.canExecute, planLines.joined(separator: "\n"))

        let backupRoot = work.url.appending(path: "backups", directoryHint: .isDirectory)
        let report = try await engine.execute(plan: plan, destination: destination, backupRoot: backupRoot)
        let lines = report.validations.map { "[\($0.passed ? "PASS" : "FAIL")][\($0.severity.rawValue)] \($0.check): \($0.detail)" }
        if let path = ProcessInfo.processInfo.environment["SESSIONDOCK_REPORT_PATH"] {
            try (["status: \(report.job.status.rawValue)", report.job.summary] + lines + planLines)
                .joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        XCTAssertNotEqual(report.job.status, .failedVerification, lines.joined(separator: "\n"))
        XCTAssertEqual(report.mappings.filter { $0.status == .verified }.count, 5, lines.joined(separator: "\n"))
        XCTAssertEqual(report.backup?.integrityResult, "ok")

        let replan = try await engine.plan(selection: selection, sourceRoot: sourceRoot, destination: destination)
        XCTAssertTrue(replan.sessionsToMigrate.isEmpty, "a second run must not duplicate anything")
        XCTAssertEqual(replan.alreadyMigrated.count, 5)
    }
}
