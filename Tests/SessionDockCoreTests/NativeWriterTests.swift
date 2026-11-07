import GRDB
import XCTest
@testable import SessionDockCore

final class NativeWriterMappingTests: XCTestCase {
    private func session(_ origin: String = "s-1", parent: String? = nil, path: String = "/Users/t/app") -> SessionSummary {
        SessionSummary(
            agent: .claudeCode,
            originalId: origin,
            projectId: "p",
            projectPath: path,
            parentSessionId: parent,
            isSubagent: parent != nil,
            title: "Fix the importer",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_060),
            messageCount: 3
        )
    }

    private func conversation(_ session: SessionSummary) -> [Message] {
        let id = session.id
        return [
            Message(
                id: "\(id):0", sessionId: id, ordinal: 0, role: .user,
                timestamp: Date(timeIntervalSince1970: 1_001), contentParts: [.text("Fix it")],
                metadata: ["recordIds": .array([.string("rec-user-1")])]
            ),
            Message(
                id: "\(id):1", sessionId: id, ordinal: 1, role: .assistant,
                timestamp: Date(timeIntervalSince1970: 1_002), model: "claude-opus-test",
                contentParts: [
                    .reasoning("plan"),
                    .text("Listing files."),
                    .toolCall(ToolCall(id: "t1", name: "Bash", input: .object(["command": .string("ls")]))),
                ],
                metadata: [
                    "recordIds": .array([.string("rec-asst-1")]),
                    "usage": .object(["input_tokens": .number(5), "output_tokens": .number(7)]),
                ]
            ),
            Message(
                id: "\(id):2", sessionId: id, ordinal: 2, role: .user,
                timestamp: Date(timeIntervalSince1970: 1_003),
                contentParts: [.toolResult(ToolResult(callId: "t1", output: "a.txt", isError: false))]
            ),
            Message(
                id: "\(id):3", sessionId: id, ordinal: 3, role: .system,
                timestamp: Date(timeIntervalSince1970: 1_004),
                contentParts: [.unknown(kind: "attachment:file", raw: .null)]
            ),
        ]
    }

    private func object(_ text: String) throws -> JSONValue {
        try JSONValue.parse(Data(text.utf8))
    }

    func testFoldsToolResultsAndLinksAssistantToItsPrompt() throws {
        let source = session()
        let rows = OpenCodeLegacyWriter.rows(
            for: [.init(session: source, messages: conversation(source), parentOpenCodeId: nil)],
            existingProjectIds: []
        )
        XCTAssertEqual(rows.counts.userMessages, 1, "the tool-result record is folded, not written as a prompt")
        XCTAssertEqual(rows.messages.count, 2)
        XCTAssertEqual(rows.skipped["system message"], 1, "system records are reported, not silently dropped")

        let user = try XCTUnwrap(rows.messages.first)
        let assistant = try XCTUnwrap(rows.messages.last)
        XCTAssertEqual(try object(assistant.data)["parentID"]?.stringValue, user.id)
        XCTAssertEqual(try object(assistant.data)["modelID"]?.stringValue, "claude-opus-test")
        XCTAssertEqual(try object(assistant.data)["tokens"]?["input"]?.numberValue, 5)
    }

    func testToolCallCarriesItsResultAndRenderingFields() throws {
        let source = session()
        let rows = OpenCodeLegacyWriter.rows(
            for: [.init(session: source, messages: conversation(source), parentOpenCodeId: nil)],
            existingProjectIds: []
        )
        let assistantId = try XCTUnwrap(rows.messages.last?.id)
        let parts = rows.parts.filter { $0.messageId == assistantId }.map { try? object($0.data) }

        XCTAssertEqual(parts.first??["type"]?.stringValue, "step-start", "step-start opens every assistant turn")
        XCTAssertEqual(parts.last??["type"]?.stringValue, "step-finish", "step-finish closes it")
        XCTAssertNotNil(parts.first??["time"], "step-start has a time")

        let tool = try XCTUnwrap(parts.compactMap { $0 }.first { $0["type"]?.stringValue == "tool" })
        XCTAssertEqual(tool["tool"]?.stringValue, "Bash")
        XCTAssertEqual(tool["callID"]?.stringValue, "t1")
        XCTAssertEqual(tool["state"]?["output"]?.stringValue, "a.txt")
        XCTAssertEqual(tool["state"]?["status"]?.stringValue, "completed")
        XCTAssertEqual(tool["state"]?["time"]?["compacted"]?.boolValue, false, "every tool state has a time block")
        XCTAssertEqual(rows.counts.toolCalls, 1)
    }

    func testIdentifiersAreDeterministicAndShaped() {
        let first = OpenCodeLegacyWriter.identifier(prefix: "ses", seed: "session:s-1")
        XCTAssertEqual(first, OpenCodeLegacyWriter.identifier(prefix: "ses", seed: "session:s-1"))
        XCTAssertNotEqual(first, OpenCodeLegacyWriter.identifier(prefix: "ses", seed: "session:s-2"))
        XCTAssertTrue(first.hasPrefix("ses_"))
        XCTAssertEqual(first.count, 30)
        XCTAssertTrue(first.dropFirst(4).allSatisfy { $0.isLetter || $0.isNumber })

        let project = OpenCodeLegacyWriter.projectIdentifier(worktree: "/Users/t/app")
        XCTAssertEqual(project.count, 40, "OpenCode project ids are 40 hex characters")
        XCTAssertTrue(project.allSatisfy(\.isHexDigit))
    }

    func testOneProjectRowPerDirectoryAndParentLinkForSubagents() {
        let main = session("s-1")
        let child = session("agent-1", parent: main.id)
        let mainId = OpenCodeLegacyWriter.identifier(prefix: "ses", seed: "session:s-1")
        let rows = OpenCodeLegacyWriter.rows(
            for: [
                .init(session: main, messages: conversation(main), parentOpenCodeId: nil),
                .init(session: child, messages: [], parentOpenCodeId: mainId),
            ],
            existingProjectIds: []
        )
        XCTAssertEqual(rows.projects.count, 1, "two sessions in one directory share one project row")
        XCTAssertEqual(rows.sessions.last?.parentId, mainId)
        XCTAssertEqual(rows.sessions.count, 2)
    }

    func testExistingProjectIsNotInsertedAgain() {
        let source = session()
        let existing = OpenCodeLegacyWriter.projectIdentifier(worktree: source.projectPath)
        let rows = OpenCodeLegacyWriter.rows(
            for: [.init(session: source, messages: conversation(source), parentOpenCodeId: nil)],
            existingProjectIds: [existing]
        )
        XCTAssertTrue(rows.projects.isEmpty)
    }
}

