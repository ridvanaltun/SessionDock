# SessionDock

**SessionDock** is a native macOS app for AI coding sessions. It finds your Claude Code and OpenCode
sessions, lets you browse and search them, and moves Claude Code sessions into OpenCode safely.

It is local-first. It has no account, no telemetry, and no network dependency. It reads your
files and databases on your Mac and writes only when you confirm a migration.

## Features

- **Discovery.** Finds Claude Code (`~/.claude/projects`) and OpenCode (`opencode.db`), including
  custom locations set in Settings.
- **Explorer.** Groups sessions by project across both agents, nests subagents under their parent
  sessions, and searches titles, paths and conversation text.
- **Inspector.** Shows the conversation read-only: user and assistant messages, reasoning, tool calls
  and results, file references and raw metadata. Tool calls are displayed as history and cannot be run.
- **Migration.** Select sessions, preview exactly what will be written, back up the OpenCode database,
  write in one transaction, then verify the result by reading the database. Existing copies are detected
  and left alone.
- **Verification.** Checks copies that already exist, read-only, including whether OpenCode's own
  API lists them.
- **Context.** Read-only view of `CLAUDE.md`, `AGENTS.md`, memory files and rules. Copies happen only
  on request, with overwrite protection and a backup of the previous file. Settings values are never shown.

## Requirements

- macOS 14 or later
- Xcode 16 or later (Swift 6 toolchain) to build from source
- Claude Code and/or OpenCode, if you want to index their sessions

SessionDock does not need any other tool installed.

## Build and run

```sh
swift build
swift test
scripts/make-app-bundle.sh      # creates build/SessionDock.app
open build/SessionDock.app
```

## How migration stays safe

1. **Preview writes nothing.** The plan is computed in memory from the transcripts and the destination.
2. **Stale plans are refused.** If the database or a transcript changed after planning, you plan again.
3. **Backup first.** A consistent copy is made with SQLite's online-backup API and checked before any write.
4. **One transaction.** All rows are written together. A failure rolls everything back.
5. **Verification reads the database.** Success is decided by independent checks, not by the process.
6. **Originals are untouched.** Claude Code transcripts are checksummed before and after.

## Project layout

```
Sources/SessionDockCore/   logic: models, index database, agents, migration, context
Sources/SessionDock/       SwiftUI app: app shell, design system, feature screens
Tests/SessionDockCoreTests fixtures and tests (real-data tests are opt-in)
docs/                      architecture, data model, migration, development, decisions, status
scripts/                   app bundle packaging
```

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Data model](docs/DATA_MODEL.md)
- [Migration](docs/MIGRATION.md)
- [Development](docs/DEVELOPMENT.md)
- [Decisions](docs/DECISIONS.md)
- [Project status](docs/PROJECT_STATUS.md)
- [Third-party notices](THIRD_PARTY_NOTICES.md)

## Licence

No licence has been chosen yet.
