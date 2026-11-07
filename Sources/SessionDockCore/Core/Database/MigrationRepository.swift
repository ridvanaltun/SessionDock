import Foundation
import GRDB

/// Persistence for migration history: jobs, source-to-target mappings, validation results,
/// and backup records.
public struct MigrationRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func save(job: MigrationJob) throws {
        let encoder = JSONEncoder()
        let selection = String(decoding: try encoder.encode(job.selection), as: UTF8.self)
        // An upsert, not INSERT OR REPLACE: REPLACE deletes the row first, and the foreign keys from
        // session_mapping and validation_result would cascade-delete the job's history.
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO migration_job (
                    id, createdAt, finishedAt, status, selectionJSON, planId, sessionCount, writerVersion,
                    operation, stdoutExcerpt, stderrExcerpt, backupId, summary
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    finishedAt = excluded.finishedAt, status = excluded.status, writerVersion = excluded.writerVersion,
                    operation = excluded.operation, stdoutExcerpt = excluded.stdoutExcerpt,
                    stderrExcerpt = excluded.stderrExcerpt, backupId = excluded.backupId, summary = excluded.summary
                """, arguments: [
                    job.id, job.createdAt, job.finishedAt, job.status.rawValue, selection, job.planId,
                    job.sessionCount, job.writerVersion, job.operation,
                    job.stdoutExcerpt, job.stderrExcerpt, job.backupId, job.summary,
                ])
        }
    }

    public func jobCount() throws -> Int {
        try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM migration_job") ?? 0
        }
    }

    /// Number of recorded backups and their combined size, without a row limit.
    public func backupTotals() throws -> (count: Int, sizeBytes: Int64) {
        try database.writer.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS n, COALESCE(SUM(sizeBytes), 0) AS size FROM backup_record")
            return ((row?["n"] as Int?) ?? 0, (row?["size"] as Int64?) ?? 0)
        }
    }

    public func jobs(limit: Int = 50) throws -> [MigrationJob] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM migration_job ORDER BY createdAt DESC LIMIT ?", arguments: [limit])
                .compactMap { row -> MigrationJob? in
                    guard let status = MigrationJobStatus(rawValue: row["status"]) else { return nil }
                    let selectionText: String = row["selectionJSON"]
                    let selection = (try? JSONDecoder().decode(MigrationSelection.self, from: Data(selectionText.utf8)))
                        ?? MigrationSelection(selectedSessionIds: [])
                    return MigrationJob(
                        id: row["id"],
                        createdAt: row["createdAt"],
                        finishedAt: row["finishedAt"],
                        status: status,
                        selection: selection,
                        planId: row["planId"],
                        sessionCount: row["sessionCount"],
                        writerVersion: row["writerVersion"],
                        operation: row["operation"],
                        stdoutExcerpt: row["stdoutExcerpt"],
                        stderrExcerpt: row["stderrExcerpt"],
                        backupId: row["backupId"],
                        summary: row["summary"]
                    )
                }
        }
    }

    public func save(mappings: [SessionMapping]) throws {
        try database.writer.write { db in
            for mapping in mappings {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO session_mapping (
                        id, jobId, sourceAgent, sourceSessionId, targetAgent, targetSessionId, status, verifiedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        mapping.id, mapping.jobId, mapping.sourceAgent.rawValue, mapping.sourceSessionId,
                        mapping.targetAgent.rawValue, mapping.targetSessionId, mapping.status.rawValue, mapping.verifiedAt,
                    ])
            }
        }
    }

    public func mappings(jobId: String) throws -> [SessionMapping] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM session_mapping WHERE jobId = ? ORDER BY sourceSessionId", arguments: [jobId])
                .compactMap(Self.mapping(from:))
        }
    }

    /// The most recent verified target for a source session, if any job has produced one.
    public func latestVerifiedMapping(sourceSessionId: String, targetAgent: AgentKind) throws -> SessionMapping? {
        try database.writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM session_mapping
                WHERE sourceSessionId = ? AND targetAgent = ? AND status = 'verified'
                ORDER BY verifiedAt DESC LIMIT 1
                """, arguments: [sourceSessionId, targetAgent.rawValue]).flatMap(Self.mapping(from:))
        }
    }

    public func save(validations: [MigrationValidationResult]) throws {
        try database.writer.write { db in
            for result in validations {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO validation_result (id, jobId, "check", severity, passed, detail)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [result.id, result.jobId, result.check, result.severity.rawValue, result.passed, result.detail])
            }
        }
    }

    public func validations(jobId: String) throws -> [MigrationValidationResult] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM validation_result WHERE jobId = ? ORDER BY rowid", arguments: [jobId]).map { row in
                MigrationValidationResult(
                    id: row["id"],
                    jobId: row["jobId"],
                    check: row["check"],
                    severity: ValidationSeverity(rawValue: row["severity"]) ?? .error,
                    passed: row["passed"],
                    detail: row["detail"]
                )
            }
        }
    }

    public func save(backup: BackupRecord) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO backup_record (
                    id, createdAt, originalPath, backupPath, sizeBytes, sha256, integrityResult,
                    sessionCount, messageCount, jobId, restoredAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    backup.id, backup.createdAt, backup.originalPath, backup.backupPath, backup.sizeBytes,
                    backup.sha256, backup.integrityResult, backup.sessionCount, backup.messageCount,
                    backup.jobId, backup.restoredAt,
                ])
        }
    }

    public func backups(limit: Int = 100) throws -> [BackupRecord] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM backup_record ORDER BY createdAt DESC LIMIT ?", arguments: [limit]).map { row in
                BackupRecord(
                    id: row["id"],
                    createdAt: row["createdAt"],
                    originalPath: row["originalPath"],
                    backupPath: row["backupPath"],
                    sizeBytes: row["sizeBytes"],
                    sha256: row["sha256"],
                    integrityResult: row["integrityResult"],
                    sessionCount: row["sessionCount"],
                    messageCount: row["messageCount"],
                    jobId: row["jobId"],
                    restoredAt: row["restoredAt"]
                )
            }
        }
    }

    public func backup(id: String) throws -> BackupRecord? {
        try backups(limit: 1_000).first { $0.id == id }
    }

    private static func mapping(from row: Row) -> SessionMapping? {
        guard let source = AgentKind(rawValue: row["sourceAgent"]),
              let target = AgentKind(rawValue: row["targetAgent"]),
              let status = MappingStatus(rawValue: row["status"]) else { return nil }
        return SessionMapping(
            id: row["id"],
            jobId: row["jobId"],
            sourceAgent: source,
            sourceSessionId: row["sourceSessionId"],
            targetAgent: target,
            targetSessionId: row["targetSessionId"],
            status: status,
            verifiedAt: row["verifiedAt"]
        )
    }
}
