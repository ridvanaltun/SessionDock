# AGENTS.md — SessionDock

Guidance for coding agents working in this repository.

## What this is
SessionDock is a native macOS app (SwiftUI, macOS 14+, Swift 6). It indexes Claude Code and OpenCode
sessions, inspects them read-only, and migrates Claude Code sessions into OpenCode with its own built-in writer.
It needs no other tool at runtime.

## Layout
- `Sources/SessionDockCore/`: all logic, no UI. `Core/` (models, database, utilities), `Agents/` (per-agent discovery and reading), `Migration/` (plan, engine, writer, backup, validation), `Context/`.
- `Sources/SessionDock/`: SwiftUI app. `App/`, `DesignSystem/`, `Features/<Feature>/` (view and view model together).
- `Tests/SessionDockCoreTests/`: XCTest. Real-data tests are opt-in (see docs/DEVELOPMENT.md).
- `docs/`: keep current. `design/`: logo candidates, not used until approved.

## Rules
1. Never write to Claude Code transcripts. Write to the OpenCode database only in `MigrationEngine.execute`, after a verified backup, in one transaction.
2. Planning and inspection use read-only connections (`ReadOnlyDatabase`). Do not add DDL or write pragmas to those paths.
3. Migration success is decided by `MigrationValidator`, which reads the destination. Never decide it from process output.
4. Do not name external tools or projects in code, comments, docs or UI. Attribution is limited to the linked-library notice in `THIRD_PARTY_NOTICES.md`.
5. Settings and configuration files are shown as key and type outlines only. Their values can be credentials.
6. Keep SwiftUI views small. Business logic belongs in Core or in the view models.
7. No force unwraps. Swift 6 strict concurrency must stay warning-free.
8. Run `swift test` before reporting work as done.

## Commands
- Build: `swift build`
- Test: `swift test`. Real-data tests: `SESSIONDOCK_REAL_TESTS=1 swift test --filter RealDataTests`
- App bundle: `scripts/make-app-bundle.sh` → `build/SessionDock.app` (universal, plus zip and checksum)
- Smoke test of the bundle on invented data: `scripts/smoke-test.sh`. Demo home: `scripts/demo-data.sh DIR`, then `SESSIONDOCK_HOME=DIR`.
- Release: see `docs/RELEASING.md`. Never push or tag without the user's explicit go-ahead.
