# Data model

## Normalised session model (Core/Models)
- **AgentKind**: `claudeCode`, `openCode`.
- **SessionSummary**: `id` (unique), `agent`, `originalId`, `projectId`, `projectPath`, `parentSessionId`, `isSubagent`, `subagentType`, `title`, `createdAt`, `updatedAt`, `messageCount`, `toolCallCount`, `model`, `sourcePath`, `metadata` (every source field kept as JSON), `searchText` (capped excerpt for search only).
- **Ids**
  - Claude main: `claude-code:<project-dir>/<uuid>`
  - Claude subagent: `claude-code:<project-dir>/<parent-uuid>/<agent-id>`
  - OpenCode: `opencode:<session-id>`
  - `originalId` is the bare value. The duplicate check uses it.
- **Project**: derived from sessions, grouped by `projectPath` across agents. Key: `project:<sha256(path)[0..16]>`.
- **Message**: `id`, `sessionId`, `ordinal`, `role`, `timestamp`, `model`, `contentParts`, `metadata`.
- **ContentPart**: `text`, `reasoning`, `toolCall`, `toolResult`, `fileReference`, `unknown(kind, raw)`.
- **SourceIssue**: a malformed record, with its byte offset and a preview.

## OpenCode legacy rows written by the migration
| Table | Columns written |
|---|---|
| `project` | id (SHA-1 of path), worktree, name, times, `sandboxes = []` |
| `session` | id, project_id, parent_id, slug, directory, path `''`, title, version `claude-code-migrated`, metadata JSON, agent `build`, times |
| `message` | id, session_id, times, data JSON (role, time, parentID for assistant turns, tokens, model) |
| `part` | id, message_id, session_id, times, data JSON (text, reasoning, tool, step-start, step-finish) |

The metadata key `claude_code_origin` marks every migrated session.

## Local index (GRDB, `~/Library/Application Support/SessionDock/sessiondock.sqlite`)
| Table | Purpose |
|---|---|
| `installation` | Last discovery result per agent (JSON) |
| `session` | Indexed metadata. No conversation bodies |
| `session_search` (FTS5) | Title, path and capped text excerpt |
| `source_state` | Per-file scan state for incremental indexing |
| `migration_job` | Runs: status, operation summary, writer version, output excerpts |
| `session_mapping` | Source session → OpenCode session, per job |
| `backup_record` | Backup path, SHA-256, integrity result, counts |
| `validation_result` | Each check's severity, outcome and detail |
| `preference` | Preferences as one JSON document |
| `project` | Legacy. No longer written; projects are derived from `session` |

Foreign keys cascade from `migration_job`. Job rows use an upsert, never `INSERT OR REPLACE`, because REPLACE would
delete the child history. The index is a cache: it can be rebuilt from the source files at any time.
