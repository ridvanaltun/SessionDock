# Project status

Last updated: 2026-11-07.

## Phases
| Phase | Status | Evidence |
|---|---|---|
| 1 Foundation | Complete | SPM package, GRDB index and migrations, navigation, design system, discovery, documentation |
| 2 Session discovery | Complete | Streaming JSONL scanner with resumable state; read-only OpenCode store with runtime schema profile; FTS5 search; incremental indexing. Real corpus: 699 Claude and 82 OpenCode sessions indexed |
| 3 Explorer | Complete (screens checked) | Dashboard, Projects, Sessions (search, filters, project grouping, subagent nesting), Inspector (paged, tool calls display-only) |
| 4 Migration | Complete for Claude → OpenCode | Built-in writer; in-memory plan; online backup; one-transaction write; independent verification; mapping; restore. Rehearsal on a copy of the real data passes |
| 5 Context | Complete | Discovery, read-only preview, explicit overwrite-protected copy, settings values hidden |
| 6 Quality | Partial | See below |

## Acceptance scenario (Chronomap)
- **Discovery:** the five Chronomap transcripts are found, with relationships: two main sessions and three subagents.
- **Existing copies:** the five sessions already exist in OpenCode from an earlier write. A new write is correctly
  a no-op. Verification of those copies, read-only against the live database, passes every error-level check.
  OpenCode's API lists all five.
- **Full write:** rehearsed on a copy of the live database with the built-in writer. Five of five verified. A second
  plan finds nothing to write.
- **Parity with the existing copies:** user prompts (35) and tool calls (356) match exactly.
- **Not verified:** a visual check of the OpenCode GUI. OpenCode projects legacy rows into its v2 store when it runs,
  so the rows should appear there after OpenCode restarts. This has not been checked by eye.

## Known limits
- Existing copies are not updated when their transcript grows.
- Subagents whose parent already exists elsewhere are blocked.
- Duplicate ids across the source set are blocked.
- System and attachment records are reported, not written.
- Only Claude Code → OpenCode. The reverse direction is not implemented.
- The first scan of a very large history takes about 100 s.

## Phase 6 remaining
- Interrupted-write tests (kill mid-transaction).
- Accessibility pass. VoiceOver labels are partial.
- Developer ID signing and notarisation. The bundle is ad-hoc signed.

## Tests
`swift test`: 71 tests, 0 failures. Five opt-in real-data tests are skipped by default. Real-data and rehearsal tests pass when enabled.
