#!/bin/zsh
# Prints the GitHub release notes for VERSION (from CHANGELOG.md) and writes dist/sessiondock.rb,
# a Homebrew cask pinned to this release's zip.
# Usage: scripts/release-notes.sh VERSION
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$1"
REPO="${GITHUB_REPOSITORY:-ridvanaltun/SessionDock}"
OWNER="${REPO%%/*}"
ZIP="dist/SessionDock-$VERSION.zip"
SHA="$(cut -d' ' -f1 "$ZIP.sha256")"

# The CHANGELOG section for this version (until the next "## " heading).
SECTION="$(awk -v v="$VERSION" '
  /^## / { if (found) exit; if (index($0, "## " v " ") == 1 || $0 == "## " v) { found = 1; next } }
  found { print }
' CHANGELOG.md)"
[[ -z "${SECTION//[[:space:]]/}" ]] && SECTION="See CHANGELOG.md."

cat <<EOF
$SECTION

## Install

With [Homebrew](https://brew.sh):

\`\`\`bash
brew tap ${OWNER}/sessiondock https://github.com/$REPO
brew install --cask ${OWNER}/sessiondock/sessiondock
\`\`\`

Or by hand: download \`SessionDock-$VERSION.zip\`, unzip it, and move **SessionDock.app** to \`/Applications\`.

> **This build is ad-hoc signed, not notarized.** macOS blocks its first launch. Open **System Settings → Privacy & Security**,
> find the message about SessionDock and click **Open Anyway** (once), or run \`xattr -dr com.apple.quarantine /Applications/SessionDock.app\`.

**SHA-256** \`SessionDock-$VERSION.zip\`: \`$SHA\`
EOF

# Homebrew cask for this exact release, generated from the template.
sed -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
    packaging/homebrew/sessiondock.rb > dist/sessiondock.rb
