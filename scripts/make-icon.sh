#!/bin/zsh
# Compiles the app icon from design/logo/AppIcon.icon (an Icon Composer document) into
# Resources/Assets.car (macOS 26 and later, which mask and render the icon themselves) and
# Resources/AppIcon.icns (earlier macOS versions). Needs Xcode 26 or later for actool.
# Run it again whenever the logo changes, and commit the results.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="$PWD/design/logo/AppIcon.icon"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun actool "$SOURCE" \
  --compile "$WORK" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$WORK/partial.plist" > /dev/null

cp "$WORK/Assets.car" Resources/Assets.car
cp "$WORK/AppIcon.icns" Resources/AppIcon.icns

# A flat preview of the rendered icon, for documents and reviews.
iconutil -c iconset Resources/AppIcon.icns -o "$WORK/AppIcon.iconset"
cp "$WORK/AppIcon.iconset/icon_128x128@2x.png" design/logo/preview.png
echo "✓ Resources/Assets.car, Resources/AppIcon.icns and design/logo/preview.png"
