import XCTest
@testable import SessionDockCore

final class IndexRepositoryTests: XCTestCase {
    private func makeIndex() throws -> IndexRepository {
        IndexRepository(database: try AppDatabase.inMemory())
    }

    private func sessions() -> [SessionSummary] {
        let main = SessionSummary(
            agent: .claudeCode,
            originalId: "main",
            projectId: "p1",
            projectPath: "/Users/me/Kadıköy-app",
            title: "Importer work",
            updatedAt: Date(timeIntervalSince1970: 2_000),
            messageCount: 12,
            searchText: "Build the importer for the Kadıköy dataset"
        )
        let child = SessionSummary(
            agent: .claudeCode,
            originalId: "agent-1",
            projectId: "p1",
            projectPath: "/Users/me/Kadıköy-app",
            parentSessionId: main.id,
            isSubagent: true,
            title: "Research",
            updatedAt: Date(timeIntervalSince1970: 1_000),
            messageCount: 3
        )
        let other = SessionSummary(
            agent: .openCode,
            originalId: "ses_1",
            projectId: "p2",
            projectPath: "/Users/me/other",
            title: "Refactor auth",
            updatedAt: Date(timeIntervalSince1970: 3_000),
            messageCount: 40
        )
        return [main, child, other]
    }

    func testReplaceIndexStoresSessionsProjectsAndCounts() throws {
        let index = try makeIndex()
        try index.replaceIndex(agent: .claudeCode, sessions: Array(sessions().prefix(2)), sourceStates: [])
        let counts = try index.counts()
        XCTAssertEqual(counts.sessions, 2)
        XCTAssertEqual(counts.subagents, 1)
        XCTAssertEqual(counts.mainSessions, 1)
        XCTAssertEqual(try index.projects().count, 1)
    }

    func testFullTextSearchMatchesTitleAndExcerptWithPrefixes() throws {
        let index = try makeIndex()
        try index.replaceIndex(agent: .claudeCode, sessions: Array(sessions().prefix(2)), sourceStates: [])
        try index.replaceIndex(agent: .openCode, sessions: [sessions()[2]], sourceStates: [])

        let byTitle = try index.sessions(SessionQuery(text: "import"))
        XCTAssertEqual(byTitle.map(\.title), ["Importer work"])

        let byExcerpt = try index.sessions(SessionQuery(text: "dataset"))
        XCTAssertEqual(byExcerpt.map(\.title), ["Importer work"])

        let byPath = try index.sessions(SessionQuery(text: "kadıköy"))
        XCTAssertEqual(Set(byPath.map(\.title)), ["Importer work", "Research"])

        XCTAssertTrue(try index.sessions(SessionQuery(text: "nonexistentterm")).isEmpty)
    }

    func testSubagentsCanBeHiddenAndChildrenFound() throws {
        let index = try makeIndex()
        let all = sessions()
        try index.replaceIndex(agent: .claudeCode, sessions: Array(all.prefix(2)), sourceStates: [])
        XCTAssertEqual(try index.sessions(SessionQuery(agent: .claudeCode, includeSubagents: false)).count, 1)
        let children = try index.children(of: all[0].id)
        XCTAssertEqual(children.map(\.originalId), ["agent-1"])
    }

    func testReplacingAnAgentLeavesOtherAgentsAlone() throws {
        let index = try makeIndex()
        let all = sessions()
        try index.replaceIndex(agent: .claudeCode, sessions: Array(all.prefix(2)), sourceStates: [])
        try index.replaceIndex(agent: .openCode, sessions: [all[2]], sourceStates: [])
        try index.replaceIndex(agent: .claudeCode, sessions: [], sourceStates: [])
        XCTAssertEqual(try index.sessions(SessionQuery()).map(\.agent), [.openCode])
        XCTAssertTrue(try index.sessions(SessionQuery(text: "importer")).isEmpty, "search rows are removed with their sessions")
    }

    func testSortingByActivityAndMessageCount() throws {
        let index = try makeIndex()
        try index.replaceIndex(agent: .claudeCode, sessions: Array(sessions().prefix(2)), sourceStates: [])
        try index.replaceIndex(agent: .openCode, sessions: [sessions()[2]], sourceStates: [])
        XCTAssertEqual(try index.sessions(SessionQuery(sort: .recentActivity)).first?.title, "Refactor auth")
        XCTAssertEqual(try index.sessions(SessionQuery(sort: .messages)).first?.title, "Refactor auth")
    }

    func testPreferencesRoundTrip() throws {
        let database = try AppDatabase.inMemory()
        let store = PreferenceStore(database: database)
        XCTAssertEqual(try store.load(), AppPreferences())
        var prefs = AppPreferences()
        prefs.theme = .dark
        prefs.pathOverrides.claudeCodeRoot = "/custom/.claude"
        try store.save(prefs)
        XCTAssertEqual(try store.load(), prefs)
    }
}
