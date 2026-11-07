import Foundation

/// Discovers Claude Code sessions under `~/.claude/projects/<encoded-cwd>/`.
///
/// Layout handled:
/// - `<encoded-cwd>/<session-uuid>.jsonl` main transcripts
/// - `<encoded-cwd>/<session-uuid>/subagents/agent-*.jsonl` subagent transcripts, with an
///   optional `agent-*.meta.json` describing the subagent
/// - `<session-uuid>/custom-title.json`, `*.prefix.json`, `tool-results/`, `memory/` sidecars
///
/// Transcripts are streamed and reduced line by line. Unchanged files are reused from the
/// persisted state, and appended files resume at their last complete line. Changed files are
/// scanned concurrently, with a bounded number of files in flight.
public struct ClaudeCodeScanner: SessionScanner {
    public init() {}

    public func scan(
        installation: AgentInstallation,
        previousStates: [SourceScanState],
        progress: (@Sendable (ScanProgress) -> Void)? = nil
    ) async throws -> ScanOutcome {
        guard let storePath = installation.storePath else { return ScanOutcome() }
        let projectsURL = URL(fileURLWithPath: storePath, isDirectory: true)
        let previous = previousStates.reduce(into: [String: SourceScanState]()) { $0[$1.sourcePath] = $1 }
        let jobs = try discoverJobs(projectsURL: projectsURL)

        progress?(ScanProgress(completed: 0, total: jobs.count))
        let results = try await reduceConcurrently(jobs, previous: previous, progress: progress)

        var outcome = ScanOutcome()
        for result in results {
            outcome.sessions.append(result.session)
            outcome.sourceStates.append(result.sourceState)
            if result.reused { outcome.filesReused += 1 } else { outcome.filesScanned += 1 }
        }
        outcome.sessions = Self.attachSubagentsToParentProjects(outcome.sessions)
        outcome.projects = Self.projects(from: outcome.sessions)
        return outcome
    }

    /// A subagent transcript is stored under its parent's project directory, but the subagent may
    /// have been started from a deeper working directory. Group it with its parent, and keep its own
    /// working directory in metadata so that nothing is lost.
    static func attachSubagentsToParentProjects(_ sessions: [SessionSummary]) -> [SessionSummary] {
        let parentPaths = Dictionary(
            sessions.filter { !$0.isSubagent }.map { ($0.id, $0.projectPath) },
            uniquingKeysWith: { first, _ in first }
        )
        return sessions.map { session in
            guard session.isSubagent,
                  let parentId = session.parentSessionId,
                  let parentPath = parentPaths[parentId],
                  parentPath != session.projectPath else { return session }
            var updated = session
            updated.metadata["agentWorkingDirectory"] = .string(session.projectPath)
            updated.projectPath = parentPath
            updated.projectId = ProjectIdentity.id(for: .claudeCode, path: parentPath)
            return updated
        }
    }

    // MARK: - Discovery

    struct TranscriptJob: Sendable {
        var url: URL
        var originalId: String
        var parentOriginalId: String?
        var agentMeta: JSONValue?
        var encodedName: String
        var inferredPath: String
        var sidecars: [String]
    }

