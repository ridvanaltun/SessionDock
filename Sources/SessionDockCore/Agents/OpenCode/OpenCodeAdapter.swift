import Foundation

public struct OpenCodeAdapter: AgentAdapter {
    public let kind = AgentKind.openCode
    public let scanner: any SessionScanner
    public let parser: any SessionParser
    public let storage: any SessionStorage
    private let environment: HostEnvironment

    public init(environment: HostEnvironment) {
        self.environment = environment
        self.scanner = OpenCodeScanner()
        self.parser = OpenCodeParser()
        self.storage = OpenCodeStorage()
    }

    public func discover(overrides: PathOverrides) async -> AgentInstallation {
        var candidates: [(url: URL, source: LocationSource)] = []
        if let override = overrides.openCodeDatabase?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            candidates.append((databaseURL(for: environment.expandingTilde(override)), .override))
        }
        if let dataHome = environment.directory(forVariable: "OPENCODE_DATA_HOME") {
            candidates.append((dataHome.appending(path: "opencode.db"), .environment))
        }
        if let xdg = environment.directory(forVariable: "XDG_DATA_HOME") {
            candidates.append((xdg.appending(path: "opencode/opencode.db"), .environment))
        }
        candidates.append((
            environment.homeDirectory.appending(path: ".local/share/opencode/opencode.db"),
            .defaultLocation
        ))

        let fileManager = FileManager.default
        for candidate in candidates where fileManager.fileExists(atPath: candidate.url.path) {
            guard fileManager.isReadableFile(atPath: candidate.url.path) else {
                return AgentInstallation(
                    agent: kind,
                    rootPath: candidate.url.deletingLastPathComponent().path,
                    storePath: candidate.url.path,
                    status: .unreadable("Permission denied"),
                    detail: "Found \(candidate.url.path) but it cannot be read.",
                    locationSource: candidate.source
                )
            }
            let store = OpenCodeStore(databaseURL: candidate.url)
            do {
                let profile = try store.profile()
                guard profile.hasV2Sessions || profile.hasLegacySessions else {
                    return AgentInstallation(
                        agent: kind,
                        rootPath: candidate.url.deletingLastPathComponent().path,
                        storePath: candidate.url.path,
                        status: .unreadable("Unrecognised schema"),
                        detail: "The database has no session tables. Found: \(profile.tables.sorted().joined(separator: ", ")).",
                        locationSource: candidate.source
                    )
                }
                let version = await Self.cliVersion(environment: environment)
                return AgentInstallation(
                    agent: kind,
                    rootPath: candidate.url.deletingLastPathComponent().path,
                    storePath: candidate.url.path,
                    status: .available,
                    detail: "Read-only access to \(candidate.url.lastPathComponent)",
                    version: version,
                    schemaSummary: profile.summary,
                    locationSource: candidate.source
                )
            } catch {
                return AgentInstallation(
                    agent: kind,
                    rootPath: candidate.url.deletingLastPathComponent().path,
                    storePath: candidate.url.path,
                    status: .unreadable(error.localizedDescription),
                    detail: "Could not open \(candidate.url.path) read-only: \(error.localizedDescription)",
                    locationSource: candidate.source
                )
            }
        }

        let checked = candidates.map { $0.url.path }
        return AgentInstallation(
            agent: kind,
            rootPath: candidates.first?.url.deletingLastPathComponent().path,
            storePath: nil,
            status: .notFound,
            detail: "No opencode.db found. Checked: " + checked.joined(separator: ", "),
            locationSource: candidates.first?.source ?? .defaultLocation
        )
    }

    private func databaseURL(for path: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path.appending(path: "opencode.db")
        }
        return path
    }

    private static func cliVersion(environment: HostEnvironment) async -> String? {
        let pathDirectories = (environment.variables["PATH"] ?? "").split(separator: ":").map(String.init)
            + [environment.homeDirectory.appending(path: ".opencode/bin").path]
        guard let executable = pathDirectories
            .map({ URL(fileURLWithPath: $0).appending(path: "opencode") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { return nil }
        guard let result = try? await ProcessRunner.run(
            executable: executable,
            arguments: ["--version"],
            timeout: .seconds(5)
        ), result.exitCode == 0 else { return nil }
        return result.stdout
            .split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

public struct OpenCodeScanner: SessionScanner {
    public init() {}

    public func scan(
        installation: AgentInstallation,
        previousStates: [SourceScanState],
        progress: (@Sendable (ScanProgress) -> Void)?
    ) async throws -> ScanOutcome {
        guard let storePath = installation.storePath else { return ScanOutcome() }
        let store = OpenCodeStore(databaseURL: URL(fileURLWithPath: storePath))
        let profile = try store.profile()
        let excerpts = try store.searchExcerpts(profile: profile)
        let sessions = try store.sessions(profile: profile).map { session -> SessionSummary in
            var updated = session
            updated.sourcePath = storePath
            updated.searchText = excerpts[session.originalId] ?? ""
            return updated
        }

        var projectsByID: [String: ProjectSummary] = [:]
        for session in sessions {
            var project = projectsByID[session.projectId] ?? ProjectSummary(
                id: session.projectId,
                agent: .openCode,
                path: session.projectPath,
                name: URL(fileURLWithPath: session.projectPath).lastPathComponent
            )
            if session.isSubagent { project.subagentCount += 1 } else { project.sessionCount += 1 }
            if let activity = session.updatedAt, activity > (project.lastActivityAt ?? .distantPast) {
                project.lastActivityAt = activity
            }
            projectsByID[session.projectId] = project
        }

        return ScanOutcome(
            sessions: sessions,
            projects: projectsByID.values.sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) },
            sourceStates: [],
            issues: [],
            filesScanned: 1,
            filesReused: 0
        )
    }
}

public struct OpenCodeParser: SessionParser {
    public init() {}

    public func page(for session: SessionSummary, offset: Int, limit: Int) async throws -> MessagePage {
        guard let storePath = session.sourcePath ?? session.metadata["databasePath"]?.stringValue else {
            return MessagePage(messages: [], nextOffset: nil, issues: [
                SourceIssue(kind: "no-database", detail: "The session is not linked to a database path.")
            ])
        }
        let store = OpenCodeStore(databaseURL: URL(fileURLWithPath: storePath))
        let profile = try store.profile()
        return try store.messages(forSession: session.originalId, profile: profile, offset: offset, limit: limit)
    }
}

public struct OpenCodeStorage: SessionStorage {
    public init() {}

    /// OpenCode sessions live in a shared database. Fingerprint the database with `databaseFingerprint`.
    public func fingerprint(for session: SessionSummary) throws -> FileFingerprint? { nil }
}
