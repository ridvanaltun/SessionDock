import Foundation
import GRDB
@testable import SessionDockCore

/// A temporary directory removed when the test object is released.
final class TempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "sessiondock-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appending(path: name)
    }
}

enum Fixtures {
    static let mainSessionId = "11111111-1111-4111-8111-111111111111"
    static let subagentId = "agent-aaaa1111bbbb2222"
    static let projectPath = "/Users/test/my-app"
    static let encodedProject = "-Users-test-my-app"

    static func environment(home: URL) -> HostEnvironment {
        HostEnvironment(homeDirectory: home, variables: [:])
    }

    /// Writes a Claude Code project with one main session and one subagent.
    /// The main session has: a user prompt, an assistant turn split over three records (thinking,
    /// text, tool_use), a tool result, a custom title, one malformed line, and a final assistant turn.
    static func makeClaudeProject(home: URL) throws -> (projects: URL, main: URL, subagent: URL) {
        let projects = home.appending(path: ".claude/projects", directoryHint: .isDirectory)
        let project = projects.appending(path: encodedProject, directoryHint: .isDirectory)
        let sessionDirectory = project.appending(path: mainSessionId, directoryHint: .isDirectory)
        let subagents = sessionDirectory.appending(path: "subagents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)

        let main = project.appending(path: "\(mainSessionId).jsonl")
        try writeLines(mainLines, to: main)

        let subagent = subagents.appending(path: "\(subagentId).jsonl")
        try writeLines(subagentLines, to: subagent)
        try #"{"agentType":"general-purpose","description":"Research the API"}"#
            .write(to: subagents.appending(path: "\(subagentId).meta.json"), atomically: true, encoding: .utf8)
        return (projects, main, subagent)
    }

    static func writeLines(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    static let mainLines: [String] = [
        #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-01T10:00:00.000Z","sessionId":"11111111-1111-4111-8111-111111111111"}"#,
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Build the importer"},"uuid":"u1","timestamp":"2026-01-01T10:00:01.000Z","cwd":"/Users/test/my-app","sessionId":"11111111-1111-4111-8111-111111111111","version":"2.1.0","gitBranch":"main"}"#,
        #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-test","role":"assistant","content":[{"type":"thinking","thinking":"Plan the work"}],"usage":{"input_tokens":5}},"uuid":"a1","timestamp":"2026-01-01T10:00:02.000Z","cwd":"/Users/test/my-app","sessionId":"11111111-1111-4111-8111-111111111111"}"#,
        #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-test","role":"assistant","content":[{"type":"text","text":"Sure, listing files."}]},"uuid":"a2","timestamp":"2026-01-01T10:00:03.000Z","cwd":"/Users/test/my-app","sessionId":"11111111-1111-4111-8111-111111111111"}"#,
        #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-test","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]},"uuid":"a3","timestamp":"2026-01-01T10:00:04.000Z","cwd":"/Users/test/my-app","sessionId":"11111111-1111-4111-8111-111111111111"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"file.txt"}],"is_error":false}]},"uuid":"u2","timestamp":"2026-01-01T10:00:05.000Z","cwd":"/Users/test/my-app","sessionId":"11111111-1111-4111-8111-111111111111","toolUseResult":{"stdout":"file.txt"}}"#,
        #"{"type":"custom-title","customTitle":"Importer work","sessionId":"11111111-1111-4111-8111-111111111111"}"#,
        #"{"type":"user", this line is broken"#,
        #"{"type":"assistant","message":{"id":"m2","model":"claude-opus-test","role":"assistant","content":[{"type":"text","text":"Done."}]},"uuid":"a4","timestamp":"2026-01-01T10:00:06.000Z","cwd":"/Users/test/my-app","sessionId":"11111111-1111-4111-8111-111111111111"}"#,
    ]

    static let subagentLines: [String] = [
        #"{"parentUuid":null,"isSidechain":true,"type":"user","message":{"role":"user","content":"Find the API docs"},"uuid":"s1","timestamp":"2026-01-01T10:01:00.000Z","cwd":"/Users/test/my-app","sessionId":"11111111-1111-4111-8111-111111111111","agentId":"aaaa1111bbbb2222"}"#,
        #"{"type":"assistant","message":{"id":"sm1","model":"claude-haiku-test","role":"assistant","content":[{"type":"text","text":"Found them."}]},"uuid":"s2","timestamp":"2026-01-01T10:01:05.000Z","cwd":"/Users/test/my-app","sessionId":"11111111-1111-4111-8111-111111111111","agentId":"aaaa1111bbbb2222"}"#,
    ]

    /// Creates an OpenCode database with both table generations, one v2 session with a subagent,
    /// and one legacy session that already carries a Claude Code origin.
    static func makeOpenCodeDatabase(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE project (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, name TEXT,
                    time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, sandboxes TEXT NOT NULL);
                CREATE TABLE session_v2 (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, workspace_id TEXT,
                    parent_id TEXT, slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT, version TEXT NOT NULL,
                    metadata TEXT, model TEXT, agent TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
                    time_archived INTEGER);
                CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, type TEXT NOT NULL,
                    seq INTEGER NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
                CREATE TABLE session_part (message_id TEXT NOT NULL, session_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
                    type TEXT NOT NULL, call_id TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
                    data TEXT NOT NULL, PRIMARY KEY (message_id, ordinal));
                CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, workspace_id TEXT, parent_id TEXT,
                    slug TEXT NOT NULL, directory TEXT NOT NULL, path TEXT, title TEXT NOT NULL, version TEXT NOT NULL,
                    metadata TEXT, agent TEXT, model TEXT, time_created INTEGER, time_updated INTEGER);
                CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER,
                    time_updated INTEGER, data TEXT NOT NULL);
                CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
                    time_created INTEGER, time_updated INTEGER, data TEXT NOT NULL);
                """)
            try db.execute(sql: """
                INSERT INTO project VALUES ('proj1', '/Users/test/other', 'other', 1, 1, '[]');
                INSERT INTO session_v2 (id, project_id, parent_id, slug, directory, title, version, metadata, model, agent,
                    time_created, time_updated) VALUES
                  ('ses_v2main', 'proj1', NULL, 'v2main', '/Users/test/other', 'OpenCode native', '2.1.4', NULL,
                   '{"id":"claude-haiku-5-5","providerID":"anthropic"}', 'build', 1793000000000, 1793000100000),
                  ('ses_v2child', 'proj1', 'ses_v2main', 'v2child', '/Users/test/other', 'Helper', '2.1.4', NULL, NULL,
                   'explore', 1793000010000, 1793000050000);
                INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES
                  ('msg_u1', 'ses_v2main', 'user', 0, 1793000000100, 1793000000100, '{"text":"Hello from OpenCode","files":[],"agents":[]}'),
                  ('msg_a1', 'ses_v2main', 'assistant', 1, 1793000001000, 1793000001000,
                   '{"model":{"id":"claude-haiku-5-5","providerID":"anthropic"},"content":[{"type":"reasoning","text":"thinking"},{"type":"text","text":"Hi"},{"type":"tool","id":"call_9","name":"read","executed":false,"state":{"status":"completed","input":{"path":"/tmp/x"},"content":[{"type":"text","text":"contents"}]}}]}'),
                  ('msg_s1', 'ses_v2child', 'assistant', 0, 1793000010100, 1793000010100, '{"content":[{"type":"text","text":"child"}]}'),
                  ('msg_i1', 'ses_v2main', 'idle', 2, 1793000002000, 1793000002000, '{"outcome":"succeeded"}');
                INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, metadata, agent, model, time_created, time_updated)
                  VALUES ('ses_legacy1', 'proj1', NULL, 'legacy', '/Users/test/my-app', 'Legacy copy', 'claude-code-migrated',
                   '{"claude_code_origin":"oldorigin-1111","is_subagent":false}', 'build', NULL, 1793000200000, 1793000200000);
                INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES
                  ('msg_leg1', 'ses_legacy1', 1793000200100, 1793000200100, '{"role":"user","ccOriginID":"x"}'),
                  ('msg_leg2', 'ses_legacy1', 1793000200200, 1793000200200, '{"role":"assistant","modelID":"claude-opus-5-5","providerID":"anthropic"}');
                INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES
                  ('prt_1', 'msg_leg1', 'ses_legacy1', 1, 1, '{"type":"text","text":"Legacy prompt"}'),
                  ('prt_2', 'msg_leg2', 'ses_legacy1', 2, 2, '{"type":"tool","callID":"toolu_L","tool":"bash","state":{"status":"completed","input":{"command":"pwd"},"output":"/tmp"}}'),
                  ('prt_3', 'msg_leg2', 'ses_legacy1', 3, 3, '{"type":"step-start"}');
                """)
        }
    }
}
