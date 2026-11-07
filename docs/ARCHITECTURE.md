# Architecture

## Layers (dependencies point down only)
```
Features (SwiftUI views and @MainActor @Observable view models)
   │  AppEnvironment → AppServices
   ▼
Services: IndexingService (actor), MigrationEngine (actor), ContextService
   │
   ├── Agents/   AgentAdapter = discovery + SessionScanner + SessionParser + SessionStorage
   │      ClaudeCode/  streaming JSONL scanner, paged parser, read-only storage
   │      OpenCode/    read-only SQLite store with a runtime schema profile
   └── Migration/
          Native/     OpenCodeLegacyWriter: transcript → rows (pure), rows → database (one transaction)
          Engine/     plan, execute, verifyExisting, restore
          Validation/ MigrationValidator, optional OpenCode visibility check
          Backup/     BackupManager (online backup, checksums, retention)
   │
   ▼
Core: Sendable models, GRDB index (AppDatabase and repositories), utilities
```

## Key components
- **IndexingService** serialises refreshes. Each agent's index is replaced in one transaction. Progress is reported per agent.
- **ClaudeCodeScanner** turns each transcript into a job. Jobs run concurrently, up to 8 at a time. Unchanged files are reused from persisted `SourceScanState`. Appended files resume at the last complete line.
- **ClaudeCodeParser** pages messages by index and caches byte checkpoints every 200 messages.
- **OpenCodeStore** reads the v2 tables and the legacy tables and unions them by id. Columns come from `PRAGMA table_info`.
- **OpenCodeLegacyWriter** maps messages to rows in memory, so preview and execution share one mapping. `apply` writes all rows in one transaction.
- **MigrationEngine** holds the safety rules: stale-plan refusal, backup before write, verification, recording, explicit restore.
- **MigrationValidator** reads the destination directly and runs the checks listed in docs/MIGRATION.md.
- **ReadOnlyDatabase** opens read-only. If SQLite refuses a WAL database with no `-shm`, it falls back to read-write with `PRAGMA query_only = ON`.

## Concurrency
- Swift 6 language mode. Models are Sendable. Repositories are Sendable structs over GRDB's pool.
- Long work runs in structured tasks. Chunk reads and per-line work run in autorelease pools, because Foundation
  objects otherwise accumulate on background threads during multi-gigabyte scans.

## Extending to another agent
Add a folder under `Agents/`, implement `AgentAdapter`, register it in `AppEnvironment.bootstrap`, and add an
`AgentKind` case. Features and migration do not switch on storage details.
