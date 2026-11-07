# Changelog

Release notes are generated from this file. Add changes under **Unreleased**;
`scripts/release.sh X.Y.Z` stamps that section with the version and date.

## Unreleased

## 0.1.0 — 2026-11-07

### New
- Browse Claude Code and OpenCode sessions on one screen, grouped by project, with subagents nested under their parent.
- Search titles, paths and conversation text.
- Read any conversation in the inspector. Tool calls and results are shown as history and cannot be run.
- Migrate Claude Code sessions into OpenCode with a built-in writer: preview first, verified backup, one-transaction write, then independent verification.
- Check copies that already exist, read-only, including whether OpenCode's own API lists them.
- Context Manager: a read-only view of `CLAUDE.md`, `AGENTS.md`, memory files and rules. Copies happen only on request, with overwrite protection and a backup of the previous file.
