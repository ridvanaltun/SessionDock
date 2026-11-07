import Foundation

/// Finds command-line tools without relying on the shell. GUI apps launched from Finder inherit a
/// minimal PATH, so the usual install directories are always searched as well.
public enum ExecutableLocator {
    public static func find(
        _ name: String,
        environment: HostEnvironment,
        extraDirectories: [String] = []
    ) -> URL? {
        let pathEntries = (environment.variables["PATH"] ?? "").split(separator: ":").map(String.init)
        let defaults = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            environment.homeDirectory.appending(path: ".local/bin").path,
        ]
        let directories = extraDirectories + pathEntries + defaults
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// Detects whether an OpenCode process is currently running, so that writes can be warned about.
public enum OpenCodeProcessDetector {
    /// Returns short descriptions of running OpenCode processes. Matches the desktop app and the CLI
    /// or server, and ignores helpers such as `opencode-pty`.
    public static func runningProcesses() async -> [String] {
        guard let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axww", "-o", "pid=,command="],
            timeout: .seconds(5)
        ), result.exitCode == 0 else { return [] }

        return result.stdout.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            let pid = String(parts[0])
            let command = String(parts[1])
            let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
            if executable.contains("OpenCode.app/Contents/MacOS/OpenCode") { return "desktop app, pid \(pid)" }
            if URL(fileURLWithPath: executable).lastPathComponent == "opencode" { return "CLI or server, pid \(pid)" }
            return nil
        }
    }
}
