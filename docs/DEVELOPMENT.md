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
scripts/make-app-bundle.sh                   # universal release build → build/SessionDock.app and a zip
scripts/smoke-test.sh                        # launches the bundle on the demo home and checks it indexes
scripts/demo-data.sh DIRECTORY               # writes a fake home with invented sessions
```

## Isolated runs with `SESSIONDOCK_HOME`
Setting `SESSIONDOCK_HOME` makes the app use that directory as the home. It also ignores the Claude Code and
OpenCode location variables, so nothing from the real machine is read. Use it for demos, screenshots and smoke tests:

```sh
scripts/demo-data.sh /tmp/sessiondock-demo
SESSIONDOCK_HOME=/tmp/sessiondock-demo build/SessionDock.app/Contents/MacOS/SessionDock
```

The demo data is invented: two projects, a subagent under its parent, and an OpenCode session. Use it for
screenshots, so that no real conversation titles appear in the repository or in the README.

## Test fixtures
`TestSupport.swift` builds a Claude project (a main session, a subagent, a malformed line, a partial line) and an
OpenCode database with both table generations. `NativeWriterTests.swift` covers the mapping rules and the
transactional write. `MigrationEngineTests.swift` covers planning, execution, staleness, duplicates and orphans.

## Continuous integration
- `.github/workflows/ci.yml` runs on every push to `main` and on pull requests. It builds, tests, creates the
  universal bundle and runs `scripts/smoke-test.sh`.
- `.github/workflows/release.yml` runs on version tags. It reuses CI, then publishes. See [RELEASING.md](RELEASING.md).

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
- Screenshots: capture by window ID (`screencapture -o -l<id>`), not by screen region. Other windows can cover the
  region, and personal content can appear in the capture.
