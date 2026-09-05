#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Clement Rahula
#
# What the app does when handed a genuinely broken NTFS volume.
#
#   ./scripts/corrupt-corpus.sh [corpus-dir] [limit]
#
# The repair tests until now made a volume dirty the honest way -- by killing
# the machine mid-write -- which produces one kind of damage. The ntfsprogs-plus
# people publish a corpus of about eighty NTFS images broken deliberately and
# specifically: boot sectors with impossible geometry, MFT records missing their
# data attribute, corrupted attribute lists, orphaned inodes, cluster runs
# pointing past the end of the disk, and a usb_unplug_test taken from a real
# unplug. It is GPL-2 and it is not vendored here; this clones it on demand.
#
#     https://github.com/ntfsprogs-plus/ntfs_corrupted_images
#
# Each image goes through the app's own ladder -- ntfs3, then ntfs-3g, then the
# repair action -- and two things are recorded: what happened, and whether the
# image changed.
#
# The second is the one that matters. "Repaired it" and "refused it" are both
# acceptable answers; the goal asks for repair and a refusal is at least safe.
# What is not acceptable is writing to a volume it could not understand, so a
# run that ends in refusal must leave the image byte-identical. That is checked
# rather than assumed, because a driver that scribbles on a damaged filesystem
# before giving up is how a recoverable disk becomes an unrecoverable one.
#
# THE WHOLE CORPUS, AFTER THE REPAIR GUARD WAS FIXED
#
#   83 cases: 68 opened at a driver rung, 0 needed the repair route,
#             15 refused, 1 refusal that wrote to the volume
#
# Against the run before it: 43 -> 68 opened at a driver, 24 -> 0 needing the
# repair, 16 -> 15 refused, and the count of refusals that wrote unchanged at
# one -- though a different case. mft_file_bad_sequence_number stopped being
# written to; mft_file_bad_base_mft_record started.
#
# Twenty-five volumes moving from "opened only after ntfsfix wrote to it" to
# "opened by a driver, untouched" is the direction this should go, and it is
# larger than the change alone accounts for. The guard was made to read the dry
# run's words rather than its exit status, which should affect only the repair
# rung; these volumes stopped needing that rung at all. The honest position is
# that the numbers are what they are and the size of the swing is not fully
# explained. Config state has already faked one set of results tonight, and the
# lesson taken was to say so rather than to claim the improvement.
#
# WHAT THE ntfs3 PROBE DID WHEN IT LANDED
#
#   83 cases: 43 mounted through ntfs3, 24 opened by the repair route,
#             16 refused, and 1 refusal that wrote to the volume
#
# Before the probe, three of the first twenty-seven were written to and then
# refused. Now one is, out of eighty-three, and it is a different rung:
#
#   mft_file_bad_sequence_number
#     ntfs3 (probed)  refused   image unchanged
#     ntfs-3g         refused   image unchanged
#     repair          refused   image CHANGED
#
# So the driver no longer does it and ntfsfix now does. `ntfsfix -n` is run
# first as a guard and vouched for this volume; `ntfsfix -d` then wrote to it;
# the mount failed anyway. That is precisely what the engine's documentation
# says will happen -- clearing a dirty flag does not fix structural damage --
# and it means the dry run is not a test of whether the wet one is safe.
#
# The narrow fix would be to attempt the repair only when the volume is
# actually dirty, rather than whenever a mount has failed for any reason. A bad
# sequence number is not a dirty flag and ntfsfix has nothing to offer it.
#
# Two ways to ask, and one of them is already ruled out. `ntfsinfo -m` reports
# Volume Flags, and on this image it gives 0x0080 -- MODIFIED_BY_CHKDSK, not
# the 0x0001 dirty bit -- so the flag would have said "do not repair this" and
# been right. But on `mft_attr_bad_fields`, one of the twenty-four the repair
# route legitimately opens, ntfsinfo prints nothing at all: the volume is
# damaged in a way it will not read. A guard that goes silent on exactly the
# volumes the repair exists for is not a guard, and gating on it would have
# closed the repair route on the cases it works for.
#
# What is left inside the guest is the driver's own refusal. ntfs3 says "volume
# is dirty and 'force' flag is not set" when that is why it declined, and a
# read-only ntfs3 mount is already known not to write. So the repair action
# could attempt one, read the reason, and only reach for ntfsfix when the word
# it wanted is there. That is untested and it is the next thing to try.
#
# The complete fix is still ntfsck, which answers the question these are all
# proxies for.
#
# WHAT IT FOUND FIRST, WHICH IS THE POINT OF HAVING WRITTEN IT
#
# Of the first 27 cases: 17 mounted, 7 were refused and left untouched, and
# three were refused *and modified*:
#
#   created_manually/mft_file_missing_bitmap_attr
#   created_manually/mft_file_missing_data_attr
#   created_manually/mft_file_missing_filename_attr
#
# All three are MFT records missing an attribute -- structural damage, not a
# dirty flag. The obvious suspect was the repair action, since it runs ntfsfix
# and the engine's own documentation warns that using ntfsfix to clear a dirty
# flag "can lead to further data corruption". That was written down here as the
# strong reading, and it was wrong.
#
# Measured rung by rung instead -- hash the image, try ntfs3, hash, try
# ntfs-3g, hash, try the repair, hash -- on all three cases:
#
#   ntfs3     refused   image CHANGED
#   ntfs-3g   refused   image unchanged
#   repair    refused   image unchanged
#
# Identical on all three. It is not ntfsfix and it is not the repair route at
# all. **The kernel ntfs3 driver writes to a damaged volume during a mount it
# then refuses**, on the very first rung, before anything of ours has decided
# to attempt a repair.
#
# Which is the same driver the engine declines to make its default, for stated
# reasons: silent corruption on hibernated volumes, and read-only directories
# on Windows system disks. This app leads with ntfs3 because it is markedly
# faster. On a healthy volume that is the right trade. On a damaged one the
# first thing that happens is a write, to a disk somebody may have brought here
# precisely because it is damaged.
#
# ntfsck, from ntfsprogs-plus, is a real checker rather than a flag-clearer and
# would let the ladder know which kind of volume it has before touching it.
# GPL-2, aggregating in the guest like the rest of the userspace.
# DO NOT SWEEP WITH `pkill -9 -f 'anylinuxfs mount'`.
#
# That pattern matches the machine serving somebody's real drive exactly as
# readily as the one serving a fixture, and killing it mid-write is the case
# measured in EngineProcesses.flushGrace. It was run repeatedly during a night
# of testing while the owner's BitLocker drive was mounted, and left it dirty
# with $MFTMirr behind $MFT -- readable, every file intact, and read-only until
# a chkdsk. Match the image being tested, as try_open and close do here.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

