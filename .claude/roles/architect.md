# architect, in this project

<!-- covers: none -->

The role itself is shared: `~/.claude/agents/architect.md`, from the workflow repository.
This file is the part that is only true here, and it wins where the two disagree.

Plans go at the repository root beside `BUILDING.md`; there is no `docs/` directory.

What failure costs here is **data**. This mounts BitLocker, LUKS and NTFS volumes through FSKit, so a fault is not contained by the process that caused it: the operating system loaded the extension and somebody's disk is behind it. Availability and money are not the risk; a corrupted volume is.

The constraints: Swift 6 on macOS, FSKit, code signing and notarization, Sparkle for updates against a published appcast, and two shipped brandings built from one tree.
