# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# shellcheck shell=bash
# Sourced rather than run, so it carries no shebang and shellcheck has to be
# told which shell it is reading.
#
# Put everything temporary this project makes inside one directory it owns.
#
# Sourced, not run. One line, first thing, in every script here that makes a
# temporary anything:
#
#     . "$(dirname "${BASH_SOURCE[0]}")/tmp-root.sh"
#
# WHY
#
# $TMPDIR is shared with the whole Mac, and this project was writing straight
# into it from about a hundred places: every harness's `mktemp -d`, ship.sh's
# copy of itself, the screen dumps, the log watchers, and -- the largest count
# by far -- SwiftPM, which leaves a `TemporaryDirectory.XXXXXX` behind on every
# single `swift build` and never takes one back.
#
# Counted on 2026-09-08: 14,328 of SwiftPM's, 245 harness workspaces holding
# 1.7 GB, and 18 copies of ship.sh. None belonged to anything running.
#
# Traps were the previous answer and they cannot be the answer. A trap does not
# run when a run is killed, and these runs are killed constantly -- by timeouts,
# by a gate being stopped, by a machine being taken down mid-measure. ship.sh
# is worse than unreliable: it `exec`s a copy of itself, which replaces the
# shell, so its EXIT trap never had any chance of running at all. That one
# leaked on every release, without exception, for as long as it has existed.
#
# So the answer is not a better trap in a hundred places. It is one directory.
# Move $TMPDIR itself, once, at the top of a run, and every child inherits it:
# every mktemp, every swift build, every NSTemporaryDirectory() in the app the
# harnesses drive. Nothing below has to remember anything, and nothing new that
# gets written here has to be told either.
#
# What that buys the sweep is the part that matters. sweep-workspaces.sh used
# to pattern-match names in the shared $TMPDIR and guess, from marker files,
# which `tmp.XXXXXXXX` was one of ours -- a guess that could be wrong about
# somebody else's data. It now empties this directory by age and cannot be
# wrong, because nothing else on the Mac writes here.

if [ "${LUKOTTA_TMP_ROOT:-}" = "" ]; then
    __lukotta_tmp_base="${TMPDIR:-/tmp}"
    LUKOTTA_TMP_ROOT="${__lukotta_tmp_base%/}/lukotta-work"
    unset __lukotta_tmp_base
    # A run that cannot have the directory keeps the one it was given rather
    # than failing. Containment is worth having and is not worth a stopped
    # release.
    if mkdir -p "$LUKOTTA_TMP_ROOT" 2>/dev/null; then
        TMPDIR="$LUKOTTA_TMP_ROOT"
        export TMPDIR
    fi
    export LUKOTTA_TMP_ROOT
fi
