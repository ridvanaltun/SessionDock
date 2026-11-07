import Foundation

/// Asks the running OpenCode service which sessions it can see, using OpenCode's own read-only API.
/// Returns `nil` when no service is running. This never starts the service, because starting it
/// would be a side effect of verification.
public enum OpenCodeVisibility {
    public static func visibleSessionIds(environment: HostEnvironment) async -> Set<String>? {
        guard let executable = ExecutableLocator.find(
            "opencode",
            environment: environment,
            extraDirectories: [environment.homeDirectory.appending(path: ".opencode/bin").path]
        ) else { return nil }

        guard let status = try? await ProcessRunner.run(
            executable: executable,
            arguments: ["service", "status"],
            timeout: .seconds(5)
        ), status.exitCode == 0, status.stdout.contains("http") else { return nil }

        guard let response = try? await ProcessRunner.run(
            executable: executable,
            arguments: ["api", "get", "/api/session"],
            timeout: .seconds(20)
        ), response.exitCode == 0 else { return nil }

        guard let data = response.stdout.data(using: .utf8),
              let json = try? JSONValue.parse(data),
              let items = json["data"]?.arrayValue else { return nil }
        return Set(items.compactMap { $0["id"]?.stringValue })
    }
}
