#!/usr/bin/env bash
# Launches the bundled app against a generated demo home and waits until it has indexed the demo sessions.
# The real home directory is never read: SESSIONDOCK_HOME isolates the app.
# Usage: scripts/smoke-test.sh [path-to-SessionDock.app]   (default: build/SessionDock.app)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/SessionDock.app}"
EXPECTED_SESSIONS=5
WORK="$(mktemp -d)"
HOME_DIR="$WORK/home"
DB="$HOME_DIR/Library/Application Support/SessionDock/sessiondock.sqlite"
PID=""

cleanup() {
  if [[ -n "$PID" ]]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

"$ROOT/scripts/demo-data.sh" "$HOME_DIR" > /dev/null
SESSIONDOCK_HOME="$HOME_DIR" "$APP/Contents/MacOS/SessionDock" > "$WORK/app.log" 2>&1 &
PID=$!

count=0
for _ in $(seq 1 120); do
  count="$(sqlite3 "$DB" "SELECT count(*) FROM session" 2>/dev/null || echo 0)"
  if (( count >= EXPECTED_SESSIONS )); then
    echo "✓ the bundled app indexed $count sessions from the demo home"
    exit 0
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "✗ the app exited before it indexed the demo home"
    cat "$WORK/app.log"
    exit 1
  fi
  sleep 1
done
echo "✗ only $count of $EXPECTED_SESSIONS sessions were indexed within 120 s"
exit 1
