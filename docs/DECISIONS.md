# Decisions

Each entry is dated. A reversal is a new entry that refers to the old one.

## D-01 · Swift Package, not an Xcode project
The app is an SPM package: `SessionDockCore` (logic, no UI), `SessionDock` (SwiftUI), and tests.
`scripts/make-app-bundle.sh` wraps the release executable in an app bundle. This keeps builds, tests and
CI scriptable from the terminal.

## D-02 · Layered architecture with adapters
Features → services → agent adapters and the migration engine → core models and storage. Dependencies point
downward only. Each agent implements discovery, scanning, parsing and storage behind protocols.

## D-03 · Claude Code is streamed, indexed by metadata, and paged on demand
Transcripts reach 32 MB here, and the active session is written while the app runs. Scanning holds one line at
a time. Incremental state stores the byte offset of the last complete line, so a partial line is never consumed.
Messages are not stored in the index. Conversations are read from the source when they are opened.

## D-04 · OpenCode is read-only for inspection, with runtime schema discovery
The store opens read-only and reads the columns that exist. It unions the v2 tables with legacy tables that are
not in v2, by id. Unknown part shapes are kept as raw JSON.

## D-05 · Local index in SQLite with FTS5
The index stores metadata, search text (a capped excerpt per session) and migration history. Projects are derived
from sessions. Preferences are one JSON document.

## D-06 · Migration is built into the app (2026-11-07)
Migration no longer depends on any external tool. The app builds rows from the transcripts and writes OpenCode's
legacy tables in one transaction, after a verified backup. Earlier designs that invoked a command-line tool were
replaced, because the app must run standalone.

## D-07 · Dependencies
The only linked library is GRDB.swift (MIT), for SQLite access. Its notice is in `THIRD_PARTY_NOTICES.md`.
No other third-party software is required at runtime. Optional CLI checks (the OpenCode version and the
OpenCode API visibility check) degrade to "unknown" when the CLI is absent.

## D-08 · Backups use SQLite's online backup API
A plain file copy of a WAL database misses committed pages still in the `-wal` file. Backups are verified with
`quick_check` and a SHA-256, and a backup must pass before any write. Copies are rewritten as a single file with no
`-wal` or `-shm` sidecars.

## D-09 · Planning never writes (2026-11-07)
The plan builds the rows in memory. The destination is not opened for writing, and no snapshot is needed.

## D-10 · The subagent set is explicit
The selection is closed under parent and child. Every planned session is written, and the verifier checks that
nothing else appears.

## D-11 · Historical tool calls are display-only
The inspector renders tool calls and results as read-only cards. Nothing in the app can re-run a tool.

## D-12 · Context copies are explicit and overwrite-protected
Only CLAUDE.md and AGENTS.md can be copied. The copy shows its destination, requires confirmation to overwrite, and
keeps the previous file as a timestamped backup.

## D-13 · Preferences in SQLite
One JSON document in the local database. Missing keys keep their defaults and unknown keys are ignored, so a
version can add or remove a setting without discarding the others. The theme is applied through `NSApp.appearance`,
which reaches every window, the sidebar material and sheets. Only UI state (the last section and session) lives in
`UserDefaults`.

## D-14 · Phase gating
A phase is complete only when its acceptance evidence exists and the tests pass. See docs/PROJECT_STATUS.md.

## D-15 · Claude session identity includes the project folder
The same UUID can appear in two project folders, and subagent transcripts are copied under resumed parents. Ids are
`claude-code:<project-dir>/<uuid>` and `claude-code:<project-dir>/<parent>/<agent>`. `originalId` keeps the bare
value, which the duplicate check uses.

## D-16 · Projects are keyed by working directory across agents
Claude Code and OpenCode sessions in one directory are one project. Projects are derived from sessions at query time.

## D-17 · Subagents group with their parent's project
A subagent transcript lives under its parent's folder. Its own working directory is kept as `agentWorkingDirectory`.

## D-18 · Read-only opens fall back to query_only
A WAL database whose last writer closed it has no `-shm`, so a read-only connection cannot open it. The fallback
opens read-write with `PRAGMA query_only = ON`, so no write is possible and the file's contents are unchanged.

## D-19 · Verification compares roles and tool calls exactly; totals are informational
Assistant turns can be grouped differently from one tool to another, so total message counts are not compared.
User prompts and tool calls are compared exactly.

## D-20 · Settings and configuration values are never displayed
These files can contain credentials. The Context Manager shows keys and value types only.

## D-21 · Verifying existing copies is a read-only action
When copies already exist, the right action is to verify them. `verifyExisting` runs the same validator without any
write, job or backup.

## D-22 · Session rows are written once; existing copies are never rewritten (2026-11-07)
Duplicate detection uses the origin id stored in metadata. A transcript that has grown after its copy was written is
reported as stale, and the copy is left alone.

## D-24 · Licence: MIT (2026-11-07)
The project is released under the MIT licence, with the copyright holder Rıdvan Altun.

## D-23 · Attribution (2026-11-07)
The project and its documentation do not name external tools or projects it learned from. The notice file lists only
linked libraries.