    private func discoverJobs(projectsURL: URL) throws -> [TranscriptJob] {
        let fileManager = FileManager.default
        var jobs: [TranscriptJob] = []
        for projectDirectory in directoryChildren(of: projectsURL, fileManager: fileManager) {
            try Task.checkCancellation()
            let encodedName = projectDirectory.lastPathComponent
            let inferredPath = ClaudeCodePathDecoder.inferredPath(fromEncodedName: encodedName)
            let entries = directoryChildren(of: projectDirectory, fileManager: fileManager)

            for entry in entries where entry.pathExtension == "jsonl" && !isDirectory(entry) {
                let originalId = entry.deletingPathExtension().lastPathComponent
                let sessionDirectory = projectDirectory.appending(path: originalId, directoryHint: .isDirectory)
                jobs.append(TranscriptJob(
                    url: entry,
                    originalId: originalId,
                    parentOriginalId: nil,
                    agentMeta: nil,
                    encodedName: encodedName,
                    inferredPath: inferredPath,
                    sidecars: sidecarNames(in: sessionDirectory, fileManager: fileManager)
                ))
            }

            for entry in entries where isDirectory(entry) {
                let name = entry.lastPathComponent
                guard name != "tool-results", name != "memory" else { continue }
                let subagentDirectory = entry.appending(path: "subagents", directoryHint: .isDirectory)
                let subagentFiles = directoryChildren(of: subagentDirectory, fileManager: fileManager)
                    .filter { $0.lastPathComponent.hasPrefix("agent-") && $0.pathExtension == "jsonl" }
                for file in subagentFiles {
                    jobs.append(TranscriptJob(
                        url: file,
                        originalId: file.deletingPathExtension().lastPathComponent,
                        parentOriginalId: name,
                        agentMeta: readSubagentMeta(at: file.deletingPathExtension().appendingPathExtension("meta.json")),
                        encodedName: encodedName,
                        inferredPath: inferredPath,
                        sidecars: []
                    ))
                }
            }
        }
        return jobs
    }

    // MARK: - Concurrent reduction

    struct JobResult: Sendable {
        var session: SessionSummary
        var sourceState: SourceScanState
        var reused: Bool
    }

