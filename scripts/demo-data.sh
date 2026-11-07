#!/bin/zsh
# Creates a fake home directory with sample Claude Code transcripts and an OpenCode database, so that
# SessionDock can be demonstrated, screenshotted and smoke-tested without any personal data.
#
# Usage: scripts/demo-data.sh DIRECTORY
# Then:  SESSIONDOCK_HOME=DIRECTORY open dist/SessionDock.app
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:?usage: scripts/demo-data.sh DIRECTORY}"
rm -rf "$TARGET"
mkdir -p "$TARGET/.claude/projects" "$TARGET/.local/share/opencode"
python3 scripts/demo-data.py "$TARGET"
sqlite3 "$TARGET/.local/share/opencode/opencode.db" < scripts/demo-opencode.sql
echo "demo home ready: $TARGET"
