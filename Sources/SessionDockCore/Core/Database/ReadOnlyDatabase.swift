import Foundation
import GRDB

/// Opens SQLite databases for inspection without writing to them.
///
/// The first attempt is a true read-only connection. SQLite cannot open a WAL-mode database
/// read-only when its `-shm` file is missing, which happens after the last writer closes it. In that
/// case the database is opened read-write with `PRAGMA query_only = ON`, which rejects every write
/// at the SQL level. No content is changed by this path.
public enum ReadOnlyDatabase {
    public static func open(at url: URL) throws -> DatabaseQueue {
        var readOnly = Configuration()
        readOnly.readonly = true
        readOnly.label = "readonly:\(url.lastPathComponent)"
        readOnly.busyMode = .timeout(5)
        do {
            return try DatabaseQueue(path: url.path, configuration: readOnly)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CANTOPEN {
            var queryOnly = Configuration()
            queryOnly.label = "query-only:\(url.lastPathComponent)"
            queryOnly.busyMode = .timeout(5)
            queryOnly.prepareDatabase { db in
                try db.execute(sql: "PRAGMA query_only = ON")
            }
            return try DatabaseQueue(path: url.path, configuration: queryOnly)
        }
    }
}
