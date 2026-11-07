# Changelog

Release notes are generated from this file. Add changes under **Unreleased**;
`scripts/release.sh X.Y.Z` stamps that section with the version and date.

## Unreleased

### Changed
- Claude Code and OpenCode are shown with their own logos throughout the app, so each session's agent is clear at a glance.
- The app icon follows the macOS 26 icon style and no longer shows a white frame.
- Settings apply as soon as they change, in the standard macOS settings layout. A new agent location is scanned at once.
- SessionDock reopens the section and session that were open last.
- The refresh control sits with the agent status in the sidebar.

### Fixed
- Wide content no longer pushes the sidebar or the columns out of place, at any window size.
- The sidebar no longer disappears when the window is made smaller, and it always opens at full width. A sidebar
  hidden once used to stay hidden or come back too narrow on the next launch.
- The Dark and Light themes now apply to the whole window.
- Saved preferences are kept when a later version adds or removes a setting.
- The writer version reads "native-1" instead of "vnative-1".

## 0.1.1 — 2026-11-07

### New
- SessionDock has its own app icon.

## 0.1.0 — 2026-11-07

### New
- Browse Claude Code and OpenCode sessions on one screen, grouped by project, with subagents nested under their parent.
- Search titles, paths and conversation text.
- Read any conversation in the inspector. Tool calls and results are shown as history and cannot be run.
- Migrate Claude Code sessions into OpenCode with a built-in writer: preview first, verified backup, one-transaction write, then independent verification.
- Check copies that already exist, read-only, including whether OpenCode's own API lists them.
- Context Manager: a read-only view of `CLAUDE.md`, `AGENTS.md`, memory files and rules. Copies happen only on request, with overwrite protection and a backup of the previous file.
