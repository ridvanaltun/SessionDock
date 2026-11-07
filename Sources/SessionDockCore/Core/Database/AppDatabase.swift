import Foundation
import GRDB

/// The local SessionDock index. Holds metadata, search, migration history, and preferences.
/// It never holds full conversation bodies; those are read from the source on demand.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func open(paths: AppPaths) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.label = "sessiondock-index"
        let pool = try DatabasePool(path: paths.indexDatabase.path, configuration: configuration)
        return try AppDatabase(writer: pool)
    }

    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-core") { db in
            try db.create(table: "installation") { table in
                table.primaryKey("agent", .text)
                table.column("json", .text).notNull()
            }

            try db.create(table: "project") { table in
                table.primaryKey("id", .text)
                table.column("agent", .text).notNull().indexed()
                table.column("path", .text).notNull()
                table.column("name", .text).notNull()
                table.column("sessionCount", .integer).notNull()
                table.column("subagentCount", .integer).notNull()
                table.column("lastActivityAt", .datetime)
                table.column("pathIsInferred", .boolean).notNull()
            }

            try db.create(table: "session") { table in
                table.primaryKey("id", .text)
                table.column("agent", .text).notNull().indexed()
                table.column("originalId", .text).notNull()
                table.column("projectId", .text).notNull().indexed()
                table.column("projectPath", .text).notNull()
                table.column("parentSessionId", .text).indexed()
                table.column("isSubagent", .boolean).notNull()
                table.column("subagentType", .text)
                table.column("title", .text).notNull()
                table.column("createdAt", .datetime)
                table.column("updatedAt", .datetime).indexed()
                table.column("messageCount", .integer).notNull()
                table.column("toolCallCount", .integer).notNull()
                table.column("model", .text)
                table.column("sourcePath", .text)
                table.column("metadataJSON", .text).notNull()
                table.column("indexedAt", .datetime).notNull()
            }

            try db.create(table: "source_state") { table in
                table.primaryKey("sourcePath", .text)
                table.column("agent", .text).notNull().indexed()
                table.column("sessionId", .text).notNull()
                table.column("size", .integer).notNull()
                table.column("modifiedAt", .datetime).notNull()
                table.column("headDigest", .text).notNull()
                table.column("offset", .integer).notNull()
                table.column("stateJSON", .text).notNull()
            }

            try db.execute(sql: """
                CREATE VIRTUAL TABLE session_search USING fts5(
                    sessionId UNINDEXED, title, projectPath, body,
                    tokenize = 'unicode61 remove_diacritics 2'
                )
                """)
        }

        migrator.registerMigration("v1-migrations") { db in
            try db.create(table: "migration_job") { table in
                table.primaryKey("id", .text)
                table.column("createdAt", .datetime).notNull().indexed()
                table.column("finishedAt", .datetime)
                table.column("status", .text).notNull()
                table.column("selectionJSON", .text).notNull()
                table.column("planId", .text).notNull()
                table.column("sessionCount", .integer).notNull()
                table.column("writerVersion", .text)
                table.column("exitCode", .integer)
                table.column("operation", .text).notNull()
                table.column("stdoutExcerpt", .text).notNull()
                table.column("stderrExcerpt", .text).notNull()
                table.column("backupId", .text)
                table.column("summary", .text).notNull()
            }

            try db.create(table: "session_mapping") { table in
                table.primaryKey("id", .text)
                table.column("jobId", .text).notNull().indexed().references("migration_job", onDelete: .cascade)
                table.column("sourceAgent", .text).notNull()
                table.column("sourceSessionId", .text).notNull().indexed()
                table.column("targetAgent", .text).notNull()
                table.column("targetSessionId", .text)
                table.column("status", .text).notNull()
                table.column("verifiedAt", .datetime)
            }

            try db.create(table: "backup_record") { table in
                table.primaryKey("id", .text)
                table.column("createdAt", .datetime).notNull().indexed()
                table.column("originalPath", .text).notNull()
                table.column("backupPath", .text).notNull()
                table.column("sizeBytes", .integer).notNull()
                table.column("sha256", .text).notNull()
                table.column("integrityResult", .text).notNull()
                table.column("sessionCount", .integer).notNull()
                table.column("messageCount", .integer).notNull()
                table.column("jobId", .text)
                table.column("restoredAt", .datetime)
            }

            try db.create(table: "validation_result") { table in
                table.primaryKey("id", .text)
                table.column("jobId", .text).notNull().indexed().references("migration_job", onDelete: .cascade)
                table.column("check", .text).notNull()
                table.column("severity", .text).notNull()
                table.column("passed", .boolean).notNull()
                table.column("detail", .text).notNull()
            }

            try db.create(table: "preference") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }
        }
        return migrator
    }
}
