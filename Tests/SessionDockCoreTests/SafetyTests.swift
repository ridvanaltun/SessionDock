import GRDB
import XCTest
@testable import SessionDockCore

final class BackupManagerTests: XCTestCase {
    func testBackupIncludesCommittedRowsStillInTheWALFile() throws {
        let dir = try TempDirectory()
        let live = dir.file("live.db")
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_mode = WAL") }
        let queue = try DatabaseQueue(path: live.path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)")
            try db.execute(sql: "INSERT INTO notes (body) VALUES ('kept in wal')")
        }
        // The connection stays open, so the row is still in the -wal file. A plain file copy would miss it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path + "-wal"))

        let root = try TempDirectory()
        let record = try BackupManager().createBackup(of: live, backupRoot: root.url, jobId: "job-1", label: "test")
        XCTAssertEqual(record.integrityResult, "ok")

        let backup = try DatabaseQueue(path: record.backupPath)
        let bodies = try backup.read { db in try String.fetchAll(db, sql: "SELECT body FROM notes") }
        XCTAssertEqual(bodies, ["kept in wal"])
        withExtendedLifetime(queue) {}
    }

    func testRestoreReplacesLiveContentFromBackup() throws {
        let dir = try TempDirectory()
        let live = dir.file("live.db")
        do {
            let queue = try DatabaseQueue(path: live.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE notes (body TEXT)")
                try db.execute(sql: "INSERT INTO notes VALUES ('original')")
            }
        }
        let root = try TempDirectory()
        let record = try BackupManager().createBackup(of: live, backupRoot: root.url, jobId: nil, label: "test")

        do {
            let queue = try DatabaseQueue(path: live.path)
            try queue.write { db in try db.execute(sql: "DELETE FROM notes; INSERT INTO notes VALUES ('changed')") }
        }
        try BackupManager().restore(backupFile: URL(fileURLWithPath: record.backupPath), over: live)

        let restored = try DatabaseQueue(path: live.path).read { db in try String.fetchAll(db, sql: "SELECT body FROM notes") }
        XCTAssertEqual(restored, ["original"])
    }

    func testPruneKeepsNewestBackups() throws {
        let root = try TempDirectory()
        for name in ["20260101-000000-a", "20260102-000000-b", "20260103-000000-c"] {
            let directory = root.url.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "{}".write(to: directory.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        }
        try BackupManager().prune(backupRoot: root.url, keep: 2)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.url.path).sorted()
        XCTAssertEqual(remaining, ["20260102-000000-b", "20260103-000000-c"])
    }
}

