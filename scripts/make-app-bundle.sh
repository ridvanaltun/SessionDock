#!/usr/bin/env bash
# Builds SessionDock.app (universal: Apple silicon and Intel), then packages it as a zip with a SHA-256.
# Usage: scripts/make-app-bundle.sh [output-directory]   (default: build/)
#
# Environment:
#   SIGN_IDENTITY  codesign identity. Default "-" (ad-hoc). Without a Developer ID certificate the app is
#                  not notarized, so macOS asks once before the first launch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build}"
APP="$OUT/SessionDock.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ARCHS=(--arch arm64 --arch x86_64)
VERSION="$(sed -n 's/.*public static let current = "\(.*\)".*/\1/p' "$ROOT/Sources/SessionDockCore/Core/Utilities/AppVersion.swift")"
[[ -n "$VERSION" ]] || { echo "could not read the version from AppVersion.swift" >&2; exit 1; }

cd "$ROOT"
echo "▸ Building SessionDock $VERSION (universal)"
swift build -c release "${ARCHS[@]}" --product SessionDock
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$OUT" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SessionDock" "$APP/Contents/MacOS/SessionDock"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

echo "▸ Signing ($SIGN_IDENTITY)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - --timestamp=none "$APP"
else
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "▸ Packaging"
# File names only, so `shasum -c` works in the folder the user downloads to.
( cd "$OUT" && rm -f "SessionDock-$VERSION.zip" && ditto -c -k --keepParent SessionDock.app "SessionDock-$VERSION.zip" )
( cd "$OUT" && shasum -a 256 "SessionDock-$VERSION.zip" > "SessionDock-$VERSION.zip.sha256" )
echo "✓ $APP and $OUT/SessionDock-$VERSION.zip"
