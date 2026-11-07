import XCTest
@testable import SessionDockCore

final class JSONLReaderTests: XCTestCase {
    func testDeliversOnlyCompleteLinesAndLeavesPartialTailUnconsumed() throws {
        let dir = try TempDirectory()
        let file = dir.file("t.jsonl")
        try "one\ntwo\nthr".write(to: file, atomically: true, encoding: .utf8)

        var lines: [String] = []
        let consumed = try JSONLReader.forEachCompleteLine(in: file, from: 0) { line in
            lines.append(String(decoding: line.bytes, as: UTF8.self))
            return true
        }
        XCTAssertEqual(lines, ["one", "two"])
        XCTAssertEqual(consumed, 8)

        try Fixtures.append("ee\n", to: file)
        var resumed: [String] = []
        _ = try JSONLReader.forEachCompleteLine(in: file, from: consumed) { line in
            resumed.append(String(decoding: line.bytes, as: UTF8.self))
            return true
        }
        XCTAssertEqual(resumed, ["three"])
    }

    func testStopsEarlyWhenBodyReturnsFalse() throws {
        let dir = try TempDirectory()
        let file = dir.file("t.jsonl")
        try "a\nb\nc\n".write(to: file, atomically: true, encoding: .utf8)
        var count = 0
        let consumed = try JSONLReader.forEachCompleteLine(in: file, from: 0) { _ in
            count += 1
            return count < 2
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(consumed, 4)
    }

    func testHandlesLinesLargerThanTheReadChunk() throws {
        let dir = try TempDirectory()
        let file = dir.file("big.jsonl")
        let big = String(repeating: "x", count: 300_000)
        try "\(big)\nshort\n".write(to: file, atomically: true, encoding: .utf8)
        var sizes: [Int] = []
        _ = try JSONLReader.forEachCompleteLine(in: file, from: 0, chunkSize: 4096) { line in
            sizes.append(line.bytes.count)
            return true
        }
        XCTAssertEqual(sizes, [300_000, 5])
    }
}

final class ClaudeCodeScannerTests: XCTestCase {
    private func makeIndexedInstallation(home: URL) async -> AgentInstallation {
        let adapter = ClaudeCodeAdapter(environment: Fixtures.environment(home: home))
        return await adapter.discover(overrides: PathOverrides())
    }

    func testDiscoversMainSessionAndSubagentWithRelationship() async throws {
        let home = try TempDirectory()
        _ = try Fixtures.makeClaudeProject(home: home.url)
        let installation = await makeIndexedInstallation(home: home.url)
        XCTAssertEqual(installation.status, .available)

        let outcome = try await ClaudeCodeScanner().scan(installation: installation, previousStates: [])
        XCTAssertEqual(outcome.sessions.count, 2)

        let main = try XCTUnwrap(outcome.sessions.first { !$0.isSubagent })
        XCTAssertEqual(main.id, "claude-code:\(Fixtures.encodedProject)/\(Fixtures.mainSessionId)")
        XCTAssertEqual(main.projectPath, Fixtures.projectPath, "cwd must come from the record, not the directory name")
        XCTAssertEqual(main.title, "Importer work", "custom title wins over the first prompt")
        XCTAssertEqual(main.messageCount, 4, "consecutive assistant records with one message.id form one message")
        XCTAssertEqual(main.toolCallCount, 1)
        XCTAssertEqual(main.model, "claude-opus-test")
        XCTAssertEqual(main.metadata["malformedLines"]?.numberValue, 1)
        XCTAssertEqual(main.metadata["projectPathInferred"]?.boolValue, false)

        let child = try XCTUnwrap(outcome.sessions.first { $0.isSubagent })
        XCTAssertEqual(child.originalId, Fixtures.subagentId)
        XCTAssertEqual(child.parentSessionId, main.id)
        XCTAssertEqual(child.title, "Research the API", "subagent meta description is used as its title")
        XCTAssertEqual(child.subagentType, "general-purpose")
        XCTAssertEqual(child.messageCount, 2)

        XCTAssertEqual(outcome.projects.count, 1)
        XCTAssertEqual(outcome.projects.first?.sessionCount, 1)
        XCTAssertEqual(outcome.projects.first?.subagentCount, 1)
    }

    func testSecondScanReusesUnchangedFiles() async throws {
        let home = try TempDirectory()
        _ = try Fixtures.makeClaudeProject(home: home.url)
        let installation = await makeIndexedInstallation(home: home.url)
        let first = try await ClaudeCodeScanner().scan(installation: installation, previousStates: [])
        let second = try await ClaudeCodeScanner().scan(installation: installation, previousStates: first.sourceStates)
        XCTAssertEqual(second.filesScanned, 0)
        XCTAssertEqual(second.filesReused, 2)
        XCTAssertEqual(second.sessions.map(\.messageCount).sorted(), first.sessions.map(\.messageCount).sorted())
    }

