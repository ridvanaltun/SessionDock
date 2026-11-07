# Migration

SessionDock migrates Claude Code sessions into OpenCode with a built-in writer. It needs no other
tool. Nothing runs outside the app bundle, and the writer uses the local SQLite databases directly.

## Scope
- Direction: Claude Code → OpenCode. Other directions are not implemented.
- Unit of work: a session, a subagent, or both. Selecting a subagent also includes its parent.
  Selecting a parent includes all of its subagents. The preview shows the exact set.

## Pipeline
```
select ──► plan (read-only) ──► confirm ──► backup ──► write (one transaction) ──► verify ──► record
             │                                 │                                    │
             │  rows built in memory           │  SQLite online backup              │  reads the database
             │  destination never written      │  + quick_check + SHA-256           │  directly, never the
             │                                 │                                    │  process result
```

## Planning (never writes)
- Reads the index and the destination. Builds every row in memory with the same mapping used for writing.
- Shows: sessions, messages, parts, tool calls, projects, and any records with no OpenCode equivalent.
- Computes a signature of the destination rows and a SHA-256 of each source transcript.
- Blocks when: the destination is missing or has no legacy tables; a session id is duplicated in
  the source; a subagent's parent already exists elsewhere (it cannot be linked correctly); a
  selected session is unknown.
- Warns when: OpenCode is running; an existing copy is older than its transcript.

## Execution
1. Refuses if the destination signature changed since planning, or any transcript changed.
2. Takes a verified backup first. A backup failure stops the run with nothing written.
3. Rebuilds the rows from the transcripts and writes them in a single transaction. Any failure rolls
   the whole write back.
4. Verifies by reading the destination (see below) and records the job, mappings, and results.

## Row mapping (Claude Code → OpenCode legacy tables)
| Claude Code | OpenCode |
|---|---|
| Working directory of the session | `project` (id = SHA-1 of the path, 40 hex) and `session.directory` |
| Session | `session` (id `ses_` + 26 characters derived from the origin id) |
| Subagent | `session.parent_id` pointing at the parent's OpenCode id |
| User record with text | `message` (role user) + `part` (type text) |
| Assistant records sharing one `message.id` | one `message` (role assistant), `parentID` = the preceding user message |
| `thinking` block | `part` type reasoning |
| `text` block | `part` type text |
| `tool_use` | `part` type tool, with input |
| `tool_result` in a later user record | attached to its tool part as `state.output` (status `error` when `is_error`) |
| Usage counts | `tokens` on the assistant message and step-finish part |
| System and attachment records | not written; counted and reported as unmapped |

Identifiers are derived from the origin id, so the same transcript always maps to the same ids.
The origin id is stored as `metadata.claude_code_origin`. The same key identifies existing copies and
prevents duplicates.

Renderer requirements are satisfied while writing: every assistant turn is preceded by `step-start`
(with a time) and closed by `step-finish` (with the native fields), and every tool state has a time block.

## Verification (reads the destination, never the process result)
| Check | Severity | Meaning |
|---|---|---|
| `database.integrity` | error | `PRAGMA quick_check` is ok |
| `source.unchanged` | error | transcripts still match the planned SHA-256 |
| `sessions.present` | error | every planned session exists with its origin |
| `sessions.noUnexpected` | error | no session appeared that was not planned |
| `subagents.parentLink` | error | each subagent's `parent_id` is its parent's id |
| `messages.present` | error | migrated sessions contain messages |
| `messages.userPrompts` | warning | user rows equal the source prompt count |
| `toolCalls.parity` | warning | tool parts equal the source tool calls |
| `alreadyMigrated.untouched` | error | existing copies keep their message counts |
| `openCode.v2Projection` | warning | rows also appear in OpenCode's v2 store (OpenCode projects them when it runs) |
| `openCode.visible` | warning | OpenCode's own API lists the sessions, when the service is running |
| `records.unmapped` | warning | records with no OpenCode equivalent (reported, not dropped) |

Outcome: any failed error check → `failedVerification`. Only warnings → `succeededWithWarnings`.
Otherwise `succeeded`.

## Reference data
The row shapes were checked against OpenCode 2.1.4 databases on this Mac, including sessions written by an
earlier writer. The counts of user prompts and tool calls for the Chronomap project match those
existing copies exactly (35 prompts and 356 tool calls across its five sessions). Total message counts differ
by design, because assistant turns are grouped per response.

## Restore
Restore replaces the live database with a chosen backup. It is refused while OpenCode is running.
A pre-restore copy of the current state is always taken first.

## Known limits
- Existing copies are never updated. Newer messages in Claude Code are not added to an earlier copy.
- Subagents whose parent already exists elsewhere are blocked.
- Transcript records of kind system and attachment are not written.
- OpenCode's v2 store is written by OpenCode itself, not by SessionDock.
