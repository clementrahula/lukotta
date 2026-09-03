#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# The owner's ten items, which are one tagged set in checks.tsv among others.
#
# This was the whole mechanism for an afternoon and it was too narrow: a list of
# ten goals is one task, and the thing that stops a fix breaking something
# already proven has to outlive any particular list. So the registry and the
# runner are general, and this is the one line that asks for this set.
exec env TAG=goal "$(dirname "${BASH_SOURCE[0]}")/verify.sh" "$@"
