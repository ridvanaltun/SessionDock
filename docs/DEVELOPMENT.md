# Development

## Requirements
Xcode 16 or later (Swift 6 toolchain). macOS 14 or later.

## Commands
```sh
swift build                                  # debug build of all targets
swift test                                   # unit and integration tests with fixtures
SESSIONDOCK_REAL_TESTS=1 swift test --filter RealDataTests
    # read-only checks against this Mac's ~/.claude and OpenCode database
SESSIONDOCK_REAL_TESTS=1 SESSIONDOCK_REHEARSE=1 SESSIONDOCK_REPORT_PATH=/tmp/rehearsal.txt \
    swift test --filter testRehearsalOfFullMigrationOnSnapshot
    # full migration on a COPY of the live database. The live file is never written.
scripts/make-app-bundle.sh                   # release build → build/SessionDock.app (ad-hoc signed)
```

## Test fixtures
`TestSupport.swift` builds a Claude project (a main session, a subagent, a malformed line, a partial line) and an
OpenCode database with both table generations. `NativeWriterTests.swift` covers the mapping rules and the
transactional write. `MigrationEngineTests.swift` covers planning, execution, staleness, duplicates and orphans.

## Performance (release build, this Mac)
- Full scan of 739 transcripts (6.4 GB): about 100 s on the first run, peak memory about 640 MB.
  Later refreshes read only changed files.
- Reader alone: 32 MB in about 20 ms. JSON decoding dominates. A byte-level prefilter for non-conversation records
  is the next optimisation.
- Measure in release. Debug builds are roughly ten times slower.

## Gotchas
- `FileManager.contentsOfDirectory` refuses symlinked directories. Resolve links first.
- A WAL database closed by its last writer has no `-shm`, and a read-only connection cannot open it. Use `ReadOnlyDatabase`.
- A default GRDB connection can run `PRAGMA quick_check`, which takes a shared lock. Keep planning reads short.
