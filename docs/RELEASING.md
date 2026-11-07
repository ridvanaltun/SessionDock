# Releasing

SessionDock ships as a GitHub Release (a zip of `SessionDock.app` with a SHA-256) and as a Homebrew cask.
This repository is its own Homebrew tap, so there is no second repository to maintain.

## What happens on a release
1. `scripts/release.sh X.Y.Z` checks that the tree is clean, `main` matches `origin/main`, the tag is new and
   `CHANGELOG.md` has notes under **Unreleased**. It then sets the version, stamps the changelog, runs the tests,
   commits `Release vX.Y.Z`, tags it and pushes both.
2. The tag starts `.github/workflows/release.yml`. It runs the CI workflow in full (build, tests, universal bundle,
   smoke test). Nothing is published unless it passes.
3. It builds the zip and checksum with `scripts/make-app-bundle.sh dist`, writes the release notes and the cask
   with `scripts/release-notes.sh`, and publishes the GitHub Release.
4. For a stable version it commits the cask to `Casks/sessiondock.rb` on `main`.

## Cutting a release
```sh
# 1. Describe the change under "## Unreleased" in CHANGELOG.md, then commit and push main.
# 2. Cut the release (use --no-push to stop before the push).
scripts/release.sh 0.1.0
# 3. Follow the workflow.
gh run watch "$(gh run list --workflow Release --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Check the result on a Mac:
```sh
brew tap ridvanaltun/sessiondock https://github.com/ridvanaltun/SessionDock
brew install --cask ridvanaltun/sessiondock/sessiondock
```

## Versions and prereleases
- The version lives in `Sources/SessionDockCore/Core/Utilities/AppVersion.swift`. The tag must match it.
- A version with a suffix, such as `0.2.0-beta.1`, is published as a prerelease. Its cask is not committed to `main`,
  so Homebrew keeps offering the last stable version.
- A manual run of the Release workflow (workflow_dispatch) publishes a draft unless `draft` is unchecked.

## Signing and notarization
Builds are ad-hoc signed. They are not notarized, because only "Apple Development" certificates are available.
The release notes and the cask caveats tell users how to open the app the first time.

To notarize later, add a Developer ID Application certificate and pass its identity as `SIGN_IDENTITY` to
`scripts/make-app-bundle.sh`. That enables the hardened runtime. Notarization then needs the Apple ID, team ID and
an app-specific password as repository secrets, and a step that submits the zip with `notarytool`.

## App icon
The logo source is `design/logo/sessiondock-icon.png` (1024×1024, with its SVG beside it). `scripts/make-icon.sh`
turns it into `Resources/AppIcon.icns`; run it after changing the logo and commit the result.
`scripts/make-app-bundle.sh` copies the icon into the bundle and sets `CFBundleIconFile`.