    func testAppendedRecordsResumeFromLastCompleteLine() async throws {
        let home = try TempDirectory()
        let project = try Fixtures.makeClaudeProject(home: home.url)
        try Fixtures.append(#"{"type":"user","message":{"role":"user","content":"partial"#, to: project.main)
        let installation = await makeIndexedInstallation(home: home.url)

        let first = try await ClaudeCodeScanner().scan(installation: installation, previousStates: [])
        let firstMain = try XCTUnwrap(first.sessions.first { !$0.isSubagent })
        XCTAssertEqual(firstMain.messageCount, 4, "an unterminated trailing line must not be counted yet")

        try Fixtures.append(#""},"uuid":"u9","timestamp":"2026-01-01T10:00:09.000Z","sessionId":"x"}"# + "\n", to: project.main)
        try Fixtures.append(#"{"type":"assistant","message":{"id":"m9","role":"assistant","content":[{"type":"text","text":"ok"}]},"uuid":"a9"}"# + "\n", to: project.main)

        let second = try await ClaudeCodeScanner().scan(installation: installation, previousStates: first.sourceStates)
        let secondMain = try XCTUnwrap(second.sessions.first { !$0.isSubagent })
        XCTAssertEqual(secondMain.messageCount, 6)
        XCTAssertEqual(second.filesScanned, 1, "only the grown main transcript is re-read")
        XCTAssertEqual(secondMain.metadata["malformedLines"]?.numberValue, 1)
    }

    func testIgnoresNonProjectDirectoriesAndToolResults() async throws {
        let home = try TempDirectory()
        let project = try Fixtures.makeClaudeProject(home: home.url)
        let toolResults = project.main.deletingLastPathComponent()
            .appending(path: "\(Fixtures.mainSessionId)/tool-results", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: toolResults, withIntermediateDirectories: true)
        try "blob".write(to: toolResults.appending(path: "b.txt"), atomically: true, encoding: .utf8)
        let installation = await makeIndexedInstallation(home: home.url)
        let outcome = try await ClaudeCodeScanner().scan(installation: installation, previousStates: [])
        XCTAssertEqual(outcome.sessions.count, 2)
    }
}

final class ClaudeCodeParserTests: XCTestCase {
    private func session(home: URL) async throws -> (SessionSummary, SessionSummary) {
        let installation = await ClaudeCodeAdapter(environment: Fixtures.environment(home: home)).discover(overrides: PathOverrides())
        let outcome = try await ClaudeCodeScanner().scan(installation: installation, previousStates: [])
        return (
            try XCTUnwrap(outcome.sessions.first { !$0.isSubagent }),
            try XCTUnwrap(outcome.sessions.first { $0.isSubagent })
        )
    }

    func testPagesMessagesInOrderWithTheSameGroupingAsTheIndex() async throws {
        let home = try TempDirectory()
        _ = try Fixtures.makeClaudeProject(home: home.url)
        let (main, _) = try await session(home: home.url)
        let parser = ClaudeCodeParser()

        let first = try await parser.page(for: main, offset: 0, limit: 2)
        XCTAssertEqual(first.messages.count, 2)
        XCTAssertEqual(first.nextOffset, 2)
        XCTAssertEqual(first.messages[0].role, .user)
        XCTAssertEqual(first.messages[1].role, .assistant)

        let assistantParts = first.messages[1].contentParts
        XCTAssertEqual(assistantParts.count, 3, "thinking, text and tool_use from three records")
        XCTAssertTrue(assistantParts.contains { if case .reasoning = $0 { true } else { false } })
        XCTAssertTrue(assistantParts.contains { if case .toolCall = $0 { true } else { false } })

        let second = try await parser.page(for: main, offset: 2, limit: 10)
        XCTAssertNil(second.nextOffset)
        XCTAssertEqual(second.messages.map(\.ordinal), [2, 3])
        let toolResult = second.messages[0].contentParts.compactMap { part -> ToolResult? in
            if case .toolResult(let result) = part { return result }
            return nil
        }.first
        XCTAssertEqual(toolResult?.callId, "toolu_1")
        XCTAssertEqual(toolResult?.output, "file.txt")
        XCTAssertEqual(second.issues.count, 1, "the malformed line is reported, not silently skipped")
    }

    func testPreservesUnknownFieldsInMetadata() async throws {
        let home = try TempDirectory()
        _ = try Fixtures.makeClaudeProject(home: home.url)
        let (main, child) = try await session(home: home.url)
        let page = try await ClaudeCodeParser().page(for: main, offset: 0, limit: 1)
        let metadata = try XCTUnwrap(page.messages.first?.metadata)
        XCTAssertEqual(metadata["gitBranch"]?.stringValue, "main")
        XCTAssertEqual(metadata["version"]?.stringValue, "2.1.0")

        let childPage = try await ClaudeCodeParser().page(for: child, offset: 0, limit: 5)
        XCTAssertEqual(childPage.messages.count, 2)
        XCTAssertEqual(childPage.messages.last?.model, "claude-haiku-test")
    }

    func testToolCallsAreRepresentedAsDataNotExecutable() async throws {
        let home = try TempDirectory()
        _ = try Fixtures.makeClaudeProject(home: home.url)
        let (main, _) = try await session(home: home.url)
        let page = try await ClaudeCodeParser().page(for: main, offset: 1, limit: 1)
        let call = page.messages.first?.contentParts.compactMap { part -> ToolCall? in
            if case .toolCall(let call) = part { return call }
            return nil
        }.first
        XCTAssertEqual(call?.name, "Bash")
        XCTAssertEqual(call?.input["command"]?.stringValue, "ls")
    }
}

final class ClaudeCodeIdentityTests: XCTestCase {
    func testSameSessionUUIDInTwoProjectFoldersGetsDistinctIds() async throws {
        let home = try TempDirectory()
        _ = try Fixtures.makeClaudeProject(home: home.url)
        let worktree = home.url.appending(path: ".claude/projects/-Users-test-my-app--claude-worktrees-x", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Fixtures.writeLines(Fixtures.mainLines, to: worktree.appending(path: "\(Fixtures.mainSessionId).jsonl"))

        let installation = await ClaudeCodeAdapter(environment: Fixtures.environment(home: home.url)).discover(overrides: PathOverrides())
        let outcome = try await ClaudeCodeScanner().scan(installation: installation, previousStates: [])
        let ids = outcome.sessions.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "every session id must be unique")
        XCTAssertEqual(outcome.sessions.filter { $0.originalId == Fixtures.mainSessionId }.count, 2)
    }

    func testSubagentsGroupWithTheirParentProject() async throws {
        let home = try TempDirectory()
        let project = try Fixtures.makeClaudeProject(home: home.url)
        // The subagent ran from a deeper working directory than its parent.
        let deeper = Fixtures.subagentLines.map { $0.replacingOccurrences(of: "/Users/test/my-app", with: "/Users/test/my-app/apps/api") }
        try Fixtures.writeLines(deeper, to: project.subagent)
        let installation = await ClaudeCodeAdapter(environment: Fixtures.environment(home: home.url)).discover(overrides: PathOverrides())
        let outcome = try await ClaudeCodeScanner().scan(installation: installation, previousStates: [])
        let child = try XCTUnwrap(outcome.sessions.first { $0.isSubagent })
        XCTAssertEqual(child.projectPath, Fixtures.projectPath)
        XCTAssertEqual(child.metadata["agentWorkingDirectory"]?.stringValue, "/Users/test/my-app/apps/api")
    }

    func testDuplicateOriginsAreBlockedInThePlan() async throws {
        let home = try TempDirectory()
        _ = try Fixtures.makeClaudeProject(home: home.url)
        let worktree = home.url.appending(path: ".claude/projects/-Users-test-my-app--claude-worktrees-x", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Fixtures.writeLines(Fixtures.mainLines, to: worktree.appending(path: "\(Fixtures.mainSessionId).jsonl"))
        let database = try AppDatabase.inMemory()
        let index = IndexRepository(database: database)
        let preferences = PreferenceStore(database: database)
        let environment = Fixtures.environment(home: home.url)
        _ = await IndexingService(registry: AgentRegistry(adapters: [ClaudeCodeAdapter(environment: environment)]), index: index, preferences: preferences).refresh()
        let destinationDirectory = try TempDirectory()
        let destination = destinationDirectory.file("opencode.db")
        try Fixtures.makeOpenCodeDatabase(at: destination)
        let engine = MigrationEngine(
            environment: environment,
            paths: AppPaths(root: destinationDirectory.url),
            index: index,
            migrations: MigrationRepository(database: database),
            preferences: preferences,
            visibility: { nil }
        )
        let ids = try index.sessions(SessionQuery(agent: .claudeCode, limit: 100)).map(\.id)
        let plan = try await engine.plan(
            selection: MigrationSelection(selectedSessionIds: ids),
            sourceRoot: home.url.appending(path: ".claude").path,
            destination: destination
        )
        XCTAssertTrue(plan.issues.contains { $0.code == "duplicate-origin" && $0.severity == .blocker })
        XCTAssertFalse(plan.canExecute)
    }
}

final class ClaudeCodeSubagentIdentityTests: XCTestCase {
    func testSubagentCopiesUnderTwoParentsStayDistinct() async throws {
        let home = try TempDirectory()
        let project = try Fixtures.makeClaudeProject(home: home.url)
        // A resumed session copies the same subagent file under a second parent folder.
        let forkedParent = project.projects.appending(path: "\(Fixtures.encodedProject)/22222222-2222-4222-8222-222222222222/subagents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: forkedParent, withIntermediateDirectories: true)
        try Fixtures.writeLines(Fixtures.subagentLines, to: forkedParent.appending(path: "\(Fixtures.subagentId).jsonl"))

        let installation = await ClaudeCodeAdapter(environment: Fixtures.environment(home: home.url)).discover(overrides: PathOverrides())
        let outcome = try await ClaudeCodeScanner().scan(installation: installation, previousStates: [])
        let ids = outcome.sessions.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        let children = outcome.sessions.filter { $0.originalId == Fixtures.subagentId }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(Set(children.compactMap(\.parentSessionId)).count, 2, "each copy links to its own parent")
    }
}
