#!/usr/bin/env bash
# Builds a release executable and wraps it in SessionDock.app.
# Usage: scripts/make-app-bundle.sh [output-directory]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build}"
APP="$OUT/SessionDock.app"

cd "$ROOT"
swift build -c release --product SessionDock

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/SessionDock" "$APP/Contents/MacOS/SessionDock"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

# Ad-hoc signature so the bundle launches on this Mac. Replace with a Developer ID for distribution.
codesign --force --sign - --timestamp=none "$APP" >/dev/null

echo "Built $APP"
