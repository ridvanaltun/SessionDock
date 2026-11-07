# CLAUDE.md

Read [AGENTS.md](AGENTS.md) first. Short version:

- Core logic lives in `Sources/SessionDockCore`. The UI lives in `Sources/SessionDock`.
- Read-only everywhere except `MigrationEngine.execute`, which backs up, writes in one transaction, and verifies.
- Migration success comes from `MigrationValidator`, never from process output.
- Do not mention external tools or projects in code, comments or docs.
- Run `swift test` before you report work as done.