CORPUS="${1:-}"
LIMIT="${2:-0}"
# The same default as every other harness here, and for the same reason.
#
# This named the Dev build, which on this Mac is not compiled with devtools and
# has no --drive. Run without LUKOTTA_ENGINE set it drove that app anyway and
# hung: thirteen minutes on `--drive actions` with nothing printed, no timeout on
# the call, and eighty-three images still to go. verify.sh resolves an app that
# answers to --drive and exports it, which is the real fix; this is so a run
# started by hand agrees with a run started by the gate.
ENGINE="${LUKOTTA_ENGINE:-/Applications/Lukotta Beta.app/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
[ -x "$ENGINE" ] || { echo "error: no engine at $ENGINE" >&2; exit 2; }
APP_BUNDLE="${ENGINE%/Contents/Resources/engine/anylinuxfs/bin/anylinuxfs}"
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' \
  "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo com.lukotta)"
export ANYLINUXFS_HOME="$HOME/Library/Application Support/$APP_ID/engine"

WORK="$(mktemp -d)"
IMG="$WORK/case.img"
cleanup() { pkill -f "anylinuxfs mount.*case" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

if [ -z "$CORPUS" ]; then
  CORPUS="$WORK/corpus"
  echo "cloning the corrupted-image corpus…"
  git clone --depth 1 https://github.com/ntfsprogs-plus/ntfs_corrupted_images.git \
    "$CORPUS" >/dev/null 2>&1 || { echo "error: could not clone the corpus" >&2; exit 2; }
fi

where() {
  mount | awk '$1 ~ /case-img\.local:/ {for(i=1;i<=NF;i++) if($i=="on") {print $(i+1); exit}}'
}

# Install the app's own guest actions before driving the engine by hand.
#
# Without this the harness asks for -a lukottantfs3, the action is not in
# config.toml because only a real mount writes it there, and the engine
# declines the attempt for that reason. Which looks exactly like the probe
# working: three damaged volumes came back "refused, left untouched" and the
# check had never run. The tell was a healthy volume mounting through ntfs-3g
# instead of ntfs3 -- the first rung was failing for everything.
#
# So the actions come from the app itself rather than being restated here.
APP="$APP_BUNDLE/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' \
  "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null)"
