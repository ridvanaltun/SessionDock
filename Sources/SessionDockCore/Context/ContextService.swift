import Foundation

public enum ContextKind: String, Codable, Sendable, Hashable, CaseIterable {
    case instructions
    case memory
    case rule
    case settings
    case configuration

    public var label: String {
        switch self {
        case .instructions: "Instructions"
        case .memory: "Memory"
        case .rule: "Rule"
        case .settings: "Settings"
        case .configuration: "Configuration"
        }
    }
}

public struct ContextFile: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var path: String
    public var displayName: String
    public var agent: AgentKind?
    public var kind: ContextKind
    public var projectPath: String?
    public var sizeBytes: Int64
    public var modifiedAt: Date?

    /// Only `CLAUDE.md` and `AGENTS.md` are candidates for an explicit copy.
    public var isCopyableInstruction: Bool {
        kind == .instructions && (displayName == "CLAUDE.md" || displayName == "AGENTS.md")
    }

    public init(
        path: String,
        displayName: String,
        agent: AgentKind?,
        kind: ContextKind,
        projectPath: String?,
        sizeBytes: Int64,
        modifiedAt: Date?
    ) {
        self.path = path
        self.displayName = displayName
        self.agent = agent
        self.kind = kind
        self.projectPath = projectPath
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

public struct ContextPreview: Sendable {
    public var text: String
    public var truncated: Bool
    public var isReadable: Bool
}

public struct ContextCopyResult: Sendable {
    public var source: String
    public var destination: String
    public var previousVersionBackup: String?
}

public enum ContextError: LocalizedError {
    case notCopyable(String)
    case targetExists(String)
    case sameFile
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notCopyable(let name): "\(name) is inspect-only. Only CLAUDE.md and AGENTS.md can be copied."
        case .targetExists(let path): "\(path) already exists. Confirm the overwrite to replace it. The current file is backed up first."
        case .sameFile: "Source and destination are the same file."
        case .unreadable(let path): "\(path) could not be read as text."
        }
    }
}

/// Discovers instruction, memory, rule, and configuration files, and performs explicit,
/// overwrite-protected copies of instruction files. Nothing else is ever written.
public struct ContextService: Sendable {
    private let environment: HostEnvironment

    public init(environment: HostEnvironment) {
        self.environment = environment
    }

    public var openCodeConfigDirectory: URL {
        if let xdg = environment.directory(forVariable: "XDG_CONFIG_HOME") {
            return xdg.appending(path: "opencode", directoryHint: .isDirectory)
        }
        return environment.homeDirectory.appending(path: ".config/opencode", directoryHint: .isDirectory)
    }

    public func discover(claudeCodeRoot: URL?, projectPaths: [String]) -> [ContextFile] {
        var files: [ContextFile] = []
        let fileManager = FileManager.default

        if let claudeRoot = claudeCodeRoot {
            files += existingFiles(in: [
                (claudeRoot.appending(path: "CLAUDE.md"), "CLAUDE.md", ContextKind.instructions),
                (claudeRoot.appending(path: "settings.json"), "settings.json", .settings),
            ], agent: .claudeCode, projectPath: nil)

            let projects = claudeRoot.appending(path: "projects", directoryHint: .isDirectory)
            for directory in childDirectories(of: projects) {
                let memory = directory.appending(path: "memory", directoryHint: .isDirectory)
                files += markdownFiles(in: memory).map {
                    ContextFile(
                        path: $0.path,
                        displayName: $0.lastPathComponent,
                        agent: .claudeCode,
                        kind: .memory,
                        projectPath: directory.lastPathComponent,
                        sizeBytes: Self.size(of: $0),
                        modifiedAt: Self.modified(of: $0)
                    )
                }
            }
        }

        let openCodeRoot = openCodeConfigDirectory
        files += existingFiles(in: [
            (openCodeRoot.appending(path: "AGENTS.md"), "AGENTS.md", .instructions),
            (openCodeRoot.appending(path: "opencode.json"), "opencode.json", .configuration),
        ], agent: .openCode, projectPath: nil)

        for path in Array(Set(projectPaths)).sorted() where fileManager.fileExists(atPath: path) {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            files += existingFiles(in: [
                (root.appending(path: "CLAUDE.md"), "CLAUDE.md", .instructions),
                (root.appending(path: "CLAUDE.local.md"), "CLAUDE.local.md", .instructions),
                (root.appending(path: ".claude/CLAUDE.md"), ".claude/CLAUDE.md", .instructions),
                (root.appending(path: "AGENTS.md"), "AGENTS.md", .instructions),
                (root.appending(path: "opencode.json"), "opencode.json", .configuration),
                (root.appending(path: "opencode.jsonc"), "opencode.jsonc", .configuration),
            ], agent: nil, projectPath: path)

            let rules = root.appending(path: ".claude/rules", directoryHint: .isDirectory)
            files += markdownFiles(in: rules).map {
                ContextFile(path: $0.path, displayName: $0.lastPathComponent, agent: .claudeCode, kind: .rule,
                            projectPath: path, sizeBytes: Self.size(of: $0), modifiedAt: Self.modified(of: $0))
            }
        }

        return files.sorted {
            ($0.projectPath ?? "", $0.kind.rawValue, $0.displayName) < ($1.projectPath ?? "", $1.kind.rawValue, $1.displayName)
        }
    }