final class NativeWriterApplyTests: XCTestCase {
    private var directories: [TempDirectory] = []

    private func destination() throws -> URL {
        let dir = try TempDirectory()
        directories.append(dir)
        let url = dir.file("opencode.db")
        try Fixtures.makeOpenCodeDatabase(at: url)
        return url
    }

    private func rows() -> LegacyRows {
        let source = SessionSummary(
            agent: .claudeCode, originalId: "native-1", projectId: "p", projectPath: "/Users/t/fresh",
            title: "Native write", createdAt: Date(timeIntervalSince1970: 1_000), updatedAt: Date(timeIntervalSince1970: 1_010), messageCount: 1
        )
        let messages = [
            Message(id: "x:0", sessionId: source.id, ordinal: 0, role: .user, timestamp: Date(timeIntervalSince1970: 1_001),
                    contentParts: [.text("hello native")], metadata: [:]),
            Message(id: "x:1", sessionId: source.id, ordinal: 1, role: .assistant, timestamp: Date(timeIntervalSince1970: 1_002),
                    contentParts: [.text("hi")], metadata: [:]),
        ]
        return OpenCodeLegacyWriter.rows(for: [.init(session: source, messages: messages, parentOpenCodeId: nil)], existingProjectIds: [])
    }

    func testWrittenRowsAreReadableByTheOpenCodeStore() throws {
        let url = try destination()
        let written = rows()
        try OpenCodeLegacyWriter.apply(written, to: url)

        let store = OpenCodeStore(databaseURL: url)
        let origin = try store.originMap().first { $0.originId == "native-1" }
        XCTAssertNotNil(origin, "the duplicate-detection marker is stored")
        let page = try store.messages(forSession: origin?.openCodeSessionId ?? "", profile: try store.profile(), offset: 0, limit: 10)
        XCTAssertEqual(page.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(page.messages.first?.contentParts.first, .text("hello native"))
    }

    func testFailedWriteLeavesDestinationUnchanged() throws {
        let url = try destination()
        var broken = rows()
        // Two sessions with the same id violate the primary key on the second insert, after the first one
        // has already been queued. The whole write must roll back.
        broken.sessions.append(broken.sessions[0])
        let store = OpenCodeStore(databaseURL: url)
        let before = try store.sessionIDs(profile: try store.profile())

        XCTAssertThrowsError(try OpenCodeLegacyWriter.apply(broken, to: url))

        XCTAssertEqual(try store.sessionIDs(profile: try store.profile()), before, "nothing from a failed write is kept")
        XCTAssertEqual(try store.quickCheck(), "ok")
    }

    func testReadinessRequiresTheLegacyTables() throws {
        let dir = try TempDirectory()
        directories.append(dir)
        let empty = dir.file("empty.db")
        _ = try DatabaseQueue(path: empty.path)
        let status = try OpenCodeLegacyWriter.writerStatus(store: OpenCodeStore(databaseURL: empty))
        XCTAssertFalse(status.isReady)

        let ready = try OpenCodeLegacyWriter.writerStatus(store: OpenCodeStore(databaseURL: try destination()))
        XCTAssertTrue(ready.isReady)
    }
}
