import Foundation
import OSLog

public enum AppLog {
    public static let subsystem = "dev.sessiondock"
    public static let scanning = Logger(subsystem: subsystem, category: "scanning")
    public static let database = Logger(subsystem: subsystem, category: "database")
    public static let migration = Logger(subsystem: subsystem, category: "migration")
    public static let context = Logger(subsystem: subsystem, category: "context")
}

public enum TimestampParser {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    /// Parses ISO-8601 timestamps as written by Claude Code (`2026-11-07T07:42:53.425Z`).
    public static func parse(_ text: String) -> Date? {
        if let date = try? fractional.parse(text) { return date }
        return try? plain.parse(text)
    }

    /// Converts a millisecond epoch (OpenCode stores these) into a Date.
    public static func fromEpochMilliseconds(_ value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }
}

extension String {
    /// First non-empty line, trimmed and truncated to `limit` characters.
    public func previewLine(limit: Int = 120) -> String {
        let line = split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    public func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit)) + "…"
    }
}

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