    public func preview(_ file: ContextFile, maxBytes: Int = 200_000) throws -> ContextPreview {
        let url = URL(fileURLWithPath: file.path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else {
            return ContextPreview(text: "", truncated: false, isReadable: false)
        }
        let truncated = Int64(data.count) >= Int64(maxBytes) && file.sizeBytes > Int64(maxBytes)
        if file.kind == .settings || file.kind == .configuration {
            return ContextPreview(text: Self.redactedOutline(text), truncated: truncated, isReadable: true)
        }
        return ContextPreview(text: text, truncated: truncated, isReadable: true)
    }

    /// Settings and config files can hold credentials, so their values are never shown. The preview
    /// lists keys and value types only. Files that are not strict JSON (for example JSONC with
    /// comments) are reported as not previewable rather than shown raw.
    static func redactedOutline(_ text: String) -> String {
        guard let data = text.data(using: .utf8), let json = try? JSONValue.parse(data) else {
            return "Not shown: this file is not strict JSON, so SessionDock cannot list its keys safely. Values are never displayed for settings or configuration files because they can contain credentials."
        }
        var lines: [String] = []
        outline(json, indent: 0, into: &lines)
        lines.append("")
        lines.append("Values are hidden on purpose: settings and configuration files can contain credentials.")
        return lines.joined(separator: "\n")
    }

    private static func outline(_ value: JSONValue, indent: Int, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                let child = object[key] ?? .null
                switch child {
                case .object, .array:
                    lines.append("\(pad)\(key): \(describe(child))")
                    outline(child, indent: indent + 1, into: &lines)
                default:
                    lines.append("\(pad)\(key): \(describe(child))")
                }
            }
        case .array(let items):
            lines.append("\(pad)[\(items.count) item(s)]")
        default:
            lines.append("\(pad)\(describe(value))")
        }
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string(let text): "string (\(text.count) characters, hidden)"
        case .array(let items): "list of \(items.count)"
        case .object(let object): "object with \(object.count) key(s)"
        }
    }

    /// Copies an instruction file to a target path. Refuses to overwrite unless `overwrite` is true,
    /// and in that case first moves the current target to a timestamped sibling.
    public func copyInstruction(
        from source: ContextFile,
        to destination: URL,
        overwrite: Bool,
        now: Date = Date()
    ) throws -> ContextCopyResult {
        guard source.isCopyableInstruction else { throw ContextError.notCopyable(source.displayName) }
        let sourceURL = URL(fileURLWithPath: source.path)
        guard sourceURL.standardizedFileURL != destination.standardizedFileURL else { throw ContextError.sameFile }
        let fileManager = FileManager.default

        var backupPath: String?
        if fileManager.fileExists(atPath: destination.path) {
            guard overwrite else { throw ContextError.targetExists(destination.path) }
            let stamp = BackupManager.timestamp(now)
            let backup = destination.deletingLastPathComponent()
                .appending(path: "\(destination.deletingPathExtension().lastPathComponent).sessiondock-backup-\(stamp).md")
            try fileManager.copyItem(at: destination, to: backup)
            backupPath = backup.path
        }

        let data = try Data(contentsOf: sourceURL)
        try data.write(to: destination, options: .atomic)
        AppLog.context.info("Copied \(source.displayName, privacy: .public) to \(destination.lastPathComponent, privacy: .public)")
        return ContextCopyResult(source: source.path, destination: destination.path, previousVersionBackup: backupPath)
    }

    // MARK: - Helpers

    private func existingFiles(
        in candidates: [(URL, String, ContextKind)],
        agent: AgentKind?,
        projectPath: String?
    ) -> [ContextFile] {
        candidates.compactMap { url, name, kind in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ContextFile(
                path: url.path,
                displayName: name,
                agent: agent ?? Self.agentFor(name: name),
                kind: kind,
                projectPath: projectPath,
                sizeBytes: Self.size(of: url),
                modifiedAt: Self.modified(of: url)
            )
        }
    }

    private static func agentFor(name: String) -> AgentKind? {
        switch name {
        case "CLAUDE.md", "CLAUDE.local.md", ".claude/CLAUDE.md", "settings.json": .claudeCode
        case "AGENTS.md", "opencode.json", "opencode.jsonc": .openCode
        default: nil
        }
    }

    private func childDirectories(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func markdownFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func size(of url: URL) -> Int64 {
        FileFingerprinting.fileStat(of: url)?.size ?? 0
    }

    private static func modified(of url: URL) -> Date? {
        FileFingerprinting.fileStat(of: url)?.modifiedAt
    }
}
