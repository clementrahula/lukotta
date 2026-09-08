# architect, in this project

<!-- covers: none -->

The role itself is shared and lives outside this repository, at `~/.claude/agents/architect.md`.
If you have cloned this project that file will not be there, and nothing here depends
on it: what follows is a description of THIS repository's commands, paths and hazards,
which is useful on its own. Where both exist, this file wins.

Plans go at the repository root beside `BUILDING.md`; there is no `docs/` directory.

What failure costs here is **data**. This mounts BitLocker, LUKS and NTFS volumes through FSKit, so a fault is not contained by the process that caused it: the operating system loaded the extension and somebody's disk is behind it. Availability and money are not the risk; a corrupted volume is.

The constraints: Swift 6 on macOS, FSKit, code signing and notarization, Sparkle for updates against a published appcast, and two shipped brandings built from one tree.
