import GRDB
import XCTest
@testable import SessionDockCore

final class OpenCodeStoreTests: XCTestCase {
    private var directories: [TempDirectory] = []

    private func makeStore() throws -> OpenCodeStore {
        let dir = try TempDirectory()
        directories.append(dir)
        let url = dir.file("opencode.db")
        try Fixtures.makeOpenCodeDatabase(at: url)
        return OpenCodeStore(databaseURL: url)
    }

    func testSchemaProfileDetectsBothTableGenerations() throws {
        let store = try makeStore()
        let profile = try store.profile()
        XCTAssertTrue(profile.hasV2Sessions)
        XCTAssertTrue(profile.hasV2Messages)
        XCTAssertTrue(profile.hasLegacySessions)
        XCTAssertTrue(profile.hasLegacyMessages)
        XCTAssertTrue(profile.has(column: "parent_id", in: "session_v2"))
    }

    func testSessionsUnionV2AndLegacyWithParentLinks() throws {
        let store = try makeStore()
        let sessions = try store.sessions(profile: try store.profile())
        XCTAssertEqual(Set(sessions.map(\.originalId)), ["ses_v2main", "ses_v2child", "ses_legacy1"])

        let child = try XCTUnwrap(sessions.first { $0.originalId == "ses_v2child" })
        XCTAssertTrue(child.isSubagent)
        XCTAssertEqual(child.parentSessionId, "opencode:ses_v2main")

        let legacy = try XCTUnwrap(sessions.first { $0.originalId == "ses_legacy1" })
        XCTAssertEqual(legacy.metadata["claude_code_origin"]?.stringValue, "oldorigin-1111")
        XCTAssertEqual(legacy.messageCount, 2)
        XCTAssertEqual(legacy.toolCallCount, 1)
        XCTAssertEqual(legacy.projectPath, "/Users/test/my-app")

        let main = try XCTUnwrap(sessions.first { $0.originalId == "ses_v2main" })
        XCTAssertEqual(main.model, "anthropic/claude-haiku-5-5")
        XCTAssertEqual(main.messageCount, 2, "user and assistant rows only")
        XCTAssertEqual(main.toolCallCount, 1)
    }

    func testV2AssistantPartsIncludeToolResultsAndReasoning() throws {
        let store = try makeStore()
        let page = try store.messages(forSession: "ses_v2main", profile: try store.profile(), offset: 0, limit: 10)
        XCTAssertEqual(page.messages.map(\.role), [.user, .assistant, .system])
        let assistant = page.messages[1]
        XCTAssertEqual(assistant.model, "anthropic/claude-haiku-5-5")
        XCTAssertTrue(assistant.contentParts.contains { if case .reasoning = $0 { true } else { false } })
        let call = assistant.contentParts.compactMap { part -> ToolCall? in
            if case .toolCall(let call) = part { return call }
            return nil
        }.first
        XCTAssertEqual(call?.name, "read")
        let result = assistant.contentParts.compactMap { part -> ToolResult? in
            if case .toolResult(let result) = part { return result }
            return nil
        }.first
        XCTAssertEqual(result?.output, "contents")
        guard case .unknown(let kind, _)? = page.messages[2].contentParts.first else {
            return XCTFail("unknown event types must be kept as unknown parts")
        }
        XCTAssertEqual(kind, "idle")
    }

    func testLegacyToolPartsAreMapped() throws {
        let store = try makeStore()
        let page = try store.messages(forSession: "ses_legacy1", profile: try store.profile(), offset: 0, limit: 10)
        XCTAssertEqual(page.messages.count, 2)
        let parts = page.messages[1].contentParts
        XCTAssertTrue(parts.contains { if case .toolCall(let call) = $0 { call.name == "bash" } else { false } })
        XCTAssertTrue(parts.contains { if case .toolResult(let result) = $0 { result.output == "/tmp" } else { false } })
        XCTAssertTrue(parts.contains { if case .unknown(let kind, _) = $0 { kind == "step-start" } else { false } })
    }

    func testOriginMapFindsExistingCopies() throws {
        let store = try makeStore()
        let origins = try store.originMap()
        XCTAssertEqual(origins.map(\.originId), ["oldorigin-1111"])
        XCTAssertEqual(origins.first?.table, "session")
    }

    func testCountsForVerification() throws {
        let store = try makeStore()
        let counts = try store.counts(forSession: "ses_legacy1", profile: try store.profile())
        XCTAssertEqual(counts.messages, 2)
        XCTAssertEqual(counts.toolCalls, 1)
    }

    func testStoreCannotWrite() throws {
        let store = try makeStore()
        let queue = try store.openReadOnly()
        XCTAssertThrowsError(try queue.write { db in
            try db.execute(sql: "CREATE TABLE should_not_exist (id INTEGER)")
        })
    }

    func testSearchExcerptsComeFromUserText() throws {
        let store = try makeStore()
        let excerpts = try store.searchExcerpts(profile: try store.profile())
        XCTAssertEqual(excerpts["ses_v2main"], "Hello from OpenCode")
        XCTAssertEqual(excerpts["ses_legacy1"], "Legacy prompt")
    }

    func testOpenCodeAdapterDiscoversExplicitDatabase() async throws {
        _ = try makeStore()
        let dir = try XCTUnwrap(directories.last)
        let home = try TempDirectory()
        let adapter = OpenCodeAdapter(environment: Fixtures.environment(home: home.url))
        let installation = await adapter.discover(overrides: PathOverrides(openCodeDatabase: dir.file("opencode.db").path))
        XCTAssertEqual(installation.status, .available)
        XCTAssertEqual(installation.locationSource, .override)
        XCTAssertEqual(installation.schemaSummary?.contains("v2 sessions"), true)
    }

    func testOpenCodeAdapterReportsUnrecognisedSchema() async throws {
        let dir = try TempDirectory()
        let url = dir.file("opencode.db")
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in try db.execute(sql: "CREATE TABLE other (id INTEGER)") }
        let home = try TempDirectory()
        let installation = await OpenCodeAdapter(environment: Fixtures.environment(home: home.url))
            .discover(overrides: PathOverrides(openCodeDatabase: url.path))
        guard case .unreadable(let reason) = installation.status else {
            return XCTFail("expected unreadable status, got \(installation.status)")
        }
        XCTAssertEqual(reason, "Unrecognised schema")
    }
}
