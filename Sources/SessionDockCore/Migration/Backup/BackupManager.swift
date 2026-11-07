import Foundation
import GRDB

/// Consistent database copies made with SQLite's online-backup API. A plain file copy of a WAL
/// database can miss committed pages that are still in the `-wal` file, so copies are never made
/// that way.
public struct BackupManager: Sendable {
    public struct Manifest: Codable, Sendable, Hashable {
        public var createdAt: Date
        public var originalPath: String
        public var backupFile: String
        public var sizeBytes: Int64
        public var sha256: String
        public var integrityResult: String
        public var sessionCount: Int
        public var messageCount: Int
        public var jobId: String?
        public var label: String
    }

    public init() {}

    /// Writes a consistent copy of `source` to `destination` and returns its checksum and counts.
    public func copyDatabase(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw MigrationError.destinationMissing(source.path)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let sourceQueue = try ReadOnlyDatabase.open(at: source)
        let destinationQueue = try DatabaseQueue(path: destination.path)
        try sourceQueue.backup(to: destinationQueue)
        // Make the copy self-contained: a single file with no -wal or -shm sidecar.
        try destinationQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
        }
        try destinationQueue.close()
    }

    /// Creates a verified backup in its own timestamped directory and writes `manifest.json`.
    public func createBackup(
        of source: URL,
        backupRoot: URL,
        jobId: String?,
        label: String,
        now: Date = Date()
    ) throws -> BackupRecord {
        let stamp = Self.timestamp(now)
        let suffix = jobId.map { String($0.prefix(8)) } ?? UUID().uuidString.prefix(8).lowercased()
        let directory = backupRoot.appending(path: "\(stamp)-\(suffix)", directoryHint: .isDirectory)
        let file = directory.appending(path: source.lastPathComponent)
        do {
            try copyDatabase(from: source, to: file)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw MigrationError.backupFailed(error.localizedDescription)
        }

        let verification = try verify(databaseAt: file)
        guard verification.integrity == "ok" else {
            try? FileManager.default.removeItem(at: directory)
            throw MigrationError.backupFailed("Backup integrity check returned \(verification.integrity).")
        }
        let digest = try FileFingerprinting.sha256(of: file)
        let size = (FileFingerprinting.fileStat(of: file)?.size) ?? 0

        let manifest = Manifest(
            createdAt: now,
            originalPath: source.path,
            backupFile: file.lastPathComponent,
            sizeBytes: size,
            sha256: digest,
            integrityResult: verification.integrity,
            sessionCount: verification.sessions,
            messageCount: verification.messages,
            jobId: jobId,
            label: label
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appending(path: "manifest.json"), options: .atomic)

        return BackupRecord(
            createdAt: now,
            originalPath: source.path,
            backupPath: file.path,
            sizeBytes: size,
            sha256: digest,
            integrityResult: verification.integrity,
            sessionCount: verification.sessions,
            messageCount: verification.messages,
            jobId: jobId
        )
    }

    /// Restores `backup` over `destination`. The caller must confirm that the destination application
    /// is closed. A pre-restore backup should be taken by the caller first.
    public func restore(backupFile: URL, over destination: URL) throws {
        guard FileManager.default.fileExists(atPath: backupFile.path) else { throw MigrationError.backupNotFound }
        let verification = try verify(databaseAt: backupFile)
        guard verification.integrity == "ok" else {
            throw MigrationError.restoreRefused("The backup failed its integrity check (\(verification.integrity)).")
        }
        let source = try ReadOnlyDatabase.open(at: backupFile)
        let target = try DatabaseQueue(path: destination.path)
        try source.backup(to: target)
        try target.close()
    }

    /// Keeps the newest `keep` backup directories and removes the rest.
    public func prune(backupRoot: URL, keep: Int) throws {
        guard keep > 0 else { return }
        let fileManager = FileManager.default
        let directories = (try? fileManager.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let ordered = directories
            .filter { fileManager.fileExists(atPath: $0.appending(path: "manifest.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in ordered.dropFirst(keep) {
            try fileManager.removeItem(at: stale)
        }
    }

    public struct Verification: Sendable, Hashable {
        public var integrity: String
        public var sessions: Int
        public var messages: Int
    }

    public func verify(databaseAt url: URL) throws -> Verification {
        let queue = try ReadOnlyDatabase.open(at: url)
        return try queue.read { db in
            let integrity = try String.fetchOne(db, sql: "PRAGMA quick_check(1)") ?? "unknown"
            let sessions = try Self.count(db, table: "session_v2") + Self.count(db, table: "session")
            let messages = try Self.count(db, table: "session_message") + Self.count(db, table: "message")
            return Verification(integrity: integrity, sessions: sessions, messages: messages)
        }
    }

    private static func count(_ db: Database, table: String) throws -> Int {
        let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?", arguments: [table]) ?? 0
        guard exists > 0 else { return 0 }
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