    private func reduceConcurrently(
        _ jobs: [TranscriptJob],
        previous: [String: SourceScanState],
        progress: (@Sendable (ScanProgress) -> Void)?
    ) async throws -> [JobResult] {
        let window = min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 8)
        return try await withThrowingTaskGroup(of: JobResult.self) { group in
            var iterator = jobs.makeIterator()
            var results: [JobResult] = []
            results.reserveCapacity(jobs.count)

            for _ in 0..<min(window, jobs.count) {
                guard let job = iterator.next() else { break }
                group.addTask { try Self.reduce(job, previous: previous[job.url.path]) }
            }
            while let result = try await group.next() {
                results.append(result)
                progress?(ScanProgress(completed: results.count, total: jobs.count))
                if let job = iterator.next() {
                    group.addTask { try Self.reduce(job, previous: previous[job.url.path]) }
                }
            }
            return results
        }
    }

    private static func reduce(_ job: TranscriptJob, previous: SourceScanState?) throws -> JobResult {
        try autoreleasepool {
            let transcript = try reduceTranscript(at: job.url, previous: previous)
            let session = makeSummary(transcript: transcript, job: job)
            return JobResult(session: session, sourceState: transcript.sourceState, reused: transcript.reused)
        }
    }

    // MARK: - Transcript reduction

    struct TranscriptScan {
        var state: ClaudeCodeScanState
        var sourceState: SourceScanState
        var size: Int64
        var modifiedAt: Date
        var reused: Bool
    }

    static func reduceTranscript(at url: URL, previous: SourceScanState?) throws -> TranscriptScan {
        let stat = FileFingerprinting.fileStat(of: url) ?? (size: 0, modifiedAt: .distantPast)
        let sessionKey = SessionSummary.compositeID(agent: .claudeCode, originalId: url.deletingPathExtension().lastPathComponent)

        if let previous, previous.size == stat.size, previous.modifiedAt == stat.modifiedAt,
           let state = decodeState(previous.stateJSON) {
            return TranscriptScan(state: state, sourceState: previous, size: stat.size, modifiedAt: stat.modifiedAt, reused: true)
        }

        var state = ClaudeCodeScanState()
        var start: UInt64 = 0
        let head = (try? FileFingerprinting.headDigest(of: url)) ?? ""
        if let previous, previous.size <= stat.size, previous.headDigest == head,
           previous.offset <= UInt64(max(stat.size, 0)), let resumed = decodeState(previous.stateJSON) {
            state = resumed
            start = previous.offset
        }

        var samples = state.malformedSamples
        let consumed = try JSONLReader.forEachCompleteLine(in: url, from: start) { line in
            try Task.checkCancellation()
            if line.bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                state.noteBlank()
                return true
            }
            do {
                let record = try JSONValue.parse(line.bytes)
                if case .object = record {
                    state.absorb(record)
                } else {
                    state.noteMalformed()
                    appendSample(&samples, kind: "non-object-record", line: line)
                }
            } catch {
                state.noteMalformed()
                appendSample(&samples, kind: "malformed-jsonl", line: line)
            }
            return true
        }
        state.malformedSamples = samples

        let sourceState = SourceScanState(
            sourcePath: url.path,
            sessionId: sessionKey,
            size: stat.size,
            modifiedAt: stat.modifiedAt,
            headDigest: head,
            offset: consumed,
            stateJSON: encodeState(state)
        )
        return TranscriptScan(state: state, sourceState: sourceState, size: stat.size, modifiedAt: stat.modifiedAt, reused: false)
    }

    private static func appendSample(_ samples: inout [SourceIssue], kind: String, line: JSONLLine) {
        guard samples.count < 20 else { return }
        let preview = String(decoding: line.bytes.prefix(160), as: UTF8.self)
        samples.append(SourceIssue(
            kind: kind,
            detail: "Record could not be decoded and was kept as an unparsed line.",
            byteOffset: line.startOffset,
            rawPreview: preview
        ))
    }

    private static func decodeState(_ json: String) -> ClaudeCodeScanState? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ClaudeCodeScanState.self, from: data)
    }

    private static func encodeState(_ state: ClaudeCodeScanState) -> String {
        guard let data = try? JSONEncoder().encode(state) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Summaries

    static func makeSummary(transcript: TranscriptScan, job: TranscriptJob) -> SessionSummary {
        let state = transcript.state
        let recordedPath = state.cwd
        let projectPath = recordedPath ?? job.inferredPath
        let projectId = ProjectIdentity.id(for: .claudeCode, path: projectPath)
        let descriptionText = job.agentMeta?["description"]?.stringValue
        let title = state.customTitle
            ?? state.agentName
            ?? descriptionText
            ?? state.firstUserText?.previewLine(limit: 120)
            ?? (job.parentOriginalId == nil ? "Untitled session" : "Subagent")

        var metadata: [String: JSONValue] = [
            "sourceFile": .string(transcript.sourceState.sourcePath),
            "sizeBytes": .number(Double(transcript.size)),
            "encodedProjectDirectory": .string(job.encodedName),
            "projectPathInferred": .bool(recordedPath == nil),
            "malformedLines": .number(Double(state.malformedLines)),
            "blankLines": .number(Double(state.blankLines)),
            "recordTypeCounts": .object(state.recordTypeCounts.mapValues { .number(Double($0)) }),
            "userPromptCount": .number(Double(state.userPromptCount)),
        ]
        if let version = state.version { metadata["claudeCodeVersion"] = .string(version) }
        if let branch = state.gitBranch { metadata["gitBranch"] = .string(branch) }
        if let customTitle = state.customTitle { metadata["customTitle"] = .string(customTitle) }
        if let sessionId = state.sessionId { metadata["recordSessionId"] = .string(sessionId) }
        if !job.sidecars.isEmpty { metadata["sidecarFiles"] = .array(job.sidecars.map { .string($0) }) }
        if !state.malformedSamples.isEmpty {
            metadata["malformedSamples"] = .array(state.malformedSamples.map { .object([
                "kind": .string($0.kind),
                "byteOffset": .number(Double($0.byteOffset ?? 0)),
                "rawPreview": .string($0.rawPreview ?? ""),
            ]) })
        }
        if let agentMeta = job.agentMeta { metadata["agentMeta"] = agentMeta }

        let fallbackDate = transcript.modifiedAt
        var summary = SessionSummary(
            agent: .claudeCode,
            originalId: job.originalId,
            projectId: projectId,
            projectPath: projectPath,
            parentSessionId: job.parentOriginalId.map { SessionSummary.compositeID(agent: .claudeCode, originalId: $0) },
            isSubagent: job.parentOriginalId != nil,
            subagentType: job.agentMeta?["agentType"]?.stringValue,
            title: title,
            createdAt: state.firstTimestamp ?? fallbackDate,
            updatedAt: state.lastTimestamp ?? fallbackDate,
            messageCount: state.messageGroups,
            toolCallCount: state.toolCalls,
            model: state.model,
            sourcePath: transcript.sourceState.sourcePath,
            metadata: metadata,
            searchText: state.excerpt
        )
        if let parentOriginalId = job.parentOriginalId {
            summary.id = ClaudeCodeIdentity.subagentId(scope: job.encodedName, parent: parentOriginalId, originalId: job.originalId)
            summary.parentSessionId = ClaudeCodeIdentity.sessionId(scope: job.encodedName, originalId: parentOriginalId)
        } else {
            summary.id = ClaudeCodeIdentity.sessionId(scope: job.encodedName, originalId: job.originalId)
        }
        return summary
    }

    static func projects(from sessions: [SessionSummary]) -> [ProjectSummary] {
        var projectsByID: [String: ProjectSummary] = [:]
        for session in sessions {
            var project = projectsByID[session.projectId] ?? ProjectSummary(
                id: session.projectId,
                agent: .claudeCode,
                path: session.projectPath,
                name: URL(fileURLWithPath: session.projectPath).lastPathComponent,
                pathIsInferred: session.metadata["projectPathInferred"]?.boolValue ?? false
            )
            if session.isSubagent {
                project.subagentCount += 1
            } else {
                project.sessionCount += 1
            }
            if let activity = session.updatedAt, activity > (project.lastActivityAt ?? .distantPast) {
                project.lastActivityAt = activity
            }
            projectsByID[session.projectId] = project
        }
        return projectsByID.values.sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
    }

    // MARK: - File helpers

    private func readSubagentMeta(at url: URL) -> JSONValue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONValue.parse(data)
    }

    private func sidecarNames(in sessionDirectory: URL, fileManager: FileManager) -> [String] {
        directoryChildren(of: sessionDirectory, fileManager: fileManager)
            .filter { $0.lastPathComponent != "subagents" }
            .prefix(40)
            .map(\.lastPathComponent)
    }

    /// Foundation refuses to list a symlinked directory, so the link is resolved first.
    /// Users commonly symlink project folders.
    private func directoryChildren(of url: URL, fileManager: FileManager = .default) -> [URL] {
        let children = (try? fileManager.contentsOfDirectory(
            at: url.resolvingSymlinksInPath(),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

enum ClaudeCodePathDecoder {
    /// Claude Code encodes `/Users/me/my-app` as `-Users-me-my-app`. The encoding is lossy, so the
    /// result is only used when no `cwd` was recorded, and is flagged as inferred.
    static func inferredPath(fromEncodedName name: String) -> String {
        guard !name.isEmpty else { return "/" }
        return "/" + name.drop(while: { $0 == "-" }).replacingOccurrences(of: "-", with: "/")
    }
}

/// Claude Code session ids are scoped by their project directory. The same session UUID can appear in
/// more than one project directory (for example after a worktree resume), so the UUID alone is not unique.
public enum ClaudeCodeIdentity {
    public static func sessionId(scope: String, originalId: String) -> String {
        "claude-code:\(scope)/\(originalId)"
    }

    /// Subagent files are copied into the new parent's folder when a session is resumed or forked, so
    /// the parent UUID is part of a subagent's identity as well.
    public static func subagentId(scope: String, parent: String, originalId: String) -> String {
        "claude-code:\(scope)/\(parent)/\(originalId)"
    }
}

/// A project is a working directory. The key is the same for every agent, so Claude Code and
/// OpenCode sessions recorded in one directory are grouped together.
public enum ProjectIdentity {
    public static func id(for _: AgentKind, path: String) -> String {
        let digest = Sha256Hex.digest(of: "project\u{0}\(path)")
        return "project:\(digest.prefix(16))"
    }
}