CFG="$ANYLINUXFS_HOME/.anylinuxfs/config.toml"
# Bounded, and refused rather than hung.
#
# This call had no timeout. Pointed at a build without devtools it does not
# answer and does not exit: measured at thirteen minutes with nothing printed
# and eighty-three images still to come, on a run that looked like it was
# working. An unbounded call to something that can hang is not a step, it is a
# place a run goes to stop.
if [ -x "$APP" ] &&
   [ "$(strings -a "$APP" 2>/dev/null | /usr/bin/grep -c -- "--drive")" -gt 0 ] &&
   timeout 120 env LUKOTTA_DEVTOOLS=1 "$APP" --drive actions > "$WORK/actions.toml" 2>/dev/null \
   && [ -s "$WORK/actions.toml" ]; then
  /usr/bin/python3 - "$CFG" "$WORK/actions.toml" <<'PY'
import sys, pathlib, re

# Remove a custom action from config.toml, line by line.
#
# The obvious regex -- \[custom_actions\.NAME\][^\[]* -- is wrong, and it
# corrupted this machine's config repeatedly before anyone noticed. It stops at
# the first "[" it meets, and the line immediately below the header is
#     environment = ['NFS_SERVER_THREAD_COUNT=8']
# which contains one. So the header was removed and its body left behind, the
# file grew a stray orphan line on every run, and eventually the engine refused
# to parse it at all -- reporting "invalid table header", by which time several
# runs of results had already been taken through a broken config and believed.
#
# A section ends at the next line that STARTS with "[". That is the rule.
def drop_action(text, name):
    out, skipping = [], False
    for line in text.splitlines(keepends=True):
        if line.startswith("[custom_actions." + name + "]"):
            skipping = True
            continue
        if skipping and line.lstrip().startswith("[") and not line.lstrip().startswith("['"):
            skipping = False
        if not skipping:
            out.append(line)
    return "".join(out)
cfg, act = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).read_text()
s = cfg.read_text() if cfg.exists() else ""
# Every action the incoming block defines, not a hard-coded pair.
#
# This dropped "lukottantfs3" and "lukottarepair" and then appended the app's
# whole block, which defines four: lukottatuned, lukottantfs3, lukottarepair and
# lukottantfs3g. So the second run of this script left two sections defined
# twice, and the engine will not parse a config with a duplicate key:
#
#     Failed to parse config file .../config.toml:
#     duplicate key `lukottantfs3g` in table `custom_actions`
#
# Which is not a mount failing -- it is every mount failing, for every drive,
# until somebody edits the file. Measured on 2026-09-05: twenty corpus images
# that had opened at a driver rung in the morning were all refused in the
# afternoon, and the app looked badly broken when the config was unreadable.
for name in re.findall(r"^\[custom_actions\.([A-Za-z0-9_]+)\]", act, re.M):
    s = drop_action(s, name)
