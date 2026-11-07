import Foundation

public struct ClaudeCodeAdapter: AgentAdapter {
    public let kind = AgentKind.claudeCode
    public let scanner: any SessionScanner
    public let parser: any SessionParser
    public let storage: any SessionStorage
    private let environment: HostEnvironment

    public init(environment: HostEnvironment, parser: ClaudeCodeParser = ClaudeCodeParser()) {
        self.environment = environment
        self.scanner = ClaudeCodeScanner()
        self.parser = parser
        self.storage = ClaudeCodeStorage()
    }

    public func discover(overrides: PathOverrides) async -> AgentInstallation {
        var candidates: [(root: URL, source: LocationSource)] = []
        if let override = overrides.claudeCodeRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            candidates.append((environment.expandingTilde(override), .override))
        }
        if let url = environment.directory(forVariable: "CLAUDE_CONFIG_DIR") {
            candidates.append((url, .environment))
        }
        if let url = environment.directory(forVariable: "CLAUDE_CODE_HOME") {
            candidates.append((url, .environment))
        }
        candidates.append((environment.homeDirectory.appending(path: ".claude", directoryHint: .isDirectory), .defaultLocation))

        let fileManager = FileManager.default
        for candidate in candidates {
            let projects = candidate.root.appending(path: "projects", directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: projects.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            guard fileManager.isReadableFile(atPath: projects.path) else {
                return AgentInstallation(
                    agent: kind,
                    rootPath: candidate.root.path,
                    storePath: projects.path,
                    status: .unreadable("Permission denied"),
                    detail: "Found \(projects.path) but it cannot be read. Check file permissions.",
                    locationSource: candidate.source
                )
            }
            let projectCount = ((try? fileManager.contentsOfDirectory(atPath: projects.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .count
            return AgentInstallation(
                agent: kind,
                rootPath: candidate.root.path,
                storePath: projects.path,
                status: .available,
                detail: "Reading \(projects.path)",
                projectCount: projectCount,
                locationSource: candidate.source
            )
        }

        let checked = candidates.map { $0.root.appending(path: "projects").path }
        return AgentInstallation(
            agent: kind,
            rootPath: candidates.first?.root.path,
            storePath: nil,
            status: .notFound,
            detail: "No projects directory found. Checked: " + checked.joined(separator: ", "),
            locationSource: candidates.first?.source ?? .defaultLocation
        )
    }
}
