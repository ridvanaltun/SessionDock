#!/bin/zsh
# Builds Resources/AppIcon.icns from the chosen logo (design/logo/sessiondock-icon.png, 1024×1024).
# Run it again whenever the logo changes, and commit the result.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="design/logo/sessiondock-icon.png"
OUTPUT="Resources/AppIcon.icns"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z $size $size "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
  double=$((size * 2))
  sips -z $double $double "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
done

iconutil -c icns "$ICONSET" -o "$OUTPUT"
rm -rf "$(dirname "$ICONSET")"
echo "✓ $OUTPUT"