cfg.write_text(s.rstrip() + "\n\n" + act.strip() + "\n")
PY
  echo "installed the app's guest actions into config.toml"
else
  echo "error: could not read the app's guest actions; the ntfs3 rung would" >&2
  echo "       fail for a missing action and be reported as a clean refusal" >&2
  exit 2
fi

# One attempt, with whatever driver and action the ladder is up to.
try_open() {
  pkill -f "anylinuxfs mount.*case" >/dev/null 2>&1; sleep 2
  # stdin from /dev/null, not inherited. The engine reads it, and inheriting
  # the loop's stdin let it swallow the list of cases being fed in through
  # process substitution: the first case ran, the rest were eaten, and the run
  # reported "cases 1" as though the corpus held one image.
  nohup "$ENGINE" mount --ignore-permissions -w false "$@" "$IMG" \
    > "$WORK/engine.log" 2>&1 < /dev/null &
  for _ in $(seq 1 25); do [ -n "$(where)" ] && return 0; sleep 2; done
  return 1
}

close_it() {
  local v; v="$(where)"
  [ -n "$v" ] && umount -f "$v" >/dev/null 2>&1
  pkill -f "anylinuxfs mount.*case" >/dev/null 2>&1
  sleep 2
}

mounted=0; repaired=0; refused=0; scribbled=0; n=0
printf '%-46s %-26s %s\n' "CASE" "OUTCOME" "IMAGE"
printf '%-46s %-26s %s\n' "----" "-------" "-----"

while IFS= read -r archive; do
  [ "$LIMIT" -gt 0 ] && [ "$n" -ge "$LIMIT" ] && break
  case_name="$(dirname "${archive#"$CORPUS"/}")"
  rm -f "$IMG"
  tar xJf "$archive" -C "$WORK" 2>/dev/null || continue
  found="$(find "$WORK" -maxdepth 1 -name '*.img' ! -name 'case.img' | head -1)"
  [ -n "$found" ] || continue
  mv "$found" "$IMG"
  n=$((n + 1))

  before="$(/usr/bin/python3 "$HERE/sparse-digest.py" "$IMG")"
  outcome="refused"
  # lukottantfs3, not lukottatuned, for the writable ntfs3 rung -- which is
  # what the app itself uses. Getting this wrong is not a detail: the first
  # version of this harness asked for lukottatuned here, so it exercised the
  # ladder as it was before the read-only probe existed and reported three
  # volumes still being written to after the fix had landed.
  if try_open -t ntfs3 -a lukottantfs3; then outcome="mounted (ntfs3)"
  else
    close_it
    if try_open -t ntfs-3g -a lukottatuned; then outcome="mounted (ntfs-3g)"
    else
      close_it
      if try_open -t ntfs3 -a lukottarepair; then outcome="mounted after repair"
      fi
    fi
  fi
  close_it
  after="$(/usr/bin/python3 "$HERE/sparse-digest.py" "$IMG")"
  changed=same; [ "$before" != "$after" ] && changed=CHANGED

  case "$outcome" in
    refused)
      refused=$((refused + 1))
      # A refusal that wrote to the volume is the one bad answer here.
      [ "$changed" = CHANGED ] && { scribbled=$((scribbled + 1)); changed="CHANGED (refused, yet written to)"; } ;;
    "mounted after repair") repaired=$((repaired + 1)) ;;
    *) mounted=$((mounted + 1)) ;;
  esac
  printf '%-46s %-26s %s\n' "$case_name" "$outcome" "$changed"
done < <(find "$CORPUS" -name '*.img.tar.xz' | sort)

echo
printf 'cases %s: mounted %s, repaired %s, refused %s\n' "$n" "$mounted" "$repaired" "$refused"
printf 'refusals that wrote to the volume anyway: %s\n' "$scribbled"
[ "$scribbled" -eq 0 ]