final class ContextServiceTests: XCTestCase {
    private func makeProject() throws -> (TempDirectory, String) {
        let root = try TempDirectory()
        let project = root.url.appending(path: "app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "# Claude rules".write(to: project.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)
        try "# Agent rules".write(to: project.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
        return (root, project.path)
    }

    func testDiscoversInstructionFilesInProject() throws {
        let (root, projectPath) = try makeProject()
        let service = ContextService(environment: HostEnvironment(homeDirectory: root.url))
        let files = service.discover(claudeCodeRoot: nil, projectPaths: [projectPath])
        XCTAssertEqual(Set(files.map(\.displayName)), ["CLAUDE.md", "AGENTS.md"])
        XCTAssertTrue(files.allSatisfy { $0.isCopyableInstruction })
    }

    func testCopyRefusesToOverwriteWithoutConfirmation() throws {
        let (root, projectPath) = try makeProject()
        let service = ContextService(environment: HostEnvironment(homeDirectory: root.url))
        let files = service.discover(claudeCodeRoot: nil, projectPaths: [projectPath])
        let claude = try XCTUnwrap(files.first { $0.displayName == "CLAUDE.md" })
        let target = URL(fileURLWithPath: projectPath).appending(path: "AGENTS.md")

        XCTAssertThrowsError(try service.copyInstruction(from: claude, to: target, overwrite: false)) { error in
            guard case ContextError.targetExists = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "# Agent rules")
    }

    func testConfirmedOverwriteBacksUpTheExistingFile() throws {
        let (root, projectPath) = try makeProject()
        let service = ContextService(environment: HostEnvironment(homeDirectory: root.url))
        let files = service.discover(claudeCodeRoot: nil, projectPaths: [projectPath])
        let claude = try XCTUnwrap(files.first { $0.displayName == "CLAUDE.md" })
        let target = URL(fileURLWithPath: projectPath).appending(path: "AGENTS.md")

        let result = try service.copyInstruction(from: claude, to: target, overwrite: true)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "# Claude rules")
        let backup = try XCTUnwrap(result.previousVersionBackup)
        XCTAssertEqual(try String(contentsOfFile: backup, encoding: .utf8), "# Agent rules")
    }

    func testOnlyInstructionFilesAreCopyable() throws {
        let (root, _) = try makeProject()
        let settings = ContextFile(
            path: root.file("settings.json").path,
            displayName: "settings.json",
            agent: .claudeCode,
            kind: .settings,
            projectPath: nil,
            sizeBytes: 2,
            modifiedAt: nil
        )
        XCTAssertThrowsError(try ContextService(environment: HostEnvironment(homeDirectory: root.url))
            .copyInstruction(from: settings, to: root.file("x.json"), overwrite: false)) { error in
            guard case ContextError.notCopyable = error else { return XCTFail("unexpected \(error)") }
        }
    }
}

final class AdapterAndProcessTests: XCTestCase {
    func testProcessRunnerCapturesOutputAndExitCode() async throws {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo hello; echo oops 1>&2; exit 3"])
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout, "hello\n")
        XCTAssertEqual(result.stderr, "oops\n")
        XCTAssertFalse(result.timedOut)
    }

    func testProcessRunnerTerminatesOnTimeout() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            timeout: .milliseconds(200)
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testProcessRunnerCancellationStopsTheChild() async throws {
        let task = Task {
            try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let started = ContinuousClock.now
        _ = try? await task.value
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testFTSQueryIsEscapedAndPrefixed() {
        XCTAssertEqual(IndexRepository.ftsQuery("imp \"x\""), "\"imp\"* \"\"\"x\"\"\"*")
        XCTAssertNil(IndexRepository.ftsQuery("   "))
    }
}

final class ContextRedactionTests: XCTestCase {
    func testSettingsPreviewNeverShowsSecretValues() throws {
        let root = try TempDirectory()
        let file = root.file("settings.json")
        try #"{"env":{"EXAMPLE_PASSWORD":"hunter2-secret","TOKEN":"abc123"},"enabled":true,"list":[1,2]}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let context = ContextFile(path: file.path, displayName: "settings.json", agent: .claudeCode, kind: .settings,
                                  projectPath: nil, sizeBytes: 90, modifiedAt: nil)
        let preview = try ContextService(environment: HostEnvironment(homeDirectory: root.url)).preview(context)
        XCTAssertFalse(preview.text.contains("hunter2"))
        XCTAssertFalse(preview.text.contains("abc123"))
        XCTAssertTrue(preview.text.contains("EXAMPLE_PASSWORD"), "keys remain visible")
        XCTAssertTrue(preview.text.contains("list of 2"))
    }

    func testInstructionFilesStillShowFullText() throws {
        let root = try TempDirectory()
        let file = root.file("CLAUDE.md")
        try "# Rules\nUse tabs.".write(to: file, atomically: true, encoding: .utf8)
        let context = ContextFile(path: file.path, displayName: "CLAUDE.md", agent: .claudeCode, kind: .instructions,
                                  projectPath: nil, sizeBytes: 20, modifiedAt: nil)
        let preview = try ContextService(environment: HostEnvironment(homeDirectory: root.url)).preview(context)
        XCTAssertEqual(preview.text, "# Rules\nUse tabs.")
    }
}
