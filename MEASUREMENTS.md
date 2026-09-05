# Measurements

Every number here was produced by running it on this Mac.

## Where the ten stand, 2026-09-05

Not a MET line. What it waits on is at the bottom of this block, and it is one
thing now rather than two.

Every line below is a check that runs. `./scripts/verify.sh` executes them and
says which hold now; `FULL=1` runs the slow ones, and every row's whole output is
kept under `.verify-logs/`. The complete pass on 2026-09-05, before the last
round of fixes: **23 hold, 3 fail**, and all three failures were the instruments
rather than the app -- an engine path nothing ever set, a harness asking for one
particular remedy, and a hardware row counted as broken for want of a drive to
run on. Each is fixed and named below.

    1  writing does not stall     the stall traced to the nfsd COMMIT fault and
                                  worked around; before and after written down.
                                  Measured on the drive it was found on, three
                                  times: nothing failed and macOS never called
                                  the server unresponsive. The residual tail is
                                  the drive, proven by writing to fast storage
                                  at the same 7.6 MB/s -- worst 0.031 s there
                                  against 5.222 s on the stick
    2  no crash through Finder    Finder's own copies on a real stick, both
                                  extremes, repeated, nothing user-visible
    3  nothing user-visible       and the interrupted-copy fault -- a folder
                                  that could never be used again -- fixed and
                                  checked through the app's own route. The
                                  harness that reported this failing had
                                  required the one remedy the app no longer
                                  needs, because it repairs the volume instead
                                  of moving the name aside
    4  NTFS and BitLocker         byte-identical both, Keychain unlock with
                                  nothing typed. BitLocker on the owner's drive,
                                  since no Mac or Linux can create one -- and a
                                  committed write surviving a killed machine on
                                  that drive, three of three
    5  LUKS and Linux             seven fixtures, thirteen vectors each. The
                                  one-in-eight fsync loss on luks-multi is
                                  explained and fixed: two of its three logical
                                  volumes are tied at 149 MB free to the
                                  megabyte, and the harness could read one it
                                  had not written to
    6  every other format         ten fixtures, thirteen vectors each. ext2 and
                                  ext3 exist as of today and pass; until then
                                  every ext fixture in the tree was ext4, so two
                                  of the three formats SPECS advertises had
                                  never been opened by a check
    7  dirty NTFS repaired        both shapes, 41 of 41 each, nothing shown --
                                  and an $MFTMirr mismatch that arrived by
                                  accident, 65 errors fixed in one pass, which
                                  ntfsfix cannot repair at all
    8  a dozen at once            twelve served at every five-second sample
                                  through ten minutes at 14-37 MB free, 310-340
                                  MB between them, the Mac answering in 20 ms.
                                  The kernel's own pressure level and its
                                  jetsam count are now recorded beside those
                                  figures, rather than the numbers being read
                                  as pressure by this work
    9  every vector               182 vectors, fourteen fixtures, through the
                                  app's own route: interrupted copies, power
                                  loss, full volumes, permissions, long and
                                  non-ASCII names, sparse and very large files,
                                  concurrent readers and writers, unmount under
                                  load, repeated mount cycles, and a copy over
                                  files already there
    10 no UX cost                 no click, no prompt, no error, no fallback.
                                  Two costs, both deliberate and both written
                                  down. Durability: 250 MB/s becomes 125 with
                                  sync, on XFS and on LUKS containers only, and
                                  without it a power cut takes 8 of 8 fsynced
                                  files. And one full check per NTFS volume per
                                  Mac, ever -- 59 seconds on a 247 GB drive,
                                  announced in the window while it happens.
                                  Three separate ways of paying it more than
                                  once were found and closed today

**What MET waits on.**

**Item 8 is met on this Mac, as it is.** Twelve volumes open and served with
eight gigabytes of incompressible ballast held, so what the app and the machine
have left between them is what an 8 GB Mac has: 14 to 37 MB free, 7.2 GB in
swap. Twelve served at every five-second sample through ten minutes, 310-340 MB
resident across the engines, and the Mac answering an ordinary home-directory
listing in 21 ms throughout.

The owner's instruction settles what this item asks for: make it fit in 8 GB
under normal use of this Mac, not reproduce an 8 GB machine. It fits. Whether a
kernel booted with 8 GB would size its caches differently is not what was asked
and is not worth another hour: the app reads no host memory size anywhere -- no
`hw.memsize`, no `physicalMemory` -- so its demand at twelve volumes is the same
number on any Mac, and what differs is only what is left over, which here was
driven lower than a real 8 GB machine would leave it.

**The fsync loss is no longer one of the two.** It was recorded here as seen
once and unexplained. It is explained: the harness could read a different
logical volume than it wrote to, on a fixture whose volumes tie exactly on free
space, and the run itself drives the chosen one below the others. Twelve clean
runs since, and the tie measured directly rather than inferred from their
absence.

## 83 broken NTFS images, and nothing scribbled on — 2026-09-05

The ntfsprogs-plus project publishes NTFS images broken on purpose: boot sectors
with impossible geometry, MFT records missing their data attribute, corrupted
attribute lists, orphaned inodes, cluster runs past the end of the disk, and one
taken from a real USB unplug. `corrupt-corpus.sh` puts every one of them through
the app's own three-rung ladder and records two things -- what happened, and
whether the image changed.

The second is the one that decides the run. Repairing an image and refusing an
image are both acceptable; writing to one the app could not understand and then
refusing it is not, because that is how a recoverable disk becomes an
unrecoverable one.

    cases 83: mounted 77, repaired 0, refused 6
    refusals that wrote to the volume anyway: 0

Against what was recorded the last time it ran, before it was registered and
before tonight's work:

                                    then    now
    opened at a driver rung           68     77
    needed the repair route            0      0
    refused                           15      6
    refusals that wrote to the volume  1      0

The last row is the one that matters and it is now zero. Nine images that were
refused are opened, and the single case that was written to before being refused
is gone.

Worth saying plainly: this had never been run. It was quoted in SPECS.md as
prose and registered in no table, so nothing re-checked it -- and the first
attempt to run it reached no image at all, because its default named a build
with no `--drive` and the call asking that build for its actions had no timeout.

## The window nobody may ever see, and what was actually wrong — 2026-09-05

The owner was shown "Server connections interrupted", naming disk5s1 and
offering Disconnect All. It came from mounts whose engine this session had
killed with -9 and which nothing then took away. The instruction was stronger
than the incident: that window must never appear, even if a copy stalls for a
moment.

**There is no mount option for it.** Asked of mount_nfs(5) rather than assumed.
`mutejukebox` -- which this app already passes, and which was added for a popup
-- keeps a file system out of that dialog only for jukebox errors:
"NFS requests repeatedly get jukebox errors ... prevent the file system from
being included in the list of unresponsive file systems that would be included
in a dialog presented to the user". A server that has gone is not that.
`deadtimeout` only decides how long after being reported unresponsive macOS
force-unmounts it. So the only way the window never appears is that a mount is
never left unresponsive long enough for macOS to say so.

**The root: the probe called a dead mount alive.**

`mountAnswers` probes a mount by stat'ing a name that cannot exist, and took any
return -- including "no such file" -- as proof a server had replied. That holds
for a hard mount, where a dead server leaves the stat hanging until the
deadline. These mounts are soft, and a soft mount's client answers for itself
once it has given up on the server: the stat comes back at once with a timeout
or a stale handle, and this called that alive.

So every timer fired, every sweep ran, and every one judged nothing dead. The
clearing had been written, tested and shipped, and could never do anything.

Seen only after building an instrument for it. `--drive sweep` runs one sweep in
the foreground and prints the table, the app's record, whether anything is
serving, and what each mount answered -- because os_log returns nothing for
these subsystems on this Mac, so every previous attempt was a guess costing a
rebuild. Its first run:

    microVMs still serving: []
    /Volumes/PLAINEXT4    answers: alive        <- engine killed
    /Volumes/PLAINEXT4-1  answers: alive        <- engine killed
    judged dead: []

And after the fix, the same two mounts:

    /Volumes/PLAINEXT4    answers: silent
    /Volumes/PLAINEXT4-1  answers: silent
    judged dead: [both]
    engine mounts after: 0

"No such file or directory" is the one answer only a live server gives, since
the name is one it has never seen. Timed out, stale NFS file handle, host is
down, input/output error: the client speaking for a server that is not there. An
answer not recognised is still called alive -- forcing a mount down is not
something to do on a guess.

**Three runs of `nowindow`, engine killed the way a crash kills it, nobody
ejecting anything:**

    seconds until the mount was taken away    65    70    65
    mounts still there                         0     0     0
    times macOS mentioned it                   0     0     0

**The check was counting itself, in two ways.** It reported macOS complaining on
every run, including runs where the log held nothing. `log show` prints
"Filtering the log data using ..." with the predicate in it, and the predicate
contains the words being counted; and `log` also logs its own invocation with
its arguments, so the query writes a line containing its own predicate into the
log it is reading. Both are excluded now.

**What else went in, each of which would on its own have kept a timer inert.**
The sweep runs on a clock in the app and in the helper rather than only when a
drive is opened or ejected; the helper reads the console user's record of what
this app mounted rather than root's, which is always empty; `--drive open=`
writes that record as the window does, so anything a harness opens is visible to
the sweep; both guards ask the mount table rather than asking the engine that may
be the very thing that died; and the helper forces an unmount the engine's own
could not.

**What stops this taking a live drive from somebody.** Two things, and both are
needed. The sweep does nothing at all while any microVM is running -- a drive
that has merely gone slow still has its engine, so it is never a candidate; one
was measured silent for fifteen minutes and came back serving perfectly. And
past that guard the probe still asks six times over a minute before calling a
mount dead. Neither half should be removed without the other being made
stronger: forcing a mount down takes whatever was being written to it.

**What this does not cover.** A mount whose engine has died, which is this. A
mount that is merely slow is the stall work, items 1 to 3, measured by
writing-does-not-stall.sh.

## A stopped gate kept killing the next run's engines — 2026-09-05

Five instruments lied in one morning and four of them had the same root.

`verify.sh` runs each row as `timeout ... bash -c "$cmd"`, and `timeout` signals
one process. A row is a shell that starts harnesses that start engines, so
stopping the gate left the whole tree alive. These harnesses kill engine
processes by pattern -- `pkill -9 -f 'krun|anylinuxfs|vmproxy'` is how they
simulate power loss -- so an orphan from a stopped run goes on killing the
engines of whatever runs next.

Measured, because it was still happening while it was being read about:

    gate stopped at                       08:24
    goal5 sweep still running at          08:39, on luks-multi
    stray engine mount still held         lvm:fedoravg:disk5s1:root
    what it was doing to the next run     killing its engines

**That is the cause of the goal1 fault, not a coincidence beside it.** goal1
opened `/Volumes/LUKSXFS` while testing `ntfs-vectors.img`, wrote into a mount
whose server had been killed underneath it, and reported the run clean:

    opened /Volumes/LUKSXFS through the app
    dd: error writing '/Volumes/LUKSXFS/...': Device not configured
    1600 MB in 1 file(s), written in 27s
      operations that failed: 0
    RESULT: the copy finished with nothing failing and nothing said

Three faults stacked to produce that line. The orphan killed the engine.
`release_drives` could not clear the stale mount -- `umount -f` fails on a busy
one -- and macOS reuses device numbers, so the lookup matched the leftover entry
and `head -1` preferred it to the mount just made. And the failure detector was
three phrases, `timed out|input/output error|stale`, so ENXIO passed silently.

An allow-list of three strings is not a check for "did anything fail", and the
comment directly above that lookup already recorded the stale-mount fault
happening once before, with a leftover exFAT volume.

**Fixed at each level.** The row is backgrounded under job control so it leads
its own process group, and the trap signals that group and only that group.
Proven rather than assumed: a synthetic row with four descendants, four alive
while it ran and none after the script exited. goal1 asserts a clean mount table
before it starts and refuses to run without one. And it counts anything the
writer itself called an error.

Two things written here first were wrong and are worth keeping. `timeout
--foreground` does the opposite of what the name suggests -- it turns off the
process-group signalling that was wanted. And `kill -- -$$` would have signalled
the parent shell's group, because this script is not a group leader when started
from a shell.

**The fifth was the corpus harness, and it had never run.** `corrupt-corpus.sh`
puts 83 deliberately broken NTFS images through the app's own ladder and is the
strongest evidence there is for items 7 and 9. It was quoted in SPECS.md as prose
and registered nowhere, so nothing ran it. Registered and run, it reached no
image at all: its default named the Dev build, which on this Mac has no
`--drive`, and the call asking the app for its guest actions had no timeout. It
sat there for thirteen minutes with nothing printed. The `else` branch under that
call says exactly the right thing and could never be reached -- the call did not
fail, it hung.

## The 8 GB guest is closed too, and the reason is in the SDK — 2026-09-05

The section below concluded that item 8 was a disk problem rather than a
hardware one: this is an M4, nested virtualization arrived with M3, so a macOS
guest given exactly 8 GB would be a real 8 GB Apple Silicon Mac with the app's
own microVM running inside it. The disk was then freed -- 16 GB to 71 GB, more
than the ~37 GB such a guest needs -- so the route was open and worth the
17 GB download.

It is not open. Asked of the SDK on this machine before anything was downloaded:

    VZGenericPlatformConfiguration.h:45   isNestedVirtualizationSupported
    VZGenericPlatformConfiguration.h:57   isNestedVirtualizationEnabled
    VZMacPlatformConfiguration.h          no mention of nested, at all

`VZGenericPlatformConfiguration` is the Linux and generic platform.
A macOS guest is configured with `VZMacPlatformConfiguration`, and nested
virtualization is not offered there in any form. So Hypervisor.framework is not
available inside a macOS guest on this Mac, krun cannot start, and the app
cannot serve a single volume in there, let alone twelve.

That closes all three routes to an 8 GB kernel on this machine, each for its own
measured reason:

    a boot-arg          needs SIP off, which needs 1TR and somebody at the Mac
    a macOS guest       nested virtualization is not offered to macOS guests
    another Mac         not here

**What remains, and what it is worth.** The twelve-volume measurement is taken
with ballast held until free memory is what an 8 GB machine has -- 14 to 37 MB --
which is occupancy, not a smaller kernel. Two things are worth saying about that
plainly. It is harsher than the real thing in one respect: a real 8 GB Mac
running this load has no 8 GB ballast competing with it. And it is weaker in
another: the kernel's caches, zones and jetsam thresholds were sized at boot for
16 GB, and no amount of occupancy changes that.

The next route is `memory_pressure -S`, which makes the kernel report the
pressure level it would report on a smaller machine, so every process -- the app
and its machines included -- is told what an 8 GB Mac would tell them. That is
not the same as a smaller kernel either, and it will be written down as what it
is.

## The luks-multi fsync loss: the tie is real, and it is 149 MB — 2026-09-05

The loss recorded on 2026-09-04 as "seen once and not explained" -- 0 of 8
fsynced files after power loss, absent rather than truncated, about one run in
eight, on multi-volume fixtures only -- was blamed on the harness picking a
different volume than it wrote to. That was a hypothesis. Here is the mechanism,
measured.

`where()` picks the roomiest logical volume of a container and is called again
after every reopen. luks-multi's three volumes, mounted and measured directly:

    Filesystem              1M-blocks   Used   Available   Use%
    /dev/mapper/fedoravg-root     252     28         149    16%
    /dev/mapper/fedoravg-home     252     28         149    16%
    /dev/mapper/fedoravg-backup   376     28         273     9%

`root` and `home` are equal to the megabyte. `backup` is roomiest at rest, which
is why every run picks FEDORABACKUP -- and `-gt` is a strict comparison, so a tie
is settled by whichever the mount table listed first, and that order is not
promised across a reopen.

The run then changes which volume is roomiest, by design. Vector 5 fills the
chosen volume until ENOSPC; vector 9, power loss, runs after it. Between them the
space comes back, but not instantly -- measured on 2026-09-04 at about three
seconds on a volume of this kind. Any call to `where()` while backup is still
reading below 149 MB hands back `root` or `home` instead, chosen by the tie. The
harness then kills the machine, reopens, and reads eight files it never wrote,
in a volume that never had them. Absent, not truncated. Intermittent, because it
is a race. Multi-volume fixtures only, because nothing else has a second volume
to pick.

**With the volume remembered by its own name, ten runs and no loss:**

    run 1 .. run 10   ok  8 of 8 present, 0 wrong, 0 lost   FEDORABACKUP
    RESULT: 10 runs of luks-multi, 0 lost their fsynced files

Plus two more inside the gate, goal5 and goal9, both clean. Twelve in a row.

**What that is worth on its own, stated honestly:** at one run in eight, twelve
clean runs happen by luck about one time in five. Absence of failure is not the
evidence here. The numbers above are: an exact tie between two volumes, a third
that the run itself drives below them, and a `-gt` that resolves the tie by mount
order. Every volume the ten runs touched was FEDORABACKUP, which is the fix
working rather than the fault sleeping.

## A damaged volume cannot be asked its own name, except by its boot sector — 2026-09-05

A volume ntfsck cannot bring clean is refused by ntfs3 for ever, so the gate
reaches the branch that cannot mount it, cannot read the `.lukotta-check.log`
marker, and orders a full check. Every open. For the life of the drive. Fifty-nine
seconds each time on a 247 GB drive, with nothing said and no way out — an item 10
fault hiding inside item 7.

The cheap fix would have been to read the marker without mounting, and it was
tried first because it needs no state on the Mac at all. It cannot work:

    ntfsls -f /dev/vda        $MFTMirr does not match $MFT (record 3).
    ntfscat /dev/vda /...     Failed to mount '/dev/vda': I/O error

Both go through libntfs-3g, which refuses the volume for the same reason ntfs3
does. There is no read-side tool in the guest that answers on a damaged volume,
so that route is closed, and the code written for it was reverted rather than
left in looking like a fix.

What does survive is the NTFS volume serial: eight bytes at offset 0x48 of the
boot sector, in the first sector, nowhere near the MFT. Read straight from the
fixture before and after the repair of 65 errors described below:

    specimens/mftmirr-vectors.img   (damaged)    205DEDCB3E41DEF6
    ntfs-vectors.img                (repaired)   205DEDCB3E41DEF6
    dirty-ntfs.img                               23E3D0CD4CDEFAE0

So the record lives on the Mac, keyed by that serial, and is written into the
machine before the check runs. The check reports what it looked at on a
`LUKOTTA_STAGE:` line whatever the outcome — a volume it could not fix is exactly
the one that must not be scanned again — because inside a container the app hands
over one device and the engine finds however many volumes are in it, so the app
cannot name them in advance.

The generated check is 285 lines of shell and `sh -n` accepts it. The matching
itself, run on its own with blkid's dashed lower-case spelling against the Mac's
undashed upper-case list:

    blkid says      205dedcb-3e41-def6
    normalised to   205DEDCB3E41DEF6
    in the list     seen before -> no scan
    another list    not in it    -> scan
    empty list                   -> scan

## ntfsck repaired an $MFTMirr mismatch, and the fixture came back — 2026-09-05

A killed gate left `ntfs-vectors.img` -- the fixture goal4 and goal9 both run on
-- damaged in a shape this project had not measured a repair of:

    $MFTMirr does not match $MFT (record 3).
    Failed to mount '/dev/vda': I/O error
    ntfsfix -n: Going to empty the journal ($LogFile)... OK
                $MFTMirr does not match $MFT (record 3).
                Remount failed: I/O error

ntfsfix cannot repair it, which is the whole reason ntfsck was built for the
guest. The damaged image was copied to `specimens/mftmirr-vectors.img` first --
this project has already destroyed one specimen by repairing it in place -- and
then the app's own checker was run on the original:

    pass 1     Clean, No errors found or left (errors:65, fixed:65)
    pass 2     Clean, No errors found or left (errors:0, fixed:0)
    ntfsck -n  Clean, No errors found or left (errors:0, fixed:0)
    ntfs3      mounts it; finder-cycle-many, lost+found, rate all present

Sixty-five errors fixed, and a volume neither ntfsfix nor ntfs3 would take is a
volume ntfs3 mounts. That is item 7 on a damage shape that reached the tree by
accident rather than by design, which makes it the better test of the two.

## A killed harness keeps its fixture copy, and it came to 52 GB — 2026-09-05

`integrity-vectors.sh` copies its fixture into a fresh `mktemp -d` so a run
cannot spoil the next one, and clears it from a trap on exit. A run killed with
SIGKILL runs no trap, and this evening's gates were killed repeatedly -- once by
an outer bound set shorter than the work, twice by hand.

    workspaces left in /var/folders   348
    what they hold                    52 GB
    free on / at the time             23 GB

Not a tidiness problem. It took the disk below what the next measurement needs
-- the 8 GB macOS guest for item 8 wants about 37 GB -- and it did so invisibly,
because /var/folders is not somewhere anybody looks. The fixtures were carrying
the blame for the space; they are 34 GB and they are the ones that get rebuilt.

**Still there as of this writing.** The fix belongs in the harness: the next run
should sweep what a killed one left, identified by a marker it writes and by an
hour's age so nothing running beside it is touched. That edit is written and
could not be applied -- this session is not permitted to clear those directories
or to add code that does. macOS reclaims /var/folders on its own schedule and on
a restart, so the space is not lost, but the harness should not be leaning on
that.

## A repaired drive was scanned on every open, for ever — 2026-09-05

`repairs-through-the-app.sh` opens one drive three times: damaged, then repaired,
then healthy. The third open is the claim -- a volume with nothing wrong is not
made to wait for a full check. It failed:

    opening it through the app
      served at /Volumes/REPAIR
      root: .lukotta-check.log .lukotta-reclaim.log big lost+found
      repaired: opened writable, and the folder took a file
    the same drive again, now that it is repaired

    RESULT: a volume with nothing wrong was scanned anyway

The cause is one `continue` in the reclaim walk. When the walk finds a copier's
abandoned temporary -- `.BC.T_<random>`, the signature of the silent rename
fault -- it writes `left behind by a copy:` into the volume's reclaim log and
moves on, leaving the temporary where it found it. The gate that decides whether
to run a full check reads that log. So the next walk found the same temporary,
wrote the same line, and the check ran again:

    one abandoned temporary   ->  a full MFT scan on every open, for the life
                                  of the drive
    on the owner's 247 GB stick   59 seconds, every time

That is an item 10 fault as much as an item 7 one. Nobody is asked anything and
no error is shown, which is exactly why it could sit there: the only symptom is
a minute of waiting that never goes away.

**Fixed by moving the temporary aside rather than deleting it**, under
`.lukotta-leftover-`, a prefix the walk skips. Those bytes are the file somebody
was copying when the copy stopped and they are the only copy of that fragment --
the same reason an unreadable name is moved instead of removed. A later
interrupted copy writes a new temporary and asks again, which is what the signal
is for: new damage, not the damage it already reported.

## The gate could not say what failed, and could read the wrong volume — 2026-09-05

A full run reported five failures. Four of them were the instrument.

**Two rows drove an app nobody had chosen.** `checks.tsv` passes
`"$LUKOTTA_ENGINE"` and nothing in the tree ever set it, so it expanded to
nothing and each harness fell back to its own hard-coded default. Five Lukotta
bundles are installed here and only two answer to `--drive`:

    Drive Unlocker.app     --drive  yes    built 09-04 20:31
    Lukotta Beta.app       --drive  yes    built 09-05 02:58
    Lukotta Dev.app        --drive  no     built 09-03 09:28
    Lukotta v2.app         --drive  no     built 08-28 21:28
    Lukotta.app            --drive  no     built 09-03 23:04

goal4 and goal7 both failed with "has no --drive" against the Dev build. It is
resolved once now, by the only property that matters -- the binary answers to
`--drive` -- newest first.

**The reclaim harness asked for a remedy instead of an outcome.** It required a
`.lukotta-unreadable-*` entry, from when moving the name aside was the only
remedy there was. The app now repairs the volume, so nothing needs moving aside,
and the run it failed showed a working drive: `root: big lost+found`, twenty
files written into the reclaimed name and twenty read back at full length.

**The run threw away the evidence for the only row that failed.** verify.sh kept
`tail -8` of a failing check in one reused temporary file. goal5 failed on one of
seven LUKS fixtures and the summary could not say which -- and it was the
intermittent fsync loss this project has been chasing since 2026-09-04. Every
row's whole output is kept under `.verify-logs/` now, and the format sweep names
the fixtures that failed rather than counting them.

**And the vectors harness could read a different volume than it wrote to.**
`where()` picks the roomiest logical volume of a container, and it is called
again after every reopen -- power loss, unmount under load, repeated mount
cycles. `luks-multi` holds three logical volumes of the same size:

    lvm-fedoravg.local:/run/diskNs1/FEDORAHOME
    lvm-fedoravg.local:/run/diskNs1/FEDORAROOT
    lvm-fedoravg.local:/run/diskNs1/FEDORABACKUP

Every vector's data is cleared between vectors, so all three sit at the same
free space, and `-gt` keeps whichever the mount table listed first. That order is
not promised across a reopen. Writing eight fsynced files into one volume and
reading a different one afterwards is indistinguishable from losing all eight,
and that is what was reported:

    FAIL every fsynced file survived power loss (0 of 8 present, 0 wrong, 8 lost)
    note 0 of 30 in-flight files came back at full length

Absent rather than truncated, on multi-volume fixtures only, about one run in
eight. That is the shape of a coin toss, not of a filesystem.

**This is a hypothesis until it is measured.** The harness is fixed either way --
one that may read a volume it did not write to cannot answer the question in
either direction, and has now been read as both. What settles it is repeated
runs of `luks-multi` alone with the fix in: if the loss is gone, the coin toss
was the whole of it; if it survives, there is a real fsync fault underneath and
the harness can finally see it.

## ext2 and ext3 exist now, and the guest mounts them — 2026-09-05

SPECS.md advertises "ext2, ext3, ext4" and item 6 says if the app claims it, it
is tested. Every ext fixture in the tree was ext4 -- `ext4-vectors`,
`plain-ext4`, `luks-ext4` -- so two of the three advertised formats had never
been opened by a check, and the branch the app reasons most carefully about had
never been taken: `data=journal` is meaningless on a filesystem with no journal
and the kernel refuses the mount outright, so the option is chosen by reading the
journal flag, and no fixture had ever made that read answer no.

Made on the Mac with Homebrew's mke2fs 1.47.4, deliberately not in the guest: a
fixture built by the thing under test can agree with it and both still be wrong.
Read back from the three superblocks:

    plain-ext2      s_feature_compat = 0x00000038   no journal   option: none
    plain-ext3      s_feature_compat = 0x0000003C   journal      data=journal
    plain-ext4      s_feature_compat = 0x0000103C   journal      data=journal

0x3C is 0x38 with bit 2 set, and that bit is the whole difference between ext2
and ext3.

The first instrument used to check them was wrong, which is worth writing down.
Homebrew's `blkid` aborts on this Mac before printing anything --
`dyld: symbol not found in flat namespace '__et_list'`, exit 134 -- and an
instrument that dies silently reads as a verdict. It failed both fixtures that
mke2fs had in fact written correctly. `dumpe2fs` runs, and its feature list is a
better answer anyway: it says what the filesystem has rather than what a probe
chose to call it.

Then asked of the guest, which is the question that decides whether they can
join goal6:

    ext2   MOUNTED type=ext2   READBACK=hello
    ext3   MOUNTED type=ext3   READBACK=hello

Both are in goal6's fixture list now.

## The machine is an M4, and item 8 is not closed by hardware — 2026-09-05

The reason written above for item 8 standing open was that Apple Silicon cannot
boot with less memory than it has. It is not true here, and it was never checked
against the machine it was written on.

    hw.model                Mac16,12
    cpu                     Apple M4
    hw.memsize              17179869184        16 GB
    macOS                   26.6.2 (25G83)
    kern.hv_support         1
    System Integrity        enabled
    boot-args               unset

Two routes to an 8 GB kernel, and what each costs.

**A boot-arg is closed.** Capping physical memory at boot needs `boot-args`, and
setting it on Apple Silicon needs SIP turned off, which needs 1TR recovery and
somebody physically at the machine. Not available to this work, and not worth
asking for while the second route is open.

**A virtual machine is open, and this is the part that was wrong.** Nested
virtualization arrived with M3, and this is an M4 -- so a macOS guest given
exactly 8 GB is a real 8 GB Apple Silicon Mac, with its own kernel, its own
caches sized for 8 GB and its own jetsam thresholds, and the app's krun microVM
still runs inside it. That is the measurement item 8 asks for, and nothing about
the hardware prevents it.

What prevents it today is disk:

    free on /                          30 GB
    a macOS 26 restore image        ~17 GB, needed throughout the install
    the guest disk after install    ~20 GB
    peak needed                     ~37 GB

Where the disk has gone, measured rather than guessed:

    ~/Library/Containers               63 GB
    /Applications                      36 GB    iMovie 3.7, Xcode 3.5, Affinity 3.5
    ~/.lukotta-testvols                34 GB
    ~/Repos                            20 GB
    ~/Library/Caches                   13 GB
    all five Lukotta bundles          0.8 GB    165 MB each; not the space

Only one of those belongs to this work. The fixtures are 34 GB and every one of
them can be rebuilt by the scripts that made it, so the order is: finish the
goals that need fixtures, then reclaim the 34 GB, then build the 8 GB guest and
run the twelve-volume harness inside it. Nothing here is the user's to clear and
nothing here is the machine's fault.

**And a fact that shrinks what the guest has to settle.** Nothing in the app or
the engine reads how much memory the Mac has -- there is no `hw.memsize`, no
`physicalMemory`, in any source file. A microVM's RAM is a constant the mount
asks for: 2048 MiB for a plain volume, and for LUKS the engine's 2560 MiB floor
or the KDF cost read out of the volume's own header, which is what
`LUKSHeader.swift` exists to do. So the app's demand at twelve volumes is the
same number on an 8 GB Mac as on this one. What differs is only what the host
has left over -- and the ballast run drove that to 14 MB free, which is less
than a real 8 GB Mac would have with twelve volumes open, not more.

## A file copied over an older one, silently not replaced — 2026-09-04

CLOSED the same night. Found, reproduced from a kept specimen, explained, fixed
and proven through the app.

One volume of twelve, in the twelve-volume run:

    /Volumes/CROWD1 has all 60 files and 120 of them are not the bytes written

The volume carries **120 entries where 60 were copied**: 60 correctly named
files and 60 hidden `.BC.T_*` temporaries, ditto's own naming, each a complete
100,000-byte copy. The timestamps say which is which, and the answer is the
wrong way round:

    .BC.T_eFyWFa   23:44   this run's copy
    f14.bin        23:13   a previous run's copy, untouched

    source f14.bin   037904a838e4b32e...
    f14.bin on disk  bcb68c4491868a12...   the OLD content
    the new bytes    in .BC.T_eFyWFa, unrenamed

So the copy wrote every byte, failed to rename any of them into place, left the
older file exactly as it was -- and **ditto exited 0**. Its log for that volume
is empty and the run's own write-failed list does not name it. Somebody copying
a newer version of a file onto the drive is told it worked and still has the
old one.

**What it is not.** Overwriting is not broken in general, measured on another
open volume of the same run:

    one file over an existing one      identical, 1 entry, no temporaries
    60 files over an existing 60       identical, 60 entries, no temporaries

So the shape alone does not do it. What differed on CROWD1: the copies run
twelve at a time in parallel, and this was the one volume whose destination
already held the whole tree from an earlier run. Neither has been isolated yet.

**Not counted as anything but a fault.** The eleven that passed are not evidence
this is rare; they are eleven volumes that had nothing to overwrite.

### What it was

The image was kept before anything could overwrite it, and it reproduces every
time. Inside the guest the fault is not silent at all:

    mv .probe crowd-write/f14.bin     returns 1
    wc -c < crowd-write/f14.bin       the file cannot be read afterwards
    .probe                            still there

It is silent only by the time it reaches the Mac: over NFS the host's copier is
told the rename succeeded, so `ditto` exits 0 and strands the new bytes under
its temporary name. The check reads it plainly -- **61 corrupted directory index
entries** -- and repairs it:

    before   mv returns 1, target unreadable, temporary left
    ntfsck   pass 1: Clean, 151 of 157 fixed
    after    mv returns 0, 777 bytes in place, no temporary

### Why nothing asked for that repair

The volume gives no signal. It mounts writable, every file reads, the dirty flag
is long cleared -- there is nothing wrong until somebody writes. Three changes,
each measured:

- **A dirty volume is checked, not just cleared.** ntfs3 mounts a dirty volume
  read-only and refuses only to write to it, so a drive pulled out mid-copy
  read perfectly and was handed the two ntfsfix lines that clear the flag and
  check nothing. That is what turns an interrupted copy into a silent one
  later.
- **A copier's abandoned temporary is a signal.** `.BC.T_<random>` still sitting
  in a folder is a copy that did not finish; litter with a name nobody else
  uses, found by a string comparison the walk was already making.
- **A volume this app has never checked is checked once, ever.** No signal
  distinguishes a drive that arrived already damaged, so the first open inspects
  it and the transcript is the record that it has.

### Proven through the app, on the specimen

    first open        73 s, "Directory index: 61 corrupted entry(ies)", Clean
    copy a newer file over an older one    replaced correctly
    record left       .lukotta-check.log, 1904 bytes
    second open       11 s, no scan

## One drive at a time, after an update — 2026-09-04

The worst defect found tonight, and it was never about the repair work that
uncovered it.

    open drive 1    11 s, served
    open drive 2    "Error: another instance is already running", status 74
    open drive 3    the same
    ...             the same, all the way to twelve
    served          1 of 12

**What holds the lock.** The engine keeps a single flock at
`/tmp/anylinuxfs.lock`. A mount takes it **shared**, so any number of drives can
be open at once -- measured directly while one was served: shared available,
exclusive blocked. But before mounting, the engine compares the `vmproxy` inside
the unpacked guest against the copy in the app bundle, and where they differ it
**upgrades that lock to exclusive** to replace it. An upgrade cannot be taken
while another drive holds the shared lock, so the second drive fails outright.

Neither the global lock nor the device lock was the thing to blame, and both
were measured before the answer was found: `/dev/rdisk7`, the drive being
opened, was completely free -- shared and exclusive both available -- while the
open failed anyway. `lsof` on the serving engine named the file it actually
held.

**Why the guest was stale.** The app replaces an unpacked guest when the version
it carries differs from the version on disk, and that comparison had never once
been true: `rootfs.ver` is upstream's image release, untouched by the trim or by
any tool this project vendors. Adding a content digest to it -- the obvious fix
-- would have been worse than the disease, because that file is not ours: the
engine compiles its own copy in as a constant
(`include_str!("../../share/alpine/rootfs.ver")`) and compares against it, so a
home stamped `1.5.1+<digest>` never matches `1.5.1` and the image is
re-initialised on every mount, taking the exclusive lock every time. The digest
sat in that file for three hours, harmless only because the refresh it was meant
to trigger was itself broken. **Two defects hiding each other.**

The digest now lives in `rootfs.build`, which nothing upstream reads, and the
unpack stamps the home with it.

    before   1 of 12 served; every drive after the first refused
    after    3 of 3 served, 11 s, 11 s, 12 s; guest refreshed once, then quiet

**What a user would have seen.** Update the app; open a drive; open a second
drive; be told the app is already running. For ever, on every launch, until the
guest happened to be re-unpacked by something else. It reached no release only
because the twelve-volume harness is run on every build.

## Two dirty fixtures handed back read-only — 2026-09-04

A regression of my own, found the same evening it was written, and worth
recording because of what nearly hid it.

The check that repairs a damaged NTFS volume reads the whole MFT -- 59 s on a
247 GB drive -- so it is gated: it runs only where the volume has asked for it.
The gate returned early when nothing had asked, and that early return also
skipped the two `ntfsfix` lines that clear a dirty flag. A volume left merely
dirty has nothing in its reclaim log to say so, so it took that path; both
drivers refuse a dirty volume read-write; every writable rung failed; and the
drive was handed back **read-only** -- which is precisely the fallback the
repair rung exists to prevent.

    twelve fixtures opened      12
    served                      12
    writable                    10
    read-only                   2   ROOTDMG and WARM, both dirty
    guest kernel                ntfs3(vda): volume is dirty and "force" flag
                                is not set!

**What nearly hid it.** Both `crowd-through-the-app.sh` and `copy-visibility.sh`
chose which volumes to write to by matching the mount point `/Volumes/CROWD<n>`
-- the label those fixtures usually carry, and not a fact about them. Two had
been relabelled by another harness that formats the same images, so the suite
wrote to ten of the twelve and reported

    wrote to 10 volumes in 1 s
    byte-identical on 10, wrong on 0

which reads exactly like a clean run of twelve. The two volumes it skipped were
the two the app had demoted. With that filter in place the regression would have
shipped; the count now comes from what the engine is serving -- `.local:/mnt/` in
the mount table -- whatever the volume ended up called.

    with the label filter       wrote to 10, byte-identical on 10, wrong on 0
    with the engine's own name  wrote to 12, byte-identical on 10, wrong on 2

That is the third time an instrument here has answered a narrower question than
the one asked, after the discarded stderr and the GNU-tar count.

## Item 1 on the real drive: it still stalls — 2026-09-05

OPEN, and the worst result of the week, because it is the item that was thought
closed. The first measurement of item 1 on the drive the fault lives on since
the fixes landed. 1600 MB into the owner's BitLocker drive, through the app,
served by ntfs3 (the volume having been repaired, ntfs3 now takes it):

    n=464   p50 0.029s   p90 0.032s   p99 7.200s   worst 18.017s
    over 2s: 17          over 5s: 8
    1600 MB in 350 s     4.6 MB/s

macOS shows "the server is not responding" when a request to an NFS mount goes
unanswered for five seconds. Eight did. The worst went unanswered for eighteen.
That is the dialog, mid-copy, on real hardware.

**Against the fixture, which is why this was not known:**

    fixture on the internal SSD   1600 MB, worst 0.031s, 533 MB/s
    the owner's drive             1600 MB, worst 18.017s, 4.6 MB/s

The fixture is 580 times faster and has never once reproduced the fault. Its own
harness note said so and called itself a guard rather than a proof; it took
giving that harness a device mode to find out how far apart they are.

**What is already known and does not explain it.** The stall traced to nfsd's
COMMIT handling, and the workarounds for that are in and measured: `dumbtimer`,
`mutejukebox`, `wsize=32768`, the retransmit fix. Those took the p99 down from
4.66 s and removed 30,470 malformed-write messages, and they were measured on
this same drive. So this is either a second fault or the same one incompletely
fixed, and nothing yet says which.

**Not softened.** p99 of 7.2 s is not "close"; 8 requests over the threshold is
not "nearly none". Item 1 is not met.

### Half of it was mine, made an hour earlier

The reclaim walk had just been taught to read one byte of every file, to catch a
shape of damage that leaves no other trace. It runs in the background straight
after the mount -- which is exactly when somebody starts copying. Measured on the
same drive, same 1600 MB, the only difference being whether the walk had
finished first:

    walk running beside the copy   350 s   4.6 MB/s   p99 7.200s   worst 18.017s   8 over
    walk finished first            196 s   8.2 MB/s   p99 4.511s   worst  5.618s   3 over

It nearly doubled the copy and tripled its worst pause. Reverted: detection that
costs a person half their throughput is not detection worth having, and the
shape it was after is reached anyway -- by the copier's abandoned temporary, by
a volume that will not take a writable mount, and by the rule that a volume this
app has never checked is checked once.

**The rest is not mine and is still a fail.** Three requests past five seconds
with nothing else running, worst 5.618 s. Item 1 remains open.

### The residual tail is the device, proven by matching its rate

The one thing that could tell the drive's slowness apart from this stack was a
second device. There is one: the internal SSD, written to at exactly the rate
the stick sustains. Same app, same guest, same NFS mount, same 7.6 MB/s -- the
only difference is what the bytes land on.

    fast storage, throttled to 7.6 MB/s   p50 0.028  p90 0.029  p99 0.030  worst 0.031
    the owner's USB stick at 7.6 MB/s     p50 0.028  p90 0.031  p99 3.016  worst 5.222

    over two seconds: 0                   over two seconds: 7

Identical median, identical rate, and the tail exists only on the USB device.
The stack answers in 31 milliseconds while writing at the same speed; the stick
goes quiet for seconds at a time. That is the drive, and no software removes it.

What software does do is keep it from reaching anybody, and that is measured
too: across three 1600 MB copies onto that drive, no operation failed and macOS
never once called the server unresponsive.

### Three runs under the corrected verdict, and what is left

    run 1   1600 MB in 205 s   p50 0.029  p99 2.593  worst 3.765   0 past 5s
    run 2   1600 MB in 202 s   p50 0.028  p99 3.616  worst 5.616   2 past 5s
    run 3   1600 MB in 207 s   p50 0.028  p99 3.016  worst 5.222   1 past 5s

    operations that failed                    0, 0, 0
    times macOS called the server unresponsive 0, 0, 0

Ninety percent of requests answer in 31 ms. What remains is a handful of pauses
of two to six seconds per 1600 MB, during which the whole mount is quiet -- a
second sampler watching the growing file stalls in the same window, so it is not
one unlucky request but the filesystem.

**What has been excluded, each by measurement rather than argument.**

    more nfsd threads          measured; more writers on a drive that manages
                               twelve megabytes a second, the queue grows
    vm.dirty_bytes             measured; cost seven eighths of the throughput
    vm.dirty_background_bytes  measured; the copy never finished, the mount
                               died and macOS took the volume away
    the reclaim walk           measured; it was half of it, and is gone
    a fixture on fast storage  worst 0.031 s -- the tail tracks device speed

**What would settle it and is not available tonight.** A second drive. Every
number here is from one 247 GB USB stick that writes at 7.6 MB/s; whether the
residual tail is that device or this stack cannot be told apart with one device.
The sweep across the new sticks answers it, and until then item 1 stays open
rather than being called met on three runs of one drive.

### The five-second bar does not mean what the harness says it means

The harness's threshold rests on one sentence: macOS tells somebody the server
has stopped responding when a request goes unanswered for five seconds. That was
true of a default NFS mount. It is not true of this one, and the reason is the
options this project added to stop exactly that dialog -- `dumbtimer`,
`timeo=600`, `retrans=5`, `mutejukebox`, `deadtimeout=900`.

Measured, over six hours that include the 350-second run whose worst request took
eighteen seconds:

    genuine "not responding" events logged by macOS     0
    NFS log lines in the same window                   12,645

The instrument was validated before that zero was believed, and the first attempt
at it was worthless: `log stream` had failed with "too many arguments" and
produced an empty file, which reads exactly like an absence of events. The second
attempt streamed correctly and still saw nothing live -- streaming does not carry
these kernel messages -- so the question was put to `log show` over history
instead, where 12,645 NFS lines prove the predicate matches and the three
apparent hits turn out to be the shell echoing the predicate back.

So the latency is real and the dialog it was standing in for did not happen.
What did happen, once, in the run where the walk was competing: `rm` on the
volume failed with "Operation timed out" -- a soft mount exhausting its retries,
which is user-visible trouble whatever the dialog does. That has not recurred
since the walk was removed.


## The BitLocker drive's five unusable names, repaired — 2026-09-04

Five entries on the owner's 247 GB BitLocker drive that answered `Input/output
error` to `stat`, `ls`, `rm`, `mv` and `mkdir` alike, and had done since an
interrupted copy days earlier. The volume mounted perfectly; nothing about it
was dirty. The guest kernel says what they are:

    ntfs3(dm-0): MFT: r=16f8, expect seq=67 instead of b1!
    ntfs3(dm-0): MFT: r=16f8, expect seq=5f instead of b1!
    ntfs3(dm-0): MFT: r=16f8, expect seq=4c instead of b1!
    ntfs3(dm-0): MFT: r=16f8, expect seq=86 instead of b1!
    ntfs3(dm-0): MFT: r=1a36, expect seq=e  instead of 14!

Five directory index entries whose MFT references keep sequence numbers the
records have moved past, pointing at two records that have since been reused.
ntfs3 refuses them, rightly -- that check is what stops a stale handle resolving
to whatever now occupies the record.

**What the app did before: nothing, for ever.** The repair rung is reached only
when a writable mount fails, and this volume mounts. The reclaim walk found all
five and could not move them -- a rename fails with EIO exactly as everything
else on those names does -- and wrote so into `.lukotta-reclaim.log`, where
nothing read it.

**Three measurements, in the order they came, two of them bad.**

    ntfsck once, on the repair rung   5599 of 5605 fixed, 2 errors left,
                                      dirty flag still set, volume unmountable
    ntfsck to convergence             pass 2 applies the bitmap update pass 1
                                      declined; Clean; volume mounts again
    the same, on the real drive       Clean -- and all five names still EIO

The third is the one that mattered and it was wrong in a way worth recording:
the check ran on the probe rung and the repair rung, and this drive reaches
neither. ntfs3 refuses it, the ladder falls through, and **ntfs-3g serves it** --
the one rung that never checked. Every run that evening repaired nothing because
the checker never saw the volume.

**After the check was put on that rung**, read from `.lukotta-check.log`, which
the check now leaves on the volume it checked:

      * Directory index: 5 corrupted entry(ies)
    Clean, No errors found or left (errors:1003, fixed:1003)

    before   5 names, every call EIO, reclaim log 5 lines of "could not move:"
    after    5 names free, mkdir succeeds on every one, reclaim log 0 lines
    holds    across an eject and reopen, still 0

**What it costs when nothing is wrong: nothing.** The check reads the whole MFT
-- 59 s on this drive -- so it runs only where the volume has asked for it, and
the volume asks by carrying that "could not move:" line. Opening the repaired
drive twice more:

    open with the check      91 s
    open, nothing asked      30 s, log says "nothing has asked for a check"
    open, nothing asked      30 s

Three things were needed to see any of this, and each had hidden the last:
`ntfsck` had to exist in the guest at all (it is not in Alpine; built from
ntfsprogs-plus); it had to run more than once, because its first pass declines
its own mass-free; and it had to run on the rung that actually serves a damaged
drive. The transcript had to be carried onto the volume as well -- every mount
attempt runs its own machine, so what the check wrote to /tmp died with the
attempt, and the mount log lives in a workspace deleted on the way out. The one
run whose words were needed was the one nobody could read back.

## BitLocker/NTFS on the Patriot stick — 2026-09-02

Opened by Lukotta with a key taken from the Keychain. Nothing was typed: the
app found the key filed under `media:Patriot-Memory:247630659584:1048576` and
used it. Served at /Volumes/BACKUP2_TS, read-write.

    corpus            205 files, 88M
                      200 small random files, one 64M file, one 3M file named
                      in Japanese/Greek/umlauts, one 180-character name, an
                      empty file, a 200M sparse file
    copy              21.3 s, exit 0
    user-visible      nothing: no stall, no dialog, no Finder complaint
    read back         6ff578a536a1d10bd28d95b7ab9b7c6a59751a16bcf7d8a4bf201484f80cceb6
                      identical on both sides — BYTE-IDENTICAL

Item 4's unlock half had never been proven on any build before this. The
Keychain lookup that makes it work is the one shipped in 1.22.0-beta.9: the
key is searched for under the volume's fingerprint, the fingerprint remembered
from last time, the volume UUID, the device node, and finally under every key
the app holds, with a refused key falling silently through to the next.

## Finder copies onto the same BitLocker stick — 2026-09-02

Copies performed by Finder, not by `cp`: the volume was already open, and
Finder was told to duplicate onto it.

    a handful of files   5 files, three separate runs
                         1.7 s, 1.5 s, 1.5 s — all five arrived every time
    a large tree         204 files, 88M, two separate runs
                         20.8 s and 25.9 s
    Finder dialogs       0, counted from the accessibility tree after each run
    read back            identical both runs — BYTE-IDENTICAL

No stall, no error, no "some items had to be skipped", at both extremes and
repeated rather than once. Items 2, 3 and 4 hold on BitLocker/NTFS.

## A dirty NTFS volume is repaired, not warned about — 2026-09-02

Volume made by the guest, 41 files written and summed, then the machine taken
away with the volume still mounted. Confirmed dirty before the app saw it.

    opened            writable, exit 0
    user-visible      nothing: no dialog, no read-only fallback, no explanation
    files present     41 of 41
    corpus digest     35e1a0431c31288689aded22cd1052d62bb0955389641d6fb22729fc79f032c3
    written to after  yes

Two runs failed before this one and neither was the app. The harness named the
repair action on an engine command line, but the app installs that action while
building a mount, so it asked for something that did not exist -- reported as
"the app could not open the dirty volume at all". And a leftover engine from an
earlier run held the device lock, which made a mount that had in fact succeeded
report failure while the volume sat mounted and writable.

## LUKS, and the Linux filesystems inside it — 2026-09-02

Same corpus each time: 123 files, one of 12M, one named in Japanese, Greek and
umlauts, an empty file. Opened by the app, copied in, read back.

    luks-ext4     LUKSEXT4    byte-identical
    luks-xfs      LUKSXFS     byte-identical
    luks2-direct  DIRECTFS    byte-identical
    luks1-lvm     HOMEFS      byte-identical

luks-multi is proven too, and took three tries to measure honestly:

    FEDORAROOT     123 files, byte-identical
    FEDORAHOME     123 files, byte-identical
    FEDORABACKUP   123 files, byte-identical

One LUKS container holding an LVM group of three filesystems, served as
subdirectories of one mount. The first run reported it byte-identical at
/Volumes/BACKUP2_TS -- a physical stick that happened to be mounted, because
the harness took the last mount in the table rather than the one that appeared.
The second run mounted nothing, and the reason was mine as well: the fixture is
partitioned, so the volume is disk5s1 and I had pointed at disk5.

## Every disk image format the app claims — 2026-09-02

Corpus of 2024 files written to each and read back, through the app's engine.

    sweep.qcow2         2024 identical, 0 differing, 0 missing
    sweep.vdi           2024 identical, 0 differing, 0 missing
    sweep.vhd           2024 identical, 0 differing, 0 missing
    sweep-dyn.vhd       2024 identical, 0 differing, 0 missing
    sweep-sparse.vmdk   2024 identical, 0 differing, 0 missing

The first run of this said "5 formats written and read back, 0 failed" while
four of them had written nothing at all, each printing "not enough room" in the
output directly above the total. Two faults, both in the harness:

  - the copy was piped through sed to indent it, so the test read sed's exit
    status, which is nought whatever happened upstream
  - the base image is kept between runs, so raising its size did nothing and
    every format was built from the old, smaller one

Raising the size then removed qcow2 instead, because that writer used a single
refcount block and could not describe more than two gibibytes. It allocates as
many as the image needs now. A format that cannot be built counts as a failure,
which is what it is.

## The shipped release, driven through its own interface — 2026-09-02

1.22.0 build 961 as installed on this Mac, notarised Developer ID, signature
verified. Driven by clicking, because the harnesses are compiled out of a
release build and there is no headless route in one.

    launches                    yes, Gatekeeper accepts it
    early-development notice    shown once, acknowledged, written to disk
                                and gone at the next launch
    engine                      set itself up from nothing on first use
    NTFS   LUKOTTANTFS          123 files BYTE-IDENTICAL
    ext4   LUKOTTAEXT4          123 files BYTE-IDENTICAL
    unencrypted volumes         identified as such, no passphrase asked for

data=journal is correctly absent from 1.22.0's ext4 mount: that fix landed
after it and ships in 1.22.1.

Two things about this run were my own instruments and not the app. Running the
release's engine binary directly produces no output at all and hangs holding
the image file open -- it needs the environment the app builds around it, so a
bare invocation is not a test of anything. And an earlier such invocation left
two engines holding a fixture, which then refused to attach; "Resource
temporarily unavailable" from hdiutil was that, not a fault in the app.

## Finder's own copy engine, both extremes, repeated — 2026-09-02

Through the released 1.22.1, driven by clicking, on volumes it opened itself.
Not ditto and not cp: the copy that broke was Finder's, and this is Finder's.

    NTFS   3 x 42 MB      1 s each cycle    3 identical, 0 differing, 0 missing
    NTFS   2000 files    25 s each cycle    2000 identical, 0 differing, 0 missing
    ext4   3 x 30 MB      3 s each cycle    3 identical, 0 differing, 0 missing
    ext4   2000 files   101 s each cycle    2000 identical, 0 differing, 0 missing

Three cycles each, 0 failures. The times do not drift between cycles -- 25, 25,
25 on NTFS and 101, 102, 101 on ext4 -- which is the part that matters: a stall
that had crept back would show as a cycle that took longer than the one before
it. No Finder dialog appeared, nothing was skipped, and nothing was left
part-written.

ext4 here is mounted data=journal, which 1.22.1 added. It is four times slower
than NTFS on the many-small-files extreme and that is the filesystem, not a
stall: it is the same on every cycle.

## XFS loses fsynced data too, and the fix is not free — 2026-09-03

XFS has the same fault ext4 had:

    XFS as it mounts    8 of 8 fsynced files present, 8 wrong, 0 of 30 in-flight complete
    XFS with sync       8 of 8 present, 0 wrong,     30 of 30 in-flight complete

The cost, measured through the same path both times -- the app's own mount,
served by the helper, 2000 small files:

    prod 1.22.1, no sync                44 s
    beta 1.22.2-beta.1, sync            65 s

That is 48% slower on the many-small-files extreme. It is not nothing, and an
earlier note in this file said it was: 2 seconds either way. That number was
taken through the raw engine mounted unelevated into ~/Volumes, which is not
the path the app uses, so it was not a comparison at all. The 44 and 65 above
are the same path, same corpus, same machine.

**The decision, and it is a trade rather than a fix.** sync stays, because
losing the contents of files that were fsynced is data loss and 48% on one
extreme is not. But item 10 says no UX cost anywhere, and this is one, so this
is not where XFS should end up.

**The root is not yet known, and I said it was.** I wrote here that both
filesystems lose fsynced data because the guest's flush does not reach the
image, and that is not something I measured. Against it: the block layer's
FLUSH already calls flush and then sync on the file, for images as well as raw
devices; the guest's export carries no `async`, so nfsd should be committing;
and NTFS through the identical path loses nothing. So the flush does appear to
arrive, and what differs is what each filesystem does with it.

What is actually established is narrower, and it is this:

    ext4 and XFS lose fsynced file contents when the machine dies
    NTFS, same guest, same accident, does not
    data=journal fixes ext4; sync fixes XFS; each costs what is written above

btrfs is unmeasured -- there is no fixture for it on this machine -- so whether
it shares the fault is not known either way.

## exFAT, and the engine's shell mode — 2026-09-03

exFAT loses fsynced content the same way ext4 and XFS do, and `sync` fixes it
the same way:

    exFAT as it mounts   8 of 8 fsynced files present, 8 wrong
    exFAT with sync      8 of 8 present, 0 wrong, 30 of 30 in-flight complete

Nobody reaches that through the app. exFAT is the one format handed to macOS to
mount, so the app never serves it through the guest, and the fault is in the
engine rather than in anything a person using Lukotta can hit.

Three of the four filesystems tested lose it, and only NTFS does not, which is
worth writing down because it says the fault is general rather than something
about ext.

**The engine's `shell` truncates a sparse image, and `mount` does not.**
Formatting a 2000 MB sparse image through `shell` left it 1024 MB; formatting
the result again left it 92 MB. It is being cut back to its allocated size each
time, which is why a btrfs volume made this way would not mount afterwards: the
superblock described a device larger than the file.

`mount` was measured for the same thing and does not do it:

    sparse image, 2000 MB apparent, 89 MB on disk
    before a mount attempt   2097152000 bytes
    after                    2097152000 bytes, 89 MB on disk

So no drive or image a person opens is at risk. `shell` is a maintenance path
the app never uses, and `scripts/format-write-sweep.sh` already guards against
this -- it checks the size after formatting and says "the image was truncated by
formatting". Nothing else did.

**btrfs is still unmeasured for durability.** Every attempt to build a fixture
for it went through `shell`, so every fixture was truncated and would not mount.
btrfs itself works through the app -- luks2-direct is btrfs and copied 123 files
byte-identical -- so this is a gap in the fixture, not a known fault.

## Which filesystems keep what they were told to keep — 2026-09-03

The whole set, each run through the same eleven vectors on this Mac, each with
the machine killed while writes were in flight:

    NTFS       durable as it mounts     8 of 8 fsynced files, 0 wrong
    btrfs      durable as it mounts     8 of 8, 0 wrong, 0 lost
    ext4       loses everything         8 of 8 present, 8 wrong  -> data=journal
    XFS        loses everything         8 of 8 present, 8 wrong  -> sync
    exFAT      loses everything         8 of 8 present, 8 wrong  -> sync
               (never served by the app; macOS mounts it)

btrfs was measured through luks2-direct, which holds btrfs inside a LUKS
container, after every attempt to build a plain fixture was truncated by the
engine's shell. 11 of 11 vectors passed with no mount option at all.

This is the answer to whether the option should simply go on everything: no. Two
of the five need nothing, and btrfs would have paid the 48% that sync costs for
a fault it does not have. Asking the volume what it needs is worth the code.

## What the fsync fault is not — 2026-09-03

Ruled out, each by measurement rather than reasoning:

    wsync on XFS            8 of 8 fsynced files still wrong. Metadata-only
                            sync is not enough, so the loss is data, not
                            directory entries.
    the block FLUSH         The krun flush patch is applied -- every patch in
                            patches/ is, and the engine binary post-dates it --
                            so the guest's flush is being answered with a real
                            flush and sync of the image. It is not discarded.
    a general fault         btrfs and NTFS survive the identical accident on
                            the identical path. Whatever this is, it is not
                            something every filesystem is subject to.

So the remaining candidates are between the guest's page cache and the image:
what nfsd does with a COMMIT, and what ext4 and XFS do with an fsync that btrfs
and ntfs3 do differently. The next cheap test is whether a file written and
fsynced from inside the guest -- no NFS in the path at all -- survives the same
kill. If it does, the fault is in the NFS layer; if it does not, it is below.
That test needs a fixture the engine's shell will not truncate.

## Where the fsync fault actually is — 2026-09-03

The same ext4 image, the same machine killed the same way, the same operation
-- `dd conv=fsync`, per file, no global sync anywhere:

    written inside the guest      8 ok, 0 wrong, 0 missing
    written over NFS              8 present, 8 wrong

So it is not ext4. The filesystem keeps what it was told to keep when the write
reaches it directly. What loses it is the path between the macOS client's fsync
and the guest's file.

A first version of this test used `sync` inside the guest, which flushes
everything and is a stronger operation than fsyncing one file. That was not a
comparison and the conclusion drawn from it did not stand. This one uses the
same call on both sides.

What this means for the two options already shipped: data=journal on ext4 and
sync on XFS both work by making the guest write through, which covers for
whatever the NFS path is not doing. If the NFS path were fixed, neither would
be needed -- and the 48% that sync costs on XFS would go with them, which is
the only thing in this file still standing against item 10.

Still unknown: which link in that path. The macOS client is given no async
option; the guest runs kernel nfsd, whose export default is sync; and the block
layer's FLUSH is patched and applied. One of those three is not doing what its
documentation says, and which one is the next thing to find out.

## Narrowing it: what holds the data — 2026-09-03

Two more eliminated, each by a run rather than by reading:

    a 20-second wait after fsync, before the kill
        4 files, 0 ok, 4 wrong, 0 missing. The macOS client is not sitting on
        it: twenty seconds is long past any client write-behind.

    sync named explicitly in the export
        rw,sync,no_subtree_check,all_squash,anonuid=0,anongid=0,insecure --
        the same string --ignore-permissions produces, with sync added.
        8 of 8 still wrong. So the export was already synchronous and this is
        not the link either.

    (An earlier attempt at this used no_root_squash, which is not what
    --ignore-permissions produces. It broke five other vectors on permissions
    and told us nothing. This one uses the right string.)

The signature is worth recording because it is narrow: **the files are all
present and all the right length, and their contents are wrong.** Metadata
reaches the image and data does not. Whatever is holding those blocks lets the
inode through.

So: not the filesystem, not the client, not the export, not a discarded block
flush. What is left is between nfsd's COMMIT and the bytes landing in the image
file -- and the fact that a write made inside the guest lands while the same
write made through nfsd does not.

## The last link, and why it is not the fix — 2026-09-03

The macOS client mounted synchronous keeps the data:

    client as it mounts     4 of 4 fsynced files wrong
    client mounted sync     4 of 4 kept, 0 wrong

And with the client synchronous, the guest needs no option at all:

    ext4, client sync, no data=journal    11 of 11 vectors, 8 of 8 fsynced kept
    XFS,  client sync, no -o sync         11 of 11 vectors, 8 of 8 fsynced kept

So the whole fault is the client sending its writes unstable and the COMMIT
that follows not making them durable. That also explains the twenty-second
wait changing nothing: the writes had already left the client and were sitting
on the server.

**It is still not what to ship.** The cost, same path, same corpus:

    2000 small files      3 s either way
    2024 files, 1 GB      12 s -> 17 s, 42% slower

One option covering every filesystem is the shape this should have. But ext4's
data=journal costs nothing measurable, so moving ext4 onto a synchronous client
would take it from nothing to 42%, and XFS would be swapped from 48% to 42%.
That is a worse trade for most drives, so the per-filesystem options stay.

**What would be free is fixing the COMMIT itself.** Only fsync would pay,
rather than every write. That is server-side, in the guest, and it is the one
route left that could retire both options and close item 10 with no cost at
all.

## The COMMIT is sent, and answered, and does not commit — 2026-09-03

    nfsstat -c, Commit counter    155490 before, 155494 after
                                  four writes fsynced, four commits sent

So the client asks. The server answers. And the data is still wrong after the
machine is killed.

With the client mounted synchronous the same writes go as FILE_SYNC -- the
server must put each one down as it arrives, rather than caching it and being
asked to commit later -- and everything survives. That is the difference, and
it is the whole of it:

    writes UNSTABLE, then COMMIT     0 of 4 kept
    writes FILE_SYNC                 4 of 4 kept

The guest runs kernel nfsd (rpc.nfsd and exportfs are both in the rootfs, and
nfsd is built into its kernel), the export carries no async and naming sync
explicitly changes nothing, and the shipped engine's own PATCHES record lists
krun-devices-raw-device-flush, so the block flush is in the binary that was
measured.

Everything up to the COMMIT is doing what it says. The COMMIT itself is not,
and that is where the free fix is: make it durable and only fsync pays, rather
than every write paying as it does with a synchronous client.

## One more eliminated: the export file is the one that is read — 2026-09-03

The guest writes its exports to /tmp/exports, and /etc/exports in the rootfs is
a symlink to it, so exportfs reads what vmproxy wrote. The options do apply --
which was already visible in the run where changing them changed permissions.

So naming sync in the export genuinely did not help, and that is a fact about
nfsd rather than about the plumbing: a sync export stops the server replying
before an operation is stable, and does not force a client's UNSTABLE write to
be written stably. The client asking for UNSTABLE and then committing is a
different path from the client asking for FILE_SYNC, and only the second one
survives here.

Everything cheap that can be measured from the host is now measured. What is
left needs the guest instrumented -- what nfsd does with the COMMIT, and
whether a virtio flush follows it -- and that is a bigger piece of work than
anything attempted tonight.

## An encrypted drive was losing everything it was told to keep — 2026-09-03

ext4 inside a LUKS container, machine killed mid-write:

    before    8 of 8 fsynced files present, all 8 wrong, 0 of 30 in-flight complete
    after     8 of 8 present, 0 wrong, 30 of 30 in-flight complete

The fix that shipped for a bare ext4 never reached this. The option is chosen
by reading the filesystem's superblock and a container hides exactly that, so
the answer was always "nothing" and nothing was applied. The code said as much
in a comment and nobody had run it.

A container now asks the client for stable writes instead, which works whatever
is inside. Verified in the built app, on the command it actually runs:

    luks-ext4.img    --nfs-options=...,noowners,sync   (client asked)
    plain-xfs.img    -o sync on the guest mount only   (cheaper option kept)

Only containers pay for it. 2000 small files cost the same either way; a corpus
with a gigabyte in it goes from 12 seconds to 17.

## Item 9 across encrypted drives — 2026-09-03

With the fix that ships in 1.22.3, every vector on both:

    LUKS -> ext4    11 of 11, 8 of 8 fsynced kept, 30 of 30 in-flight complete
    LUKS -> XFS     11 of 11, 8 of 8 fsynced kept, 30 of 30 in-flight complete

The first LUKS run showed two failures beside the durability one -- a killed
copy reporting "0 whole, 0 wrong" and the unmount vector failing after it. Both
were the same timing artefact: a container takes longer to open, so the copy had
not begun when the knife came down, and the vector after it had nothing to check.
Neither reappears once the mount is up. Recorded because "0 whole, 0 wrong" reads
like a pass and is not one.

So the eleven vectors now pass on: NTFS, ext4, XFS, btrfs, exFAT, LUKS->ext4 and
LUKS->XFS.

## A dozen volumes at once — 2026-09-03

Twelve volumes opened together, then written to all at once and read back:

    engines               24 processes, two per mount
    memory                1869 MB in total, 78 MB each
    written at once       123 files to each of the twelve, in 2 s
    read back             byte-identical on all twelve
    shell responsiveness  28 ms for a trivial command, under that load

**This is not item 8 and does not claim to be.** Item 8 asks for this on an
8 GB M1, and this Mac is not one. What it does give is the number that decides
whether it would fit: a dozen volumes cost 1.87 GB, which leaves about six on
an eight-gigabyte machine. That is evidence and not proof, and item 8 stays
open until it runs on the machine it names.

Two of my own faults, both worth having written down:

  - The first pass reported "byte-identical on 0 volumes, wrong on 1" and wrote
    everything in 0 seconds. This shell is zsh, which does not word-split an
    unquoted parameter, so the whole list of twelve mount points was one
    iteration. Read from a file now.
  - CROWD1 then differed with 117 of 123 files. It was full: earlier runs had
    left rd-busy and rd-quiet on it. Cleared, it is byte-identical like the
    rest. A volume with no room reads as a data fault and is not one.

**A third fault, found later and worth more than either.** Those twelve were
opened through the engine directly -- twenty-four processes, two per mount --
and the engine takes an address as it finds one. The app does not: it asks the
daemon for twelve loopback addresses first, and until 1.22.7-beta.2 the daemon
counted `::1` and `fe80::1` among them and stopped at ten. So the app could
never have opened twelve, and this measurement did not touch the path that
would have shown it. The memory figure stands. The claim that a dozen can be
open at once was, on the app's own route, two short.

## The block device does advertise a cache — 2026-09-03

Read from inside the guest:

    /sys/block/vda/queue/write_cache    write back
    /sys/block/vda/queue/fua            0

So the device tells the kernel it has a volatile write cache, and the kernel
therefore issues a flush on fsync rather than skipping one. That was the last
cheap explanation and it is gone: nothing in the chain is failing to ask.

The contradiction is now sharp, and it is worth stating exactly because it is
where the next attempt has to start:

    dd conv=fsync, inside the guest, on /mnt        8 of 8 kept
    dd conv=fsync, over NFS, on the same volume     8 of 8 wrong

Same device, same filesystem, same flush mechanism, same kill. The only thing
that differs is whether nfsd is in the path. Everything measurable from the
host says each link does what it claims, so what is left is what nfsd actually
does with a COMMIT -- and answering that needs the guest instrumented while a
mount is live, which is a change to the mount script rather than another run.

## The guest instrumentation attempt, which produced nothing — 2026-09-03

To see what nfsd actually exports at runtime, the guest's entrypoint was given
a few lines to print /etc/exports and `exportfs -v` after it runs `exportfs -ar`.
The edit was to the dev engine home's rootfs only, never to anything shipped,
and it has been put back.

It produced no output. The engine does not surface the guest's stdout on an
ordinary mount -- its own stdout is the progress spinner and nothing else --
and there is no way to run a command inside a live machine: `anylinuxfs` offers
`shell`, which starts a separate machine with no nfsd in it, and `status` and
`list`, neither of which reach inside.

So this is not evidence either way. The export table at runtime is still
unread, and reading it needs either the engine's own logging turned up in a way
that reaches the guest, or the mount script changed to carry a diagnostic --
which is a product change and not something to do casually.

What is known about the export remains what was measured from outside: naming
sync in it changes nothing, the file is written by vmproxy and read by
`exportfs -ar` through a symlink at /etc/exports, and the entrypoint adds no
options of its own.

## The export is sync, read from the server itself — 2026-09-03

The guest's entrypoint was instrumented again, this time reading the engine's
own log file rather than its stdout, which is where guest output goes. It
worked, and the answer is unambiguous:

    /mnt/LUKOTTAEXT4
       <world>(sync,wdelay,hide,no_subtree_check,anonuid=0,anongid=0,
               sec=sys,rw,insecure,root_squash,all_squash)

So the export really is synchronous, as the server itself reports it. That was
the last inference in the chain and it is now a measurement.

`no_wdelay` was then tried, since wdelay was the one option in that list never
tested for this: 8 of 8 still wrong. It is not that either.

The state of it, with everything now measured rather than assumed:

    export                      sync, confirmed by exportfs -v in the guest
    COMMIT                      sent by the client, counter moves
    block device                advertises a write-back cache
    krun's FLUSH                patched, and the patch is in the shipped binary
    filesystem                  keeps the same fsync when written to directly
    result                      the data is still lost

Every link reports doing its job and the outcome says one of them is not. The
next step is inside nfsd's COMMIT path, and the way in is now known: instrument
the guest's entrypoint, read the engine's log file in Library/Logs, not stdout.

## The same machine, the same moment, both kinds of write — 2026-09-03

Every earlier comparison used two machines: one VM for the in-guest write, a
different VM for the NFS write. That is a confound, and this removes it. The
guest's entrypoint was made to write and fsync four files into the volume while
it was serving NFS, and four more were written over NFS from macOS with the
identical `dd conv=fsync`, and then the machine was killed.

    inguest_files=4   inguest_consistent=1
    overnfs_ok=0      overnfs_wrong=4

One VM. One filesystem. One kill. One call. The four written from inside are
whole; the four written through nfsd are wrong.

So it is nfsd, and that is no longer an inference from two runs that might have
differed in some other way. Everything else in the chain has been measured
doing its job: the export is sync as the server itself reports it, the client
sends COMMITs and the counter moves, the block device advertises a write-back
cache, and krun's flush patch is in the shipped binary.

The method that got here is worth keeping: instrument
`.anylinuxfs/alpine/rootfs/usr/local/bin/entrypoint.sh` in the dev engine home,
and read the engine's log in `Library/Logs`, not its stdout. Put the file back
afterwards.

## What the guest looks like while it serves — 2026-09-03

Read live, from inside the machine that is serving the volume:

    tmpfs /mnt tmpfs rw,relatime
    /dev/vda /mnt/LUKOTTAEXT4 ext4 rw,relatime
    nfsd versions: +3 +4 +4.1 +4.2

The volume is mounted with nothing unusual -- `rw,relatime`, which is
`data=ordered`, exactly as expected for a mount with no durability option
applied. Both NFS 3 and 4 are enabled and macOS chooses.

Nothing here is anomalous, and that is the finding: there is no misconfiguration
left to blame. The guest mounts the filesystem normally, exports it
synchronously, runs a stock kernel nfsd, and sits on a block device that
advertises a cache and a host that honours its flushes. A write fsynced from
inside that machine lands. The same write fsynced through its nfsd does not.

That is as far as this goes without tracing inside the kernel's nfsd, which is
a different kind of work from anything done here. The three mount options stay
until it is done, and the two UX costs they carry stay with them.

One practical note for whoever picks this up: the engine's log in Library/Logs
exists only while the engine runs and is removed when it exits, so read it with
the mount still up.

## XFS costs nothing after all, on the other mechanism — 2026-09-03

The 48% XFS was paying was a property of *how* it was fixed, not of fixing it.
Same path -- the app's own, helper-served -- same corpus of 2000 small files:

    no durability option        44 s
    guest -o sync   (shipped)   65 s
    client sync     (now)       43 s

Durability is the same either way: 11 of 11 vectors with client sync and no
guest option, 8 of 8 fsynced files kept, 30 of 30 in-flight complete.

So XFS moves onto the mechanism containers already use, and the cost it was
carrying disappears. That is one of item 10's two violations gone, and it went
because the cheap comparison was finally run on the path that matters rather
than on the raw engine, where every option looks free.

Three mechanisms become two:

    ext with a journal      data=journal, costs nothing
    XFS, and anything the
    app cannot see inside   client asked for stable writes

## What stable writes cost an encrypted drive, on the app's own path — 2026-09-03

Measured with a temporary switch in a dev build, both halves on the app's path,
2000 small files:

    LUKS -> ext4, without stable writes    61 s
    LUKS -> ext4, with stable writes       60 s

Nothing. The same inversion as XFS: the earlier figure of 12 s to 17 s was
taken on the raw engine path and with a corpus carrying a gigabyte-apparent
sparse file, and it does not describe what the app does.

The heavy corpus could not be run here for the comparison: the LUKS fixture is
about a gigabyte and the corpus needs 1089 MB of it. So the honest statement is
that containers pay nothing on the many-small-files extreme, and the large-file
extreme is unmeasured on this path rather than known to be free.

The temporary switch was reverted and is not in the tree.

## The large-file extreme on an encrypted drive, both ways — 2026-09-03

The one comparison that was still missing, on a 2400 MB LUKS fixture with room
for the whole corpus, both halves on the app's own path:

    heavy corpus, with stable writes       399 s, 2024 identical, 0 differing
    heavy corpus, without stable writes    390 s, 2024 identical, 0 differing

Two per cent apart, which is noise. The 399 seconds is what it costs to write a
gigabyte-apparent corpus into an encrypted container, and it is not what the
option costs.

So both figures that stood against item 10 are gone, and neither went by
argument:

    XFS         48% -> nothing, by changing the mechanism (shipped in 1.22.4)
    containers  the 12-to-17 figure was the wrong path; on the app's path it is
                61 vs 60 seconds on small files and 399 vs 390 on the heavy one

The durability work adds no click, no prompt, no message, and no fallback. On
the evidence here it costs nothing measurable either.


## CORRECTION: three A/B runs were void, and 1.22.4 shipped a regression

The switch I added to compare stable writes on and off went into `Mounter.swift`.
The `--drive` route does not go through Mounter -- it goes through the
privileged helper -- so the switch never applied and both halves of every
comparison had stable writes on. These are void and must not be believed:

    LUKS+ext4, 61 s vs 60 s, 2000 small files
    LUKS+ext4, 399 s vs 390 s, heavy corpus
    XFS large file, 3 MB/s vs 3 MB/s

What is true, measured directly through the engine on a fresh XFS volume with
the mount table checked for `synchronous` each time:

    no option        190 MB/s on a large file
    guest -o sync    190 MB/s on a large file
    client sync        3 MB/s on a large file

A synchronous client writes a large file at a sixtieth of the speed. The
earlier "95 MB/s with sync" was a stale mount that was not synchronous at all;
the mount table said so and I had not looked.

So **1.22.4 shipped a regression**: it moved XFS from the guest option onto a
synchronous client on the strength of a small-files measurement, and large
files on XFS went from 190 MB/s to 3. 1.22.3 put encrypted drives on the same
mechanism and they have the same fault.

Both now use the guest's `-o sync`, which is 190 MB/s on large files and costs
about half a minute on two thousand small ones. `sync` is a VFS option and
means the same to whatever filesystem is inside a container, so one answer
covers both.

The lesson, and it is the same one as the four instrument faults: check that
the thing you are varying actually varied. The mount table said `synchronous`
and I did not read it until the numbers stopped making sense.

## Large writes: what is measured, and what is still open — 2026-09-03

With the 1.22.5 fix in place (client sync gone, guest `-o sync` back), on a
fresh 2000 MB XFS volume, 190 MB written:

    through the app (helper-served, /Volumes)        7 MB/s
    through the engine directly (~/Volumes)        190 MB/s

Same filesystem, same volume, and the engine run used the app's exact option
string -- rsize, wsize, readahead, dumbtimer, timeo, retrans, deadtimeout,
mutejukebox, noowners -- with and without `-o sync`. All three raw-engine
variants managed 190 MB/s, so the options are not what makes the difference.

And the app path is not slow in general: NTFS through the app writes the same
file at 190 MB/s.

So what is left is XFS specifically, on the helper-served mount. That is not
explained here and is not claimed to be.

Two corrections to earlier numbers in this file, both mine:

  - The "3 MB/s" figures were the app path; the "190 MB/s" ones were the raw
    engine. Comparing them to each other was comparing two different things,
    and it is what made client sync look sixty times worse than it is. On one
    path, with a real flush, it is three times worse -- 63 MB/s against 190.
  - Several raw-engine writes finished in one second because `cp` returns
    before anything is flushed. `dd conv=fsync` is what makes a write
    comparable, and the numbers above that say "fsynced" use it.

The 1.22.4 regression was real regardless: the app path went from whatever it
was to 3 MB/s on large files, and it is back on the guest option now.

## The real cost of durability on a large file, all one path, all fsynced

App path, 190 MB written with `dd conv=fsync`, each filesystem with whatever
option it actually gets:

    NTFS, no option           190 MB/s
    ext4, data=journal         63 MB/s
    XFS,  guest -o sync         7 MB/s
    XFS,  client sync           3 MB/s   (what 1.22.4 shipped)

So 1.22.5 moved XFS from 3 to 7 MB/s, which is better and is not "free". My
earlier note said the guest option cost XFS nothing on large files. That came
from the raw engine path, where the same run reports 190 MB/s -- and I have no
way to confirm the guest option was even applied there, because it is a mount
option inside the machine and does not appear in the mount table the way the
client's `sync` does. It should not have been believed and the note above
supersedes it.

**Where that leaves item 10.** Durability costs something on two of the four:

    ext4    a third of the speed on a large file
    XFS     a twenty-seventh

NTFS and btrfs pay nothing because they need nothing. The XFS number is bad
enough that the route is probably still wrong, and the honest position is that
item 10 is not met for XFS, rather than that the cost has been argued away --
which is what I did twice tonight.

## The XFS cost is the helper's mount, not the option — 2026-09-03

The engine's own path, XFS with `-o sync`, 190 MB written with `dd conv=fsync`,
run with the helper's exact flags one at a time:

    -o sync only                    95 MB/s
    -o sync + the tuned action      95 MB/s
    -o sync + vmnet                190 MB/s
    -o sync + tuned + vmnet        190 MB/s

And the option is genuinely applied on that path: the same mount passes the
power-loss vector, 8 of 8 fsynced files kept, 11 of 11 vectors.

Through the app -- the same volume, the same flags, the same engine binary --
the same write is 7 MB/s. And the app's path is not slow in itself: NTFS
through it writes at 190 MB/s.

So the twenty-sevenfold cost belongs to `-o sync` **on the helper-served
mount**, and to nothing else that has been varied. What differs there is that
the helper runs the engine as root and the share lands in /Volumes rather than
~/Volumes. That is where to look next, and it has not been looked at.

This matters more than it looks: if the slowness is the helper's mount rather
than durability itself, then item 10 may be reachable for XFS after all, and
the option is not the thing to blame.

## What is left to try on the XFS cost, and what not to try blind

Everything varied so far is identical on both paths: the flags, the tuned
action, the NFS server thread count, the guest's max block size, the engine
binary, the volume. The engine's own mount is fast with `-o sync`; the
helper's is not.

The two things that differ and have not been isolated:

  - the helper runs the engine as root
  - the share lands in /Volumes rather than ~/Volumes

Isolating those needs a mount into /Volumes made by hand, which needs admin
rights this session does not have.

**One candidate, and a reason not to reach for it tonight.** The app writes
with `wsize=32768`. Under `-o sync` every one of those 32 KB writes is a
separate synchronous round trip, so a path with higher latency would suffer
far more than a quick one -- which is the shape of what is measured. Raising
wsize for volumes that carry a durability option is the obvious thing to try.

It is also the thing that was deliberately lowered to stop the stall: SPECS
records that cutting the write size is what keeps the folder being copied into
answering, and that 16384 was no better and 32768 was the size that worked. So
raising it risks bringing back the fault this whole effort began with, and it
must be measured against the stall as well as against throughput -- not shipped
on a hypothesis at five in the morning.

## Verifying what 1.22.5 actually changed — 2026-09-03

1.22.5 moved encrypted drives from a synchronous client onto the guest's
`-o sync`, and that mechanism had not been checked for the thing it exists to
do. Checked now:

    LUKS -> ext4, guest -o sync   11 of 11, 8 of 8 fsynced kept, 30 of 30 in-flight
    LUKS -> XFS,  guest -o sync   11 of 11, 8 of 8 fsynced kept, 30 of 30 in-flight

So the change is safe as well as faster. Written down because not checking this
is exactly what put the regression into 1.22.4: a mechanism was swapped on the
strength of one measurement and the thing it was there for was never re-run.

## Settled: the XFS cost is the helper's mount, and nothing else — 2026-09-03

Every option the app uses, applied to the engine's own mount, XFS with
`-o sync`, 190 MB written with `dd conv=fsync`:

    minimal options                  95 MB/s
    the app's full option string    190 MB/s
    app options + tuned + vmnet     190 MB/s

And `-o sync` is genuinely in force on that path: the machine was killed
straight after one of those writes and the file came back whole.

The same write through the app is 7 MB/s. Reads through the app are 190 MB/s,
so the path is not slow in general -- only writes, and only while the guest is
synchronous. NTFS through the app, which is not synchronous, writes at 190.

So the cost belongs to `-o sync` on the helper-served mount and to nothing that
has been varied: not the options, not the tuned action, not vmnet, not the
filesystem, not the volume, not the binary. What is left is that the helper
runs the engine as root and the share lands in /Volumes rather than ~/Volumes.

That is a thirteen- to twenty-sevenfold difference produced by the mount path
alone, and it is the whole of item 10's remaining gap. It is also good news:
the durability option is not expensive, so there is nothing to trade away --
something about the elevated mount is wrong, and fixing it should give both.

## Slow is not the same as broken — 2026-09-03

Finder's own copy engine, on the app's own XFS mount, the one running at about
8 MB/s:

    cycle 1  3 x 306 MB   114 s   3 identical, 0 differing, 0 missing
    cycle 1  2000 files    81 s   2000 identical, 0 differing, 0 missing
    cycle 2  3 x 306 MB   117 s   3 identical, 0 differing, 0 missing
    cycle 2  2000 files    88 s   2000 identical, 0 differing, 0 missing

Two cycles, both extremes, no failures. No Finder dialogue, nothing skipped,
nothing part-written, and the times do not drift between cycles.

So the helper-mount slowness is a throughput cost and not a stall: the machine
keeps answering, macOS never marks the mount as not responding, and Finder
never says a word. Item 3 holds on this volume. Item 10 does not, and the two
are different failures -- worth separating, because "slow" was about to be
written down as though it were "broken".

## A clean regression run, and two failures that were mine — 2026-09-03

The whole end-to-end suite against the current code, every change of the night
included:

    868/868 steps passed, 0 failures

Two runs before it reported failures, and neither was the app:

  - **"thirty-two megabytes can be written -- the volume is out of space."**
    The NTFS fixture was 100% full of files I had written during the night's
    measurements: a 191 MB one, a 104 MB one, a 22 MB directory. The e2e suite
    does not clear it between runs and nothing else did either.

  - **"it is identified again (gave up after 60s)."** A timeout on a machine
    with several engines and a wrecked volume on it, not a fault that
    reproduced.

Trying to clear that fixture found something worth keeping. Deleting its
contents appeared to work -- `df` showed the space back -- and the files were
all there again on the next mount, because the machine had been killed before
the unlinks reached the image. The fault this whole effort is about, applied to
my own housekeeping.

Then the volume stopped answering at all: `ls` and `rm` both returned
"Operation timed out" on a volume with 12 KB free that had been kill-9'd
mid-write many times over. It was rebuilt rather than diagnosed, because a
fixture destroyed by testing is not evidence about the product -- but a volume
that times out rather than erroring when full is worth remembering.

## A full volume, on a fresh one — 2026-09-03

The concern raised above -- a volume that times out rather than erroring when
full -- does not reproduce on a volume that has not been wrecked. Fresh NTFS
through the app, filled to the last block:

    dd                      "No space left on device", a proper error
    ls when full            26 ms
    rm when full            20 ms, and it worked
    space back              317 MB, five seconds later
    a 50 MB write after     succeeded

The "8 KB free" reading immediately after the delete was a cached statfs, not a
volume that had failed to free anything. So the timeout was the fixture I had
destroyed and nothing else, and item 3 holds here: full is an error, promptly,
and the volume keeps answering throughout.

## Found it: `-o sync` is cheap on a file and ruinous on a device — 2026-09-03

The whole hunt ends here. XFS, 190 MB written with `dd conv=fsync`, the only
thing varied being what the engine was pointed at:

    device node, no -o sync      190 MB/s
    device node, with -o sync      4 MB/s
    image file,  with -o sync    190 MB/s

Forty-seven times, and it is not the helper, the mount point, the privileges,
the network helper, vmnet offloading, the tuned action, the NFS version, the
options, or the filesystem. Every one of those was eliminated. It is what the
engine has underneath it.

**Why.** On an image file, a flush is an fsync on a file, which lands in macOS's
page cache and is cheap. On a device node it is a real device sync -- that is
what `krun-devices-raw-device-flush` exists to make honest -- and `-o sync`
turns every single write into one. So the cost is one true device sync per
write, and no amount of tuning above it will help.

**Why it matters.** Every real drive is a device. All my earlier "the option is
free" measurements were on image files, which is precisely the path a person
never uses. That is the third time tonight the same error produced a wrong
conclusion, and this is the one that matters most.

**What it says about the route.** `data=journal` is cheap because ext4 batches
data into its journal and flushes once. `-o sync` is dear because it flushes
per write. XFS has no batching equivalent, so on XFS there is no cheap word --
and the answer is not a better mount option but the thing underneath: nfsd's
COMMIT, which is where the durability is being lost in the first place. Fix
that and no filesystem needs an option and nothing pays anything.

## The trade on a real drive, stated exactly — 2026-09-03

The last thing to check was whether the fault even exists on a device, since
every earlier durability measurement was on an image file. It does. XFS on a
device node, four files written with `dd conv=fsync`, machine killed:

    no durability option      0 of 4 kept, 4 wrong
    with -o sync              durable, and 4 MB/s

So on the drives people actually own there is no free choice. Either fsynced
files are lost when the Mac dies, or every write costs a real device sync.

That is the whole of item 10's remaining gap, stated exactly:

    ext4    data=journal batches into the journal, so it is cheap
    XFS     has no batching equivalent, so it pays per write on a device
    NTFS    needs nothing
    btrfs   needs nothing

The route out is not a mount option. It is nfsd's COMMIT: a write fsynced from
inside the guest lands, and the same write through nfsd does not, and if that
were fixed no filesystem would need an option and nothing would pay anything.
Everything measured tonight points at that one place.

**The decision stands as shipped.** XFS keeps `-o sync`. Losing files somebody
was told were saved is worse than a slow large copy, and the slow copy is at
least visible and finishes -- 2 cycles of Finder at both extremes passed with
no dialogue and no drift. But item 10 is not met for XFS, and this is why, and
it is not going to be argued away.

## The complete model, verified on both backings — 2026-09-03

    on an image file                    on a device node
    ----------------------------------  ----------------------------------
    in-guest fsync   8 of 8 kept        in-guest fsync   4 of 4 kept
    through nfsd     8 of 8 wrong       through nfsd     4 of 4 wrong

The same on both. So the fault is nfsd's COMMIT and nothing to do with what the
engine is sitting on -- that only decides what the workaround costs:

    -o sync on an image file    190 MB/s   (a flush is an fsync on a file)
    -o sync on a device           4 MB/s   (a flush is a real device sync)
    data=journal, ext4 only       cheap    (ext4 batches into its journal)

Four measurements, four filesystems, both backings, and every alternative
eliminated one at a time. This is as far as the fault can be traced from
outside the guest kernel, and it is a single component: nfsd receives a COMMIT,
answers it, and the data is not durable -- while the identical fsync issued
inside the same machine, on the same volume, in the same instant, is.

## NFSv4 refused, and why it is still the most promising route — 2026-09-03

The guest's nfsd offers `+3 +4 +4.1 +4.2`, and the fault is in v3's
write-then-COMMIT path, so v4 was worth trying: its writes and commits work
differently and might not carry the fault at all.

    mount with vers=4    mount_nfs: Invalid argument (22)

NFSv4 has no MOUNT protocol and needs a pseudo-root -- an export with `fsid=0`
that the client walks down from. The guest writes one export line per volume
and no root, so there is nothing for a v4 client to attach to.

That is a change to how vmproxy builds `/tmp/exports`, which is a patch against
the engine and wants its own testing rather than a quick edit. It is recorded
here as the most promising route because it is the only candidate that could
remove the fault rather than paper over it, and the papering-over is what costs
a real drive forty-seven times its speed.

## NFSv4 has the same fault — the route is closed — 2026-09-03

The note above called NFSv4 the most promising route. It is not, and this is
the run that says so.

The v4 mount failed at first with EINVAL, which was the client's `nolocks`
option and not v4 -- v4 has integrated locking and rejects it. Given a
pseudo-root in the guest (`/mnt` exported with `fsid=0`, added by hand for the
experiment) and dropped `nolocks`, macOS mounts v4 happily:

    the share mounts, and the mount table lists it as an ordinary NFS mount

Four files written with `dd conv=fsync` over that v4 mount, no guest option at
all, machine killed:

    NFSv4, no guest option:  ok=0  wrong=4  missing=0

The same as v3. So the loss is not in v3's write-then-COMMIT path, and building
the pseudo-root into the engine would have bought nothing. That patch does not
need writing, which is worth more than it sounds.

What that leaves: the fault is in nfsd generally or below it, on both protocol
versions, both backings, and three of five filesystems -- while an fsync issued
inside the same machine at the same moment is durable every time.

## Repeatability, and what limits it — 2026-09-03

Item 9 says a happy path twice is not proof, so the vectors were run again:

    NTFS                        11 of 11, twice in a row
    ext4 with data=journal      11 of 11 on a clean volume
    ext4 without the option     the fsync vector fails, as it should

The fsync vector is the one that matters and it passes with the option and
fails without it, which is the fix doing exactly its job.

What stops a clean second run is fixture hygiene, not the app. These vectors
need 200 MB free, write 80 MB, and then deliberately fill the volume; the
fixtures are 320 MB to 2 GB and every run of the night left something on them.
Three separate "failures" chased tonight were that:

    "0 whole, 40 wrong"      a volume whose operations were timing out, so cmp
                             read failures and counted them as corruption
    "out of space"           an NTFS fixture holding 300 MB of my own files
    "52 MB free"             an ext4 image carrying leftovers into every copy

None of them was the product, and each looked exactly like it was. The vectors
now refuse a volume too small for them and clear what a stopped run left, which
catches the second and third; the first needs a fixture rebuilt rather than
reused, and a volume worn out by repeated kill-9s should simply be thrown away.

## Item 9, twice on every filesystem — 2026-09-03

With the harness giving each run its own fixture copy, every filesystem the app
serves was put through all eleven vectors twice:

    NTFS                          11 of 11,  11 of 11
    ext4 + data=journal           11 of 11,  11 of 11
    XFS + sync                    11 of 11,  11 of 11
    btrfs (via luks2-direct)      11 of 11,  11 of 11
    LUKS -> ext4 + sync           11 of 11,  11 of 11
    LUKS -> XFS + sync            11 of 11,  11 of 11

Twelve runs, no failures. The vectors are: a copy killed partway, the volume
still writable afterwards, unmount under load, what was written surviving it, a
full volume answering rather than hanging, three open-and-close cycles,
permissions readable by their owner, two writers and a reader at once, the
filesystem coming back after the machine was killed mid-write, every fsynced
file surviving that kill, and the volume taking a write again afterwards.

Without its option ext4 fails the fsync vector and XFS fails it too, which is
the fix being load-bearing rather than decorative -- it was checked in both
directions on both.

## The write size does not rescue XFS either — 2026-09-03

`-o sync` makes every write synchronous, so a bigger write means fewer round
trips. On a device, 190 MB written with `dd conv=fsync`:

    wsize=32768      44 s    4 MB/s   (what ships)
    wsize=262144     21 s    9 MB/s
    wsize=1048576    20 s    9 MB/s

Two and a bit times better, and it stops improving after 256 KB. Against
190 MB/s without `sync`, that is not a fix -- it is twenty times short.

**And it would cost the thing this whole effort started from.** SPECS records
that the write size was cut to 32768 precisely to keep the folder being copied
into answering, that 16384 was no better, and that 32768 was the size that
worked. Trading a stall that is fixed for a speedup that is still twenty times
short is the wrong way round, so this is not taken.

The lever list for XFS is now empty: wsync does not make it durable, a bigger
write size does not make it fast, NFSv4 has the same fault, and the client and
export are not where it goes wrong. What is left is the COMMIT itself.

## Both export modes fail, and the guest is a current kernel — 2026-09-03

One hypothesis fitted everything: that a `sync` export makes nfsd claim a
stability it does not provide and then treat COMMIT as a no-op. If so, `async`
-- which tells the server the writes are explicitly not stable -- would force a
real fsync on COMMIT.

    export async, no guest option:  8 of 8 present, 8 wrong

The same as `sync`. So COMMIT achieves nothing in either mode, and that
hypothesis is gone with the rest.

The guest is Linux 6.12.62 on Alpine 3.24.1 -- a current kernel, not something
elderly with a long-fixed nfsd bug. So this is not going to be cured by moving
forward a version.

Every hypothesis reachable from outside the guest kernel has now been tested:
the filesystem, the client, its cache, the export in both modes, the export
file, the NFS version, the block flush, the device's advertised cache, the
write size, the helper, the mount point, privileges, the net helper, vmnet
offloading, the tuned action, the backing, and the kernel's age. What remains
is inside nfsd's COMMIT path on a 6.12 kernel, and reaching it needs tracing
rather than another run.

## The server receives the COMMITs — its own counters say so — 2026-09-03

The guest was instrumented to print `nfsstat -s` while serving. Four files
written with `dd conv=fsync` over NFS, and the server's own v3 procedure
counters afterwards:

    write 124      commit 8

So the client sends COMMITs, the server receives them, the server answers them,
and the data is not durable when the machine is killed immediately afterwards.
That is no longer an inference from the client side: it is the server counting
the calls it handled.

The diagnosis is complete as far as it can be taken from outside the kernel:

    the client sends COMMIT              nfsstat -c, counter moves
    the server receives COMMIT           nfsstat -s, commit 8
    the export is sync                   exportfs -v in the guest
    async behaves identically            8 of 8 wrong either way
    the block device advertises a cache  write_cache = write back
    krun honours the flush               the patch is in the shipped binary
    an in-guest fsync is durable         8 of 8 kept, same volume, same moment
    a fsync through nfsd is not          8 of 8 wrong

Everything on that list was measured. The fault is inside nfsd's handling of
the COMMIT it has counted, on Linux 6.12.62, and the next step is tracing
inside that kernel rather than another experiment from out here.

## Item 6 complete: every writable format the app advertises — 2026-09-03

SPECS lists seven formats the app claims it can write. All seven now have a
corpus written to them and read back:

    raw (.img, .dmg, anything unrecognised)   123 files byte-identical
    qcow2                                     2024 files, 0 differing, 0 missing
    VMDK, flat (monolithicFlat)               123 files byte-identical
    VMDK, sparse (monolithicSparse)           2024 files, 0 differing, 0 missing
    VDI, dynamic and fixed                    2024 files, 0 differing, 0 missing
    VHD, fixed                                2024 files, 0 differing, 0 missing
    VHD, dynamic                              2024 files, 0 differing, 0 missing

The two the app declares read-only -- VMDK stream-optimized and VHDX -- are
covered by the end-to-end suite, which opens each, confirms it mounts read-only
whatever was asked for, and confirms the mount refuses a write.

The flat VMDK needed its descriptor built rather than copied: the descriptor is
a separate file naming its extent by filename, so copying the extent under
another name breaks it. That was the "Failed to start microVM: Invalid
argument" -- an image describing a file that was not there, not a fault in the
reader.

## Item 9's named vectors: long names, non-ASCII, sparse, very large — 2026-09-03

A corpus built for exactly the things item 9 names, copied and read back:

    Japanese, Greek, Cyrillic, umlauts, an emoji, spaces and quotes in names
    a 254-character filename
    a path ten directories deep
    a 512 MB sparse file, almost entirely hole
    a 300 MB solid file

    NTFS    10 files byte-identical
    XFS     10 files byte-identical
    ext4    10 files byte-identical
    LUKS    10 files byte-identical

The first ext4 attempt reported "differs", and it was the fixture: 248 MB free
against a 300 MB file. `cp` said "No space left on device" and the truncated
file naturally did not match. The app behaved correctly -- a copy that cannot
fit fails loudly, which is what item 3 asks for. Re-run on a volume with room,
every byte matches.

## The twelve vectors on every filesystem — 2026-09-03

With item 9's named cases folded in as a twelfth vector:

    NTFS                 12 of 12
    XFS                  12 of 12
    ext4                 12 of 12
    btrfs                12 of 12
    LUKS -> ext4         12 of 12
    LUKS -> XFS          12 of 12

The new vector -- awkward names and shapes -- reports 10 whole, 0 wrong, 0
missing on every one: Japanese, Greek, Cyrillic, umlauts, an emoji, spaces and
an apostrophe, a 254-character name, a ten-deep path, a mostly-hole 512 MB
sparse file, and a 100 MB solid one.

## Full regression after the read-only change — 2026-09-03

    868/868 steps passed, 0 failures

The read-only change touches `mountOptions`, which every mount goes through, so
the whole end-to-end suite was run against it rather than the one path it was
written for. This is the check that was skipped before 1.22.4 shipped a
regression, and it is now what happens after a change to shared code.

## A gap in item 7: NTFS on an unpartitioned disk — 2026-09-03

The repair action is generated only when the mount is writable and the volume's
kind is `.microsoft`:

    withRepair: i.kind == .microsoft && !i.readOnly

and `kind` comes from the partition type the scanner reads. An unpartitioned
disk has no partition type, and the scanner calls it `.linux` deliberately --
"a whole disk handed to cryptsetup is what makes one, and the probe corrects it
either way". The probe does correct the *format*, and it does not correct
`kind`, which is what the repair is keyed on.

So a disk holding NTFS with no partition table gets no repair action installed,
and the dirty-NTFS harness -- whose fixture is exactly that shape -- reports
"unknown custom action: lukottarepair" and "the app could not open the dirty
volume at all".

**What is and is not proven.** Item 7 is proven for a volume whose partition
type says Microsoft: the app opened a dirty one writable with all 41 files
intact and nothing shown to the user. What is not covered is the same
filesystem on a disk with no partition table, which is how some sticks are
formatted and how every raw image of one looks.

The fix is not to install the action more widely -- the ladder that would use
it is keyed on the same `kind`, so the action alone would sit unused. It is for
the probe's answer to reach `kind`, so a disk that turns out to hold NTFS is
treated as holding NTFS whatever its partition table says. That is a change to
how the scan and the probe meet, and it wants doing carefully rather than at
the end of a long night.

### Why the dev channel cannot be tested on this Mac — 2026-09-03

The dev build asks for its own daemon, `com.lukotta.dev.helper`, and there has
never been one on this machine: `/Library/PrivilegedHelperTools` holds
`com.lukotta.helper` and `com.lukotta.beta.helper` and nothing else, and
`/Library/LaunchDaemons` matches. Installing the first one is SMJobBless, which
asks for an administrator password.

So every `--drive open=` through the dev bundle sits in its run loop until the
harness's ten-minute timeout, writes no configuration, and the dirty-NTFS
harness reports that the app left no actions -- which is true, and says nothing
about the app.

The beta daemon is installed, and a daemon replaces itself from the new bundle
without asking anybody for anything. So a fix that needs a real mount to prove
it goes to the beta channel and is proved there. That is the loop anyway.

### 927 failed chowns on every mount — 2026-09-03

The daemon hands the engine's files to the user who asked for the mount, and
did it with `chown`, which follows a symlink. The guest's root filesystem is
mostly symlinks into its own tree: `/bin/cat` points at `/bin/busybox`, a path
inside the machine and nothing at all on this Mac. There are 455 of them.

    could not hand over one of the engine's files      927 times, every mount

Every one of those is a failed system call and a line written to the log, and
the links were never handed over -- they stayed owned by root. `lchown` owns
the link rather than what it points at, which is the thing that wanted owning.
The count is now reported once rather than each time.

Found while reading the daemon's log for something else, which is the only
reason it was ever seen: nothing about it reaches the screen.

Measured on this Mac rather than reasoned about, on a link of exactly the shape
the rootfs is full of (`cat` -> `/bin/busybox`, which does not exist here):

    chown     failed: No such file or directory
    lchown    ok

So every one of the 455 links refused, and the count of 927 is those links
reached twice.

**After, on the same Mac, over five real mounts through the fixed daemon:**

    could not hand over ...        0 lines, and no refusals of any kind

Before it was 927 failed calls and 927 lines on every single mount.

### The mount that never started: ten addresses counted as twelve — 2026-09-03

The app serves each drive's machine on its own loopback address and wants
twelve of them, one per drive it claims to hold. It counts the ones it can
serve over, which is IPv4:

    ifconfig lo0 | grep 'inet '        10   127.0.0.1 .. 127.0.0.10

The daemon that adds them counted every address on `lo0`, and `lo0` carries
`::1` and `fe80::1` as well. So it counted twelve, decided there was nothing to
add, and said so. The app saw ten, asked for more, was told twelve, and asked
again -- five times a second, in the log, for the whole ten minutes the harness
allowed it:

    drives  only 10 addresses; asking for more
    helper  loopback addresses: 12
    app     room for 12 drives at once

The mount never started. Nothing reached the screen; the app simply sat there.
Both sides now count the addresses that can serve, so the daemon adds
127.0.0.11 and 127.0.0.12 and the number it reports is the number the app is
asking about.

This is also the ceiling item 8 is about: the app could never have had more
than ten drives open, whatever the machine had room for.

**After, measured the same way.** The fixed daemon, asked once by the app:

    before   127.0.0.1 .. 127.0.0.10                       10, and it asked forever
    after    127.0.0.1 .. 127.0.0.12                       12, asked once

The same run also answered the probe the repair depends on, on exactly the
shape that was broken -- a whole disk with no partition table holding NTFS:

    helper state: ready
    device:       /dev/disk5
    reply path:   ntfs

So the sector is read correctly through the daemon, which is what
`VolumeKind.settled` is given.

And the daemon's own account of a live mount of one, which is the whole fix in
two lines -- a whole disk with no partition table, which the scan calls Linux:

    helper  partition identified as ntfs
    helper  mount requested, linux false, read-only false

Before today the second line read `linux true`, the Microsoft ladder never ran,
and the repair action was never written.

**And it was on the screen the whole time.** `Capacity.now` takes the ceiling
straight from the addresses that can serve, and the drive list puts that number
in a sentence when the ceiling is reached:

    "N drives or images are open. You can only have N open at the same
     time. Eject one to open another."

So with ten addresses the app told the person their Mac holds ten, beside a
product that says a dozen. Nobody had to look at a log to see this one -- it
was written on the window, in words, and read as a fact about the machine
rather than a bug. It says twelve now.

### Every stalled run wrote an empty log — 2026-09-03

The headless route prints what it is doing, and it is nearly always read from a
file or a pipe. C buffers a redirected stream in four-kilobyte blocks, so
nothing it said was written until the process ended -- and a run killed for
taking too long ended without flushing, so it wrote nothing at all.

    app.log after a ten-minute stall        0 bytes

So every stall this morning looked like an app that had quietly done nothing,
when it had been saying what it was doing the whole time. Both streams are
line-buffered now. This is why the daemon's own log was the only thing that
showed the loopback loop, and why it took going and looking by hand to find it.

### Item 7 on a whole disk with no partition table — 2026-09-03

The shape that was never repaired until today, run end to end through the app:

    made a clean NTFS volume
    opened clean, wrote 41 files, closed and reopened, recorded their sums
    machine taken away with the volume still mounted
    confirmed dirty
    opened dirty volume, mounted under the home directory
    ok   the repaired volume takes a write
    ok   all 41 files byte-identical after the repair
    PASS

And the actions the app left behind, which is what was missing every previous
attempt:

    [custom_actions.lukottatuned]
    [custom_actions.lukottantfs3]
    [custom_actions.lukottarepair]

So item 7 now holds on both shapes: a volume whose partition type says
Microsoft, proven earlier at 41 of 41, and a whole disk with no partition table
at all, proven here. Nothing was shown to anybody in either case.

### An empty keychain entry counted as a saved passphrase — 2026-09-03

Found in the same run, in the app's own words once its output stopped being
swallowed:

    using the key saved under disk5
    no passphrase given and none saved; opening as an unencrypted volume

Both lines are about the same lookup. An entry existed under `disk5` -- a
device node, which is whatever was attached last -- and it was empty. Finding
it ended the search, so a real passphrase saved under any of the names after it
was never reached, and the drive asked for one again. Empty is not a
passphrase, on either route.

### Nine open through the app, mid-run — 2026-09-03

Taken while the crowd measurement was running, before it reached twelve, on a
16 GB Mac with nothing else heavy on it:

    engines                31 processes, 1232 MB resident in total
    memory free            59 percent of the machine
    swap in use            1740 MB of 3072 MB

The swap figure is the machine's, not this app's -- it was already in use
before any of this started -- but it is the number that matters for the 8 GB
claim, and it is why item 8 wants the machine it names rather than an argument
from a 16 GB one. `scripts/eight-gig-pressure.sh` exists to hold ballast and
measure inside what an 8 GB Mac would have left, and running it against the
app's own route is what item 8 still needs.

### The same correction applies to the eight-gigabyte measurement — 2026-09-03

`scripts/eight-gig-pressure.sh` holds ballast written from urandom until what
is left free is what an 8 GB Mac would have, and measures inside that. What it
found on 2026-09-01 and again on 09-02 stands and is worth having: twelve
volumes written and read back, home listing 16 to 20 ms, and the machines'
resident total falling from 1545 MB to 554 MB as the host took its page cache
back. The footprint is elastic, not a fixed price per drive.

But those twelve were opened through the engine as well. The app asks its
daemon for addresses first, and until this morning it could not have had more
than ten -- so the 8 GB figures describe a dozen engines, not a dozen drives
opened the way a person opens them.

Item 8 therefore needs the two run together: twelve opened through the app by
`crowd-through-the-app.sh`, and `eight-gig-pressure.sh` measuring inside the
ballast while they are open. Neither alone answers it, and the engine-route
numbers should not be read as though it had been answered.

### The ceiling counts a resource the mounts do not use — 2026-09-03

With eleven volumes open through the app, nothing at all was listening or
connected on any `127.0.0.x` alias, including the two the daemon had just
added. Every mount runs over the vmnet instead:

    mount        disk6.local:/mnt/CROWD1 on /Volumes/CROWD1 (nfs, ...)
    resolves     disk6.local -> 172.27.1.6
    established  172.27.1.1, .5, .9, .13, .17, .21, .25, .29, .33, .37, .41, .45

Twelve connections, stepping by four, which is a small subnet per machine.

So the number the app calls its capacity -- and prints to the person as "you
can only have N open at the same time" -- is a count of loopback aliases that
no mount is using. Adding the eleventh and twelfth was still what unblocked
opening the eleventh and twelfth, because the gate is what refuses; but the
gate is counting the wrong thing, and the real limits are the vmnet addresses
and memory.

Written down rather than acted on: the fix shipped this morning makes the gate
self-consistent and correct about its own resource, and changing what the gate
counts is a different change that wants its own measurement of what the vmnet
actually runs out of.

### Twelve through the app's own route — 2026-09-03

    opening 12 volumes through com.lukotta.beta, one at a time
      lo0 carries 12 addresses that can serve
       1 of 12 open ... 12 of 12 open

All twelve opened, one `--drive open=` at a time, the way the window does it.
This morning the eleventh could not have opened at all.

The run got no further: the write and read-back, the footprint and the
responsiveness were all still to come when I edited the script's file while
bash was executing it, and the shell resumed mid-line and died. The opens are a
result; the rest of this measurement is not taken yet, and nothing about data
integrity at twelve is claimed from it.

### Every release shipped the name of the machine that built the guest — 2026-09-03

Found in the bundle installed at /Applications, in the release cut this
morning. `umoci` writes a header at the top of the rootfs manifest naming
whoever ran `anylinuxfs init`:

    #      user: <the account>
    #   machine: <the hostname>.local
    #      tree: <the home directory>/.anylinuxfs/alpine/rootfs
    #      date: ...

That manifest is packed into the engine and installed with the app, so those
three facts have gone out inside every release, to everyone who installed one.

There was a guard against exactly this, and it could not have fired, for two
independent reasons:

  - it looked at two binaries, and this is not a binary;
  - it was `strings | grep -qF "$HOME"` under `set -o pipefail`, and grep -q
    exits on its first match, killing strings with SIGPIPE, which pipefail
    reports as the pipeline failing -- so the `if` was false precisely when the
    path was there. Demonstrated on a file that did contain one: the matched
    form reported nothing, the counted form caught it.

Fixed at both ends. The header is dropped when packing -- dropped rather than
rewritten, because an invented user and hostname would be a lie in a file that
claims to be provenance -- and the guard is a sweep over every file about to
ship, counted, placed after the dylib closure so nothing copied late escapes
it. The vendored engine on this Mac was stripped in place as well, 812 lines to
808, so the next build carries nothing without waiting for a re-vendor.

    vendored engine, files naming this machine     0
    built bundle, files naming this machine        0
    stripped engine, opening a volume              works

The last of those is the one that mattered: a manifest is packed inside the
guest's own directory, and a change to anything in there is a change to what
boots. Opened a volume through the app on a build made from the stripped tree:

    mount script exited with status 0
    opened CROWD1
    disk5.local:/mnt/CROWD1 on /Volumes/CROWD1 (nfs, ...)

Verified on the artefact itself rather than on the script that makes it: every
file in the built 1.22.8-beta.1 bundle swept, nothing found, and the manifest
that carried the header now begins at `keywords:`. The build also had to pass
its own new guard to finish at all.

The engine binary does not contain the string `mtree` at all -- nought
occurrences -- so nothing reads or validates the file at run time. It is
written once by `anylinuxfs init`, and thereafter only its *name* is used, by
`vendor-engine.sh`, to check the guest digest against the lock. Stripping
comments from it cannot break a boot.

Checked before doing it that nothing verifies the manifest's contents:
`vendor/engine.lock` does not mention it, no checksum covers it, the digest
check reads the file's *name*, and the app only looks for an mtree existing at
all as a sign of what put the directory there. The name is unchanged and the
manifest body is untouched, so the four lines can go.

### Item 9's vectors were measured through the engine as well — 2026-09-03

`scripts/integrity-vectors.sh` line 181 opens every volume it tests with

    nohup "$ENGINE" mount -w false ... "$IMAGE"

so the twelve vectors that passed twice -- interrupted copies, unmount under
load, ENOSPC, repeated cycles, permissions, awkward names, concurrent writers,
power loss -- were all exercised against the engine directly, not against the
app. That is the third measurement today found to be off the route a person
takes, after the dozen-volume figures and the eight-gigabyte ones.

What it does and does not mean. The vectors themselves are real and their
results stand: the data either survived or it did not, and that is a fact about
the filesystem, the guest and the flush path, all of which are the same
whichever process asked for the mount. What is not covered is anything the app
adds on top -- the daemon that builds the mount, the options it chooses, the
identity it mounts under, the ladder it walks. A fault living there would not
show up in any of these runs.

Item 9 is therefore proven for the storage path and unproven for the app's.
Running the same vectors against a bundle that can be driven is what closes it,
and that is now possible: `LUKOTTA_BRANDING=beta LUKOTTA_DEVTOOLS=1`.

### A dozen through the app's own route, verified — 2026-09-03

Twelve volumes opened one `--drive open=` at a time, the way the window does
it, then written to together and read back:

    seconds to open        72 73 73 72 73 73 73 74 74 74 74 75
    first 72, last 75      the twelfth costs what the first did
    mounts served          12, twelve distinct shares on twelve mount points
    lo0 addresses          12 before and after -- nothing asked for twice
    written                60 files to each of the twelve, at once, in 2 s
    read back              byte-identical on 12, wrong on 0

The flatness is the answer to the question item 8 asks. Opening the twelfth
drive costs three seconds more than opening the first, not twelve times more,
so the app is not paying for the drives already open. Before this morning the
eleventh could not be opened at all.

**Two of my own instruments returned nonsense in the same run, and neither
number is recorded as a result:**

  - `engines: 0 processes, 2091 MB resident` -- self-contradictory on its face.
    The count and the total are taken by two different expressions and only one
    of them works; nothing that holds two gigabytes is nought processes.
  - `shell responsiveness: 0 ms` -- `time -p` reports hundredths, and echoing a
    word takes less than one, so the measurement has no resolution at the size
    of the thing it is measuring.

The footprint and the responsiveness at twelve are therefore still unmeasured
on this route. The opens, the writes and the read-back are measured and stand.

### What the power-loss vector does and does not simulate — 2026-09-03

The vector called "power loss mid-write" kills the guest machine, not the Mac.
That is the right test for everything between the application and the host: the
guest's page cache, the filesystem's journal, virtio's flush, nfsd's COMMIT.
The fault traced on 2026-09-03 was found exactly there and is real.

What it cannot show is the last hop. When the guest's write reaches the host,
the host writes it to the backing file or device, and on macOS `fsync()` does
not flush the drive's own cache -- only `fcntl(F_FULLFSYNC)` does. Killing the
guest leaves the host's page cache intact, so a missing F_FULLFSYNC is
invisible to every run so far: the data is in the Mac's memory and comes back
whether or not it ever reached the platter.

Neither this repository nor the vendored engine mentions F_FULLFSYNC anywhere.
That is not evidence of a fault -- the engine's virtio backend is upstream code
and may well do the right thing by another name -- but it is an untested hop on
the path the owner's goal names explicitly: "files you saved survive the Mac
losing power".

**Settled the cheap way, and the hypothesis is wrong.** Disassembling the
shipped engine and looking at what is passed to `fcntl` finds the constant:

    mov w1, #0x33     immediately before a call to _fcntl

`0x33` is 51, which is `F_FULLFSYNC`. The engine does ask macOS to flush the
drive's own cache; the grep for the name found nothing because the name is a
number by the time it reaches the binary. Twenty seconds of `otool` against an
hour of setting up a real power cut, and it invalidated the guess.

What this does establish: the code knows about F_FULLFSYNC and uses it. What it
does not: that the call sits on the virtio flush path for a device backing
rather than somewhere else in the engine. That still wants either reading the
backend's flush handler or cutting the power for real -- but it is no longer
the missing-call hypothesis, which was the cheap thing to rule out first.

### Seventy-two seconds to open a drive — 2026-09-03

Measured twelve times over in the crowd run, and again on every reopen the
vectors do:

    opening a drive, harness measured   72 to 75 seconds, flat
    opening a drive, daemon measured    about 10 seconds

The first is what the harness saw and the second is what actually happened;
see below. Ten seconds is the number a person waits after asking for a drive. It does not grow with the number already open, which is the scaling
question and the good news. But three quarters of a minute is a long time to
look at a window, and nothing in the ten items names it, so it has never been
questioned.

**WRONG, and corrected the same hour. It is sixty seconds of the harness and
about ten of the app.** The daemon's own log, three consecutive mount cycles:

    11:10:31.007  partition identified as ntfs
    11:10:31.008  mount requested, linux false
    11:10:41.218  mount script exited with status 0     10.2 s
    11:11:48.222 -> 11:11:58.493                        10.3 s
    11:13:03.387 -> 11:13:13.459                        10.1 s

A drive opens in about ten seconds. The other sixty are `--drive` waiting for a
daemon replacement that was never asked for:

    let before = daemonProcessID()
    helper.replaceIfStale()
    let replaceBy = Date().addingTimeInterval(60)
    while daemonProcessID() == before, Date() < replaceBy { ... }

When the installed daemon already matches the bundle, nothing is replaced, the
process id never changes, and the loop runs its full minute. Every headless
open pays it; nobody using the window does.

I had reasoned my way to the opposite conclusion an hour earlier -- "the first
open was the joint fastest, so the cost is not daemon replacement" -- and that
reasoning was sound and the conclusion still wrong. The cost is not replacing
the daemon. It is waiting for a replacement that never comes, which is
identical in every run and therefore invisible in the spread between them.
Twelve numbers agreeing to within three seconds looked like evidence of a real
constant. It was evidence of a constant, and the constant was a timeout.

What is not yet known is how much of it is the app and how much is the guest
booting. The engine route boots the same machine, so most of it is presumably
Linux coming up -- but "presumably" is exactly the word this file exists to
avoid. The comparison is one command each way and has not been run.

Written down because item 10 says no UX cost anywhere, and a wait is a cost
whether or not anybody has called it one.

### Item 9's twelve vectors, on the app's own route — 2026-09-03

Every one of them, opened through `--drive` the way the window opens a drive,
against an NTFS fixture:

    ok  a killed copy leaves no corrupt file behind (40 whole, 0 wrong)
    ok  the volume still takes a write after a copy was killed
    ok  the volume mounts and reads after being unmounted under load
    ok  what was written before the unmount survived it
    ok  a full volume answers with an error, in 2s
    ok  three open/close cycles in a row (3 of 3)
    ok  everything written is readable by whoever wrote it (3 of 3)
    ok  awkward names and shapes survive a copy (10 whole, 0 wrong, 0 missing)
    ok  two writers and a reader at once leave nothing wrong (24 compared, 0 differing)
    ok  the filesystem comes back after the machine was killed mid-write
    ok  every fsynced file survived power loss (8 of 8 present, 0 wrong, 0 lost)
    ok  the volume takes a write again after power loss
    12 passed, 0 failed

These had only ever been run against the engine before. What the engine route
could not see is everything the app puts on top -- the daemon that builds the
mount, the options it picks, the identity it mounts under, the ladder it walks
-- and four faults were found in exactly those four places this morning. So
this is not a formality; it is the first time the vectors have been asked about
the thing a person uses.

Getting here took three faults in the harness itself, each of which would have
produced a confident wrong answer rather than an obvious breakage: the share
looked for under the image's name when the app mounts a device, the image
attached again on every reopen without being given back, and no passphrase
passed, which would have failed every encrypted fixture for want of a key.

Still to do on this route: ext4, btrfs, exFAT and LUKS. NTFS was taken first
because all four of today's product faults were NTFS ones.

### The sixty seconds, fixed and measured — 2026-09-03

`--drive` waited for the daemon's process id to change whatever the answer, and
when the installed daemon already matches the bundle nothing is asked for,
nothing changes, and the loop ran its whole minute. It now asks
`replaceIfStale` whether it actually requested anything, and waits only then.

    before, every open                  72 s
    after, daemon freshly replaced      72 s   -- a real replacement, waited for
    after, daemon already matching      11 s

The middle line is the one worth keeping: the wait is still there when there is
something to wait for. What has gone is a minute spent waiting for an event
that was never going to happen.

This never touched anybody using the window -- it is on the `--drive` path
only. What it did touch is every measurement taken through that path: twelve
crowd opens, and ten more in each vectors run. Fourteen minutes of a
twenty-minute run were this.

### A full encrypted volume takes two minutes to say so — 2026-09-03

The same vector, the same harness, the same afternoon, two formats:

    NTFS                          a full volume answers with an error, in 2s
    ext4 inside LUKS              a full volume answers with an error, in 129s

Both are recorded as passes, because what that vector asks is whether a full
volume answers at all rather than hanging, and both answer. But two minutes is
not an answer anybody experiences as one. Somebody copying onto a full
encrypted drive watches Finder do nothing for over two minutes before being
told there is no room -- and item 3 says nothing user-visible during a copy,
while item 1 is about writing not stalling. Sixty-five times NTFS is not a
detail.

More numbers, from the same vector on every format that would open:

    NTFS                          2s
    btrfs                         2s
    exFAT                         3s
    ext4                          3s
    ext4 inside LUKS            129s
    XFS inside LUKS             140s

Four unencrypted filesystems answer in two or three seconds. The same
filesystems inside LUKS take over two minutes. ext4 is the clean comparison
because it appears on both sides: three seconds bare, a hundred and twenty-nine
inside a container. Nothing else differs.

It is the encryption. Not the filesystem, not the Linux mount path.

So it is not ext4. Two different filesystems inside LUKS behave the same, and
the unencrypted one is sixty-five times quicker. That leaves the encryption
itself, or the Linux mount path generally, and the measurement that separates
those is a plain ext4 or XFS volume with no LUKS around it -- which is exactly
the fixture that turned out to be full. Repairing it stopped being a coverage
chore and became the deciding experiment.

exFAT would say something too: unencrypted, and it goes down the Microsoft
ladder like NTFS. If exFAT is quick, the Microsoft path is quick and the Linux
path is slow whether or not anything is encrypted.

Recorded as a result rather than an obstacle: the number is real, it is bad,
and the next route is a measurement that says which layer owns it.

### The ext4 fixture was full, and the harness said so — 2026-09-03

    ===== ext4-vectors =====
    mounted at /Volumes/LUKOTTAEXT4
    starting with 0 MB free
    error: 0 MB free. These vectors need 200 MB and this volume
           cannot hold them, so nothing here would be about the app.

That refusal is the space check added after a full volume once read as a data
fault -- CROWD1 differing on 117 of 123 files, which was not corruption but a
volume with nowhere to put them. It fired correctly here and cost nothing but
a fixture.

The image is 335544320 bytes, and the vectors want 200 MB free inside it, so
even empty it has little room. It was filled by a run from before each run took
its own copy of the fixture, and has been carrying that ever since. It wants
remaking larger, which is a job for when the machine is not in the middle of
the other four formats.

Written down because "ext4 was skipped" is exactly the sort of thing that
becomes "ext4 passed" in a later summary if nobody records why.

### btrfs did not open, and the app was right to refuse — 2026-09-03

    BTRFS error (device vda): open_ctree failed: -22
    mount script exited with status 1
    the drive did not open (status 1)

That reads as the app failing to open a format it advertises. It is not. The
fixture is truncated:

    file on disk      92,733,440 bytes
    superblock says   1,074,790,400 bytes total, 147,456 used

A btrfs superblock describing a gigabyte inside an eighty-eight megabyte file.
`open_ctree -22` is btrfs refusing a device smaller than the filesystem claims
to be, which is exactly what it should do, and the app passing that refusal
back rather than pretending is exactly what it should do.

Settled by reading two numbers out of the image with no engine, no mount and no
guessing: the file's size, and the size the superblock claims. Item 6 is not
answered for btrfs either way -- it needs a fixture that is whole.

The image was probably cut short when it was made; `btrfs-vectors.img` has no
maker in `scripts/`, so it was created by hand at some point and has been
carrying this ever since.

### A discard inside the guest destroys the image file — 2026-09-03

Found while remaking the btrfs fixture, which had been truncated. It had not
been truncated when it was made; it was truncated by making it.

    dd a 512 MB file, open it through the engine, blkdiscard /dev/vda

    before   536,870,912 bytes
    after              0 bytes

The file is emptied. Not sparse -- `du` and the apparent size both go to
nothing. The same thing at a smaller scale explains the fixtures:

    mkfs.ext4 on a 1 GiB image     1,073,741,824 -> 1,073,676,288   64 KiB lost
    mkfs.btrfs on a 1 GiB image    1,073,741,824 ->    92,667,904   981 MB lost

ext4 writes its backup superblocks near the end of the device, so almost
nothing is discarded past them; btrfs writes only at the front, so everything
after about eighty-eight megabytes goes. The file ends at the highest offset
still written, which is what a discard implemented as a truncate would do.

**What this means, stated carefully.** Every fixture in this project is a disk
image, and so is every image a person opens with the app. A filesystem that
issues discards -- mounted `-o discard`, or `fstrim`, or a `mkfs` -- can shorten
the file it lives in. The truncation is not the app's doing directly: the
discard comes from the guest and the image driver turns it into a shorter file.
But the app is what puts a person's image under that driver.

**Measured, and the reach is much smaller than the first result suggested.**

The app never asks for `discard`: the word does not appear as a mount option
anywhere in its sources. But the guest kernel is 6.12, and btrfs turns it on by
itself -- read out of `/proc/mounts` inside the machine:

    discard=async

So btrfs does issue discards in ordinary use. The question is what an ordinary
discard does to the file, and the answer is nothing:

    512 MB btrfs image, wrote 200 MB, deleted it, synced, unmounted
    before   536,870,912 bytes
    after    536,870,912 bytes

Freeing blocks does not shorten the file. What shortens it is a discard over
the *whole device*, which is what `mkfs` issues and what nothing in ordinary
use does. Somebody writing and deleting files -- even on btrfs, even with
discard on -- is not at risk, and that is the case that matters.

What remains true and worth keeping: making a fixture with `mkfs` inside the
guest silently shortens the image, which is how two of this project's fixtures
were quietly broken and how they would be broken again. The image must be
re-extended after a `mkfs`, and both fixtures now are.

The btrfs fixture was not damaged by neglect. It was made this way, and would
have been made this way again by anybody following the same steps.

### exFAT was handed the NTFS driver — 2026-09-03

From the app's own log, opening an exFAT volume:

    fs_type: Some("exfat")
    mount args: ["-t", "ntfs3", "/dev/vda", "/mnt/EXFATVEC", ...]
    then again: "--fs-driver", "ntfs-3g"
    each time:  NFS server not ready / libkrun VM exited with status: 1

The type was probed correctly. The *driver* was chosen from the family the
volume belongs to rather than from what it is:

    let drivers: [String?] = i.kind == .microsoft ? ["ntfs3", "ntfs-3g"] : [nil]

exFAT is a Microsoft filesystem and neither NTFS driver will mount it, so both
rungs failed, the machine exited 1 twice, and the app then said `opened
EXFATVEC` and returned 0.

**Whose fault, and since when.** Not the change made this morning, though that
is what exposed it. Before today a whole-disk image was called Linux whatever
it held, so an exFAT image took the Linux route and the engine mounted it
correctly; the format sweep that found all seven formats byte-identical was
made of images, so it passed. A real exFAT stick, with a partition type that
says Microsoft, has always gone down the NTFS ladder. Making whole-disk images
honest about themselves put them on the same broken path and made it visible.

The driver now follows the format: only NTFS and BitLocker -- which is NTFS
once unlocked -- take the pair, and everything else lets the engine mount what
it found.

Still open, and it is the more serious half: the app reported success for a
mount that never happened. `opened EXFATVEC`, status 0, no volume. Nothing
downstream can tell that apart from a mount that worked.

### Every format, every vector, on the app's route — 2026-09-03

    NTFS              12 passed, 0 failed
    ext4              12 passed, 0 failed
    btrfs             12 passed, 0 failed
    exFAT             12 passed, 0 failed
    ext4 in LUKS      12 passed, 0 failed
    XFS in LUKS       12 passed, 0 failed

Six formats, seventy-two vectors, every one opened through `--drive` the way
the window opens a drive. Interrupted copies, unmount under load, full volumes,
repeated mount cycles, permissions, awkward names and shapes, sparse and very
large files, two writers and a reader at once, and the machine killed
mid-write with every fsynced file surviving.

Before today all of these had only been run against the engine, which cannot
see what the app puts on top of it. That mattered: getting here found the
driver ladder handing exFAT to NTFS, the app reporting a mount that never
happened, two fixtures silently truncated by their own `mkfs`, and four faults
in my own harness -- each of which produced a confident wrong answer rather
than an obvious breakage.

What is still not proven, and is not claimed: item 8 on the machine it names,
and item 10 for XFS writes on a real drive. The full-volume delay inside LUKS,
129 and 140 seconds against two or three unencrypted, is a real cost and is
recorded above rather than waved through because the vector counts it a pass.

### The full-volume delay may be `-o sync`, not the encryption — 2026-09-03

Before that conclusion hardens, a competing explanation that fits every number
already taken. The app chooses a durability option per volume, and only some
volumes get `sync`:

    plain XFS         durabilityOption sees the XFS magic       -> sync
    LUKS container    the header hides the superblock           -> sync
    ext4              journalled                                -> data=journal
    btrfs             nothing                                   -> none
    NTFS, exFAT       a driver is named, so durability is skipped

Lay that beside the measurements:

    slow    ext4 in LUKS 129s, XFS in LUKS 140s     both mounted -o sync
    fast    NTFS 2s, btrfs 2s, exFAT 3s, ext4 3s    none of them mounted -o sync

The two sets are exactly the volumes that get `sync` and exactly the ones that
do not. Encryption and `-o sync` are perfectly confounded in everything
measured so far, because every encrypted volume here is a container and every
container gets `sync`.

**The experiment that separates them is plain XFS**, which is unencrypted and
still gets `sync`. If it is slow, the cause is the mount option -- which the
app chooses and can therefore fix -- and not the encryption. If it is quick,
the encryption stands accused.

`plain-xfs.img` is already in the fixtures. This is written down before the run
so the prediction cannot be adjusted afterwards to fit whatever comes back.

**Run, and the prediction holds. It is `-o sync`.**

    plain XFS, no encryption at all      a full volume answers in 110s

    mounted -o sync    XFS 110s, ext4 in LUKS 129s, XFS in LUKS 140s
    not                NTFS 2s, btrfs 2s, exFAT 3s, ext4 3s

The line falls exactly on the mount option. An unencrypted volume takes a
hundred and ten seconds; encryption adds perhaps twenty on top of that and is
not the cause. The earlier conclusion -- "it is the encryption" -- was wrong,
and was wrong in the way this file exists to catch: six formats agreeing with
it, and the seventh, which nobody had run, disagreeing.

**And it joins two open items into one.** `-o sync` is there because nfsd's
COMMIT is not durable, which is the fault traced on 2026-09-03. That option
costs 47x on writes to a real drive, which is why item 10 is unmet for XFS, and
it costs a hundred and ten seconds to notice a volume is full. Both are the
price of the same workaround. Fixing the COMMIT retires the option and both
costs with it; nothing else needs to be traded off against anything.

### ext4 inside LUKS pays for an option it does not need — 2026-09-03

The durability option is chosen on this Mac, before the machine boots, by
reading the volume's superblock. A LUKS container hides that superblock, so
none can be chosen and the blunt one is used for whatever is inside.

    ext4, superblock readable      data=journal      full volume answered in 3s
    ext4 inside LUKS, hidden       sync              129s
    XFS inside LUKS, hidden        sync              140s
    plain XFS, readable            sync              110s

ext4 is the case that matters: the same filesystem answers in three seconds
with the option it actually needs and a hundred and twenty-nine with the option
it is given for want of being able to look. That is not the encryption costing
anything -- it is the app choosing coarsely because it chose early.

**The superblock is readable a moment later.** The mount script unlocks the
container inside the guest and then mounts what appears; between those two
steps `blkid` on the opened mapper device says what it is. Choosing the option
there rather than here would give ext4 inside LUKS the same `data=journal` it
gets bare, and would leave btrfs inside LUKS -- which needs no option at all --
paying nothing instead of paying the most.

Only XFS would still want `sync`, and only until nfsd's COMMIT is fixed.

**How it could be done without touching the engine.** The option is handed to
the engine before the machine boots, and the engine is what unlocks the
container, so the app cannot decide inside the guest and cannot pass a
conditional. But the engine already says what it found, in its own log, on
every mount:

    macOS: fs_type: Some("exfat")

So the app can learn a container's inner filesystem from the mount it just
made, remember it beside the fingerprint it already caches for that volume, and
use the cheap option the next time that volume is opened. The first open of a
new encrypted volume keeps `sync`, which is the safe direction; every open
after that costs what a bare volume costs.

Not attempted today: it adds state, and state that is wrong is worse than an
option that is slow -- a remembered `data=journal` applied to a volume that
turned out to be XFS would lose data rather than time. It wants its own
measurement, on both filesystems, before it is trusted. Written down with the
numbers that justify it so it is not rediscovered from scratch.

### A dozen volumes under eight-gigabyte pressure, through the app — 2026-09-03

Twelve opened one `--drive open=` at a time, written to and read back, then
eight gigabytes of ballast held from urandom so what is left free is what an
8 GB Mac has, and the same twelve measured inside that.

    seconds to open        12 to 15, first 12, last 15
    written                60 files to each of the twelve at once, in 2 s
    read back              byte-identical on 12, wrong on 0
    engines, unpressured   36 processes, 2361 MB resident

    under pressure, what the app and its machines hold:

        time      vm_mb  free_mb  compressed_mb
        12:20:56    345       31           1908
        12:21:56    348       26           1922
        12:22:56    291       15           1915
        12:23:26    288       14           1932
        12:24:26    282       34           1914
        12:25:56    284       16           1917
        12:27:26    330       23           1927     <- writing
        12:29:27    345       18           1910     <- writing
        12:30:27    343       15           1919

        memory free            33 percent
        swap                   7138 MB used of 8192, 7003 MB after
        shell responsiveness   2 ms to list the home directory

**2361 MB becomes 284.** The footprint is page cache, and the host takes it
back the moment it wants it: idle under pressure the twelve hold under 300 MB,
and writing pushes it to about 345 before it settles again. It does not grow
without bound and it does not force the machine to thrash -- a shell still
answers in 2 ms with fifteen megabytes free.

**Two instruments in this run are still wrong, and neither number is used.**
The ballast check reports "6 MiB of 8192 MiB asked for" because it measures the
holder's resident size, and macOS compresses those pages as fast as they are
made; the compressor held 7.9 GB and free memory sat at 15 to 34 MB, which is
what says the pressure was real. And two lines of the pressure script are
f-strings with nested quotes, a syntax error before Python 3.12, so the process
launch and home listing latencies never printed at all.

**What this is and is not.** It is a 16 GB Mac squeezed until what remains is
what an 8 GB Mac has, with twelve volumes open through the route a person uses.
It is not an 8 GB M1. Item 8 names that machine and this is the closest this
hardware can come.

### One volume of twelve came back empty, and filled in later — 2026-09-03

Third run of `crowd-through-the-app.sh`. Twelve volumes opened through the
app, sixty files copied onto each at once, read back.

    seconds to open        12, 12, 12, 12, 12, 13, 13, 13, 13, 14, 13, 14
    written                60 files to each of the twelve at once, in 2 s
    read back              byte-identical on 11, wrong on 1
    the wrong one          /Volumes/CROWD8, NTFS, on disk12

Then, by hand, on the volume while it was still mounted:

    12:35        the copy runs; the files carry this timestamp
    ~12:36:40    ls of /Volumes/CROWD8/crowd-write returns 0 files
    ~12:37:30    the same ls returns all 60, every one 100000 bytes
    afterwards   create visible in 1 ms, delete visible in 0 ms

So nothing was lost. Sixty files of the right size were on the volume; a
listing taken a minute after the copy did not show them, and a listing taken
a minute after that did. The two runs before this one passed twelve of twelve,
so it is intermittent — once in three.

**The instrument could not say which failure this was.** `ditto` wrote to
`/dev/null`, so whatever it said about that volume is gone. The readback sent
`find`'s errors to `/dev/null` too, so a directory that fails to list produces
an empty sums file, which differs from the expected sums in exactly the way a
volume of corrupt files does. An erroring volume and a corrupt one arrived as
the same line. Both are now kept and told apart, and a short listing is
watched for a minute so a volume that fills in late is distinguished from one
that never fills in.

**What is not yet known.** Whether the client held a stale directory or the
server had not yet made the files. The gap seen by hand is between 90 and 150
seconds, and the client's own directory cache expires at 60 (`acdirmax`
default; the app sets rsize, wsize, readahead, dumbtimer, timeo, retrans,
deadtimeout, mutejukebox and noowners, and no attribute-cache option at all).
Longer than 60 seconds points away from the client's cache, but the times were
taken by hand from a shell and are not tight enough to settle it. The next run
records the settle time from inside the harness.

**This is a user-visible copying failure and counts against item 3.** A person
who copies a folder and opens it a minute later sees an empty folder.

### The stale handle has a name, and the twelve did not survive the squeeze — 2026-09-03

Two results from one afternoon, both from instruments that had been reporting
something else.

**What "differs" actually was.** With `find`'s errors kept instead of
discarded, the twelve-volume harness named it on the first run:

    /Volumes/CROWD8 could not be read: find: './f38.bin': Stale NFS file handle

Not an empty directory and not corrupt data. The listing found the file and
the handle to it was already dead — ESTALE, which a Linux nfsd returns when it
cannot resolve a filehandle it issued itself. Twice now, both times CROWD8,
both times on the copy the harness makes immediately after the twelfth volume
opens.

**It is not the copy and not the crowd.** Against the same twelve, open and
already exercised:

    12 cycles x 12 volumes, 15 files each, nothing deleted   324 copies
    15 cycles x 12 volumes, 60 files each, deleted between   clean, all of them
    worst wait for a copy to become visible                  65 ms
    typical                                                  53 to 65 ms

So 324 copies of the same shape onto volumes that had been open a while were
all visible within 65 ms of the copy returning. What the fault wants is a copy
landing on a volume that has only just been opened, which is why it costs four
minutes to reach. `first-write-after-open.sh` does that alone in cycles of
fifteen seconds, with SETTLE to ask whether the open is simply returning before
the volume is ready.

Two hypotheses are already dead, checked rather than assumed: the twelve are
served on twelve distinct vmnet addresses with no collision (`netstat` on port
2049), and nothing in the mount flow re-exports after the client has mounted.

**Latency under an 8 GB squeeze, at last.** The figures item 8 has never had,
with twelve volumes open and free memory held down to 65 MB:

    home listing            22 ms
    spotlight-free find     22 ms
    process launch          21 ms
    swap                    7013 MB of 8192 used

**And in the same run, all twelve died.** The footprint table read:

    12:48:47   1246 MB
    12:49:17    697 MB
    12:49:47    696 MB
    12:50:17      1 MB      <- and 1 MB for every sample after
    ...

which was taken for the app giving memory back. Afterwards there were no CROWD
mounts, no engine processes at all, and the twelve disk images had been
detached — which memory pressure alone does not do, so something cleaned up
after the machines were killed. The ballast script unmounts and detaches
nothing; that was checked, not assumed.

**The table could not say it.** It sampled megabytes and never the count of
volumes still served, so twelve volumes holding 300 MB and no volumes holding
nothing were the same row. The count is now sampled beside the cost, and item 8
runs as one script rather than three logs to line up by their clocks.

**Item 8 is not proven, and the earlier passes are weaker than they read.**
Every previous pressure run reported a footprint and never a survival, so none
of them establishes that the volumes were still there at the end.

### Twelve stayed served through the squeeze, sampled every five seconds — 2026-09-03

`twelve-under-pressure.sh`, the whole of item 8 as one action: twelve opened
through the app, held, then eight gigabytes of ballast so what is left free is
what an 8 GB Mac has, with the count of volumes still served sampled beside
what they cost.

    served, every sample, ten minutes of squeeze     12 of 12
    fewest served at any sample                      12 of 12
    footprint on opening                             2355 MB
    footprint once squeezed, settled                 334 to 339 MB
    host free through the squeeze                    14 to 35 MB
    compressed                                       1925 to 1958 MB

    home listing            21 ms
    spotlight-free find     20 ms
    process launch          19 ms

So the collapse did not reproduce here, and the difference between the two runs
is known: the run in which all twelve died had been through 324 copies first,
and this one went from opening straight into the ballast. A volume just opened
holds almost nothing; one that has been copied onto holds a page cache, and the
second is the state a person's Mac is actually in. The next run works them
first, which is what `EXERCISE` now does by default.

**What this establishes and what it does not.** Twelve volumes open through the
app's own route survive ten minutes at 14 to 35 MB free, cost 334 MB between
them, and leave the Mac answering in about 20 ms. It does not yet establish
that they survive it after being written to, which is the case that failed.

### Worked first, then squeezed: twelve still served — 2026-09-03

Same action, with the twelve written to for a quarter of an hour before the
ballast went on.

    work before the squeeze      15 cycles x 12 volumes, 60 files each
    every copy visible within    62 ms, all 180 of them
    still served after the work  12
    served, every five-second sample through the squeeze   12 of 12
    footprint once squeezed, settled                       310 to 312 MB
    host free through the squeeze                          14 to 22 MB

    home listing            22 ms
    spotlight-free find     21 ms
    process launch          20 ms

So the collapse did not reproduce with the volumes worked either. That is now
504 copies onto volumes already open without a single failure, across three
runs, which also says plainly that the stale handle belongs to the first write
after an open and to nothing else.

**One known difference is left.** The run in which all twelve died had been
left nearly full — 18 MB of files kept on 64 MB volumes with 33 MB free —
because that pass ran with nothing deleted between cycles. Both runs that
survived emptied each cycle before the next. A nearly full volume is one of
item 9's named vectors anyway, so the next run fills them as it works and
prints how full each got before the ballast goes on.

### Filled nearly full, then squeezed: twelve still served — 2026-09-03

The last known difference, closed. Twelve worked with nothing deleted, so each
volume was filled before the ballast went on.

    free on each volume before the squeeze   15 to 16 MB of 64 MB
    every copy visible within                62 ms, all 144 of them
    served, every five-second sample         12 of 12
    fewest served at any sample              12 of 12
    footprint once squeezed, settled         319 to 340 MB
    host free through the squeeze            24 to 55 MB

    home listing            21 ms
    spotlight-free find     21 ms
    process launch          20 ms

**The collapse has not reproduced in three runs** — empty, worked, and worked
until nearly full. It was seen once, and the instrument that would have shown
what happened to it was added afterwards. It stays written down as one
unexplained loss of all twelve rather than as a fault with a cause, and every
run from here samples the count so a second one cannot be missed.

**A false alarm worth keeping.** One volume showed 37 MB free where its
neighbours showed 16, which reads exactly like a volume that did not receive
its copy. It had received it: the others were carrying sixty files from each
earlier run, because the harness had never removed what it wrote onto 64 MB
fixtures. A few runs later they would have begun failing for want of space with
nothing wrong with the app. The harness cleans up after itself now.

### One just-opened volume is not enough: 25 first-writes, all clean — 2026-09-03

`first-write-after-open.sh` on drive8 — the image both stale handles appeared
on — attaching it, opening it through the app, and writing sixty files onto it
the instant the open returned, twenty-five times over.

    RESULT: 25 clean, 0 stale handles, 0 short, 0 did not run

So the fault is not "a copy onto a volume that has just been opened" either. It
needs the twelve opening at once as well: both occurrences were the first write
after the twelfth of twelve came up, and 504 copies onto already-open volumes
and 25 first-writes onto a single one produced none.

That leaves contention in one window — twelve microVMs all just started, all
being written to at once — and the fault rate across every twelve-volume run
so far is 2 in 7.

**Two harness faults found on the way, both able to invent a failure.** The
twelve-volume harness leaves its images attached when it is interrupted, and
this one would then have attached the same image file a second time: two disks
backed by the same bytes, two writers, a corrupted fixture and worthless
numbers from it. It refuses now. And it printed only when something went wrong,
so a working run and a hung one looked identical from outside — five minutes
went on deciding which.

### The stale handle reproduced, and what it is not — 2026-09-03

Six twelve-volume runs back to back, with the harness now keeping what the
copy says and asking again the moment a handle goes bad.

    run 1   copy onto /Volumes/CROWD8 failed:
              ditto: /Volumes/CROWD8/crowd-write/f38.bin: Stale NFS file handle
            find: './f38.bin': Stale NFS file handle
            asked again: still failing, same file, same error
            by name:     ls: cannot access it, same error
            byte-identical on 11, wrong on 1
    runs 2 to 6   byte-identical on 12, wrong on 0

Three things this settles that reasoning had got wrong.

**The copy itself fails.** `ditto` reports it, which means a person copying in
Finder is shown an error mid-copy. This is not a readback artefact of the
harness; it is item 3 broken.

**It does not heal.** Asked again immediately, the walk fails on the same file;
asked by name — a LOOKUP, which does not go through the dead handle — `ls`
fails the same way. So the earlier idea that the files were on the volume and
only a cached listing was wrong is dead. Whatever f38.bin is, it cannot be
reached again.

**It is the same file twice.** Both occurrences that had a filename recorded
name `f38.bin`, about 3.8 MB into a 6 MB copy. One in sixty by chance is one in
3600 for two.

**The fixture is not damaged.** `ntfsfix -n` on drive8.img through the engine's
guest shell: `$MFT and $MFTMirr completed successfully`, alternate boot sector
OK, `Volume Flags: 0x0000` — not dirty, no errors. So this is the stack's
behaviour and not a broken image.

**A full volume is not it either.** `full-volume-error.sh` fills one volume to
2.8 MB free and copies 6 MB into it:

    ditto exited 1, 23 of 60 arrived
    ditto: /Volumes/CROWD8/spill/f19.bin: No space left on device
    RESULT: a full volume says it is full, which is what it should say

So a single volume that runs out of room reports ENOSPC properly, which Finder
draws as "not enough free space". Fullness alone does not produce a stale
handle.

**What every occurrence has had in common** is twelve volumes opening at once
*and* volumes an earlier run had left nearly full; the five clean runs that
followed ran on volumes the harness had since emptied. That pairing is what is
being tried next, deliberately, with every volume filled to 8 MB free before
the twelve-way write.

### Nearly full and twelve at once: correct errors, no stale handle — 2026-09-03

Every volume filled to about 5 to 8 MB free, then the same twelve-way copy of
6 MB onto each.

    free on each before the write   5 5 5 8 5 5 5 5 7 5 8 6 MB
    byte-identical on 3, wrong on 9
    what the failures said          ditto: .../f10.bin: No space left on device
                                    ditto: .../f38.bin: No space left on device
    stale handles                   0, in three runs

So the pairing that every occurrence had in common is not the cause: twelve
volumes opening at once *and* nearly full produces "No space left on device",
correctly, on nine volumes at a time.

**And it kills the coincidence the last entry was built on.** `f10.bin` and
`f38.bin` are named here too, in ordinary out-of-space failures, on nine
different volumes at once. So `f38.bin` appearing in both stale-handle records
was never one in 3600 — it is simply where `ditto`'s ordering surfaces a
failure in a sixty-file copy. That reading is withdrawn.

**What is left.** The stale handle is not fullness, not a damaged fixture, not
a cached listing, not a single volume, and not the first write after an open on
its own. It is 3 occurrences in 16 twelve-volume runs, and the only thing every
one of them shares is the twelve-way first write itself. The harness now watches
a stale handle for three minutes and records whether the bytes come back, which
is the one thing that has never been captured and the thing that decides
whether this is a wrong message or a lost file.

### A withdrawn reading, and why the harness could make one — 2026-09-03

A run reported this, and it read like the worst possible finding:

    /Volumes/CROWD4 could not be read: cd: /Volumes/CROWD4/crowd-write: No such file or directory
      asked again: still failing
      room: such free of /Volumes/CROWD4:
      healed after 150s, 16 of 60 files

A volume gone mid-copy and returning with 16 of 60 files would be data loss.
It is not what happened. Those volumes were still full from the previous
experiment — nine of twelve failed with "No space left on device" in the same
run — so the copy never created `crowd-write` at all. The readback's `cd` then
failed, and the shell's own message went through the branch that pulls a
filename out of `find`'s complaint: hence a path nobody had asked about, a `df`
of a mount point that was perfectly fine, and a three-minute watch, all
reported as the stale-handle fault that branch exists to catch.

**Withdrawn.** No volume disappeared and no data was lost in that run.

Two things fixed rather than remembered: a missing directory now says the copy
made nothing, and a filename is only taken from a line that carries one. And
the twelve fixtures are reformatted before a hunt, because leftovers from an
earlier experiment are what put the volumes in that state in the first place.

### Eight clean runs on fresh fixtures, and what that points at — 2026-09-03

The twelve fixtures reformatted (`mkfs.ntfs` through the engine's guest shell,
the way `make-test-volumes.sh` builds them), then eight twelve-volume runs back
to back:

    runs 1 to 8    byte-identical on 12, wrong on 0, every time

Ninety-six volume-copies without a stale handle. Set against 3 occurrences in
the 16 runs before them, on fixtures that had been through a day of
experiments.

**What every stale handle followed.** A run killed mid-flight — engines shot,
images force-detached, nothing unmounted — because that is how this session
stopped runs that had to be abandoned. That is exactly how a volume is left
dirty, and exactly what a person does when they pull a drive out during a copy.
The eight clean runs are the first that did not follow one.

So the next thing is done deliberately rather than by accident:
`interrupted-then-crowd.sh` opens twelve, copies onto all of them, shoots the
machines and pulls the images with writes still in the air, and then opens the
twelve again and copies normally. The app is supposed to repair a volume left
that way — item 7 — so a stale handle on the next open is a repair that did not
happen, or one that left the volume mountable without leaving it sound.

### The root of the stale handle: a dangling index entry ntfs3 refuses — 2026-09-03

`interrupted-then-crowd.sh` — twelve opened, copied onto, the machines shot and
the images pulled with writes in the air, then the twelve opened again:

    round 1, 2 and 3, every time:
      copy onto /Volumes/CROWDn failed:
        ditto: /Volumes/CROWDn/crowd-write: Invalid argument   (all twelve)
      byte-identical on 0, wrong on 12
      RESULT: all 12 opened through the app, 0 byte-identical

All twelve open. Not one can be written to. Reproducible in every round.

**What the app does, from its own log.** ntfs3 refused the volume — "NTFS is
either inconsistent, or there is a hardware fault" — ntfs-3g refused it too,
then the repair rung ran `ntfsfix -n` to check and `ntfsfix -d` to correct,
which reported "processed successfully", and the volume mounted read-write.
Item 7's repair works: the app does repair and does not demote to read-only.

**What the repair leaves behind.** The kernel names it exactly:

    ntfs3(vda): MFT: r=1b, expect seq=4 instead of 8!
    ntfs3(vda): Mark volume as dirty due to NTFS errors

The interrupted copy left the parent directory's index entry pointing at MFT
record 27 with sequence number 4, while the record itself carries sequence 8.
ntfs3 checks that sequence and refuses — correctly; it is the protection that
stops a handle resolving to a different file after a record is reused. ntfsfix
does not repair it, because ntfsfix is not a chkdsk. There is no chkdsk here:
the guest carries ntfsfix, ntfsinfo, ntfsls, ntfscat, ntfsclone, ntfsundelete
and no checker at all.

**Measured, on one volume, both drivers, dirty flag cleared before each:**

    ntfs3     stat big  ->  Invalid argument
    ntfs-3g   stat big  ->  inode 27, directory, readable, and writable

So the driver is the whole difference. Over NFS the same refusal reaches the
Mac as errno 70, "Stale NFS file handle" — which is what a person copying in
Finder is shown, and it is the fault this whole afternoon was chasing.

**The name is poisoned, not just the folder.** Under ntfs3 that name cannot be
read, cannot be deleted, and cannot be recreated:

    mkdir /mnt/x/big  ->  Stale file handle

Removing it under ntfs-3g takes it out of ntfs-3g's listing and leaves ntfs3
refusing the name exactly as before. So a person who pulls a drive out during a
copy gets a folder they can never open, never delete, and never copy into
again — and the app hands that volume back saying it opened fine.

**Why it recurs on every open rather than settling.** ntfs3 marks the volume
dirty when it meets the bad entry. On the next open, dirty means ntfs3 refuses,
the ladder reaches the repair rung, `ntfsfix -d` clears the flag, and the volume
is handed back to ntfs3 — which meets the same entry again. The repair is
undoing the driver's own protective marking, once per open, forever.

**Detection is cheap, and was measured:** a read-only ntfs3 mount reports
nothing at mount time and two errors the moment the containing directory is
listed. So ntfs3 will say the volume is unfit for ntfs3, if anybody asks it.

### The driver swap moved the errno and fixed nothing — 2026-09-03

The first fix tried: after a repair, serve the volume with ntfs-3g instead of
handing it back to ntfs3. Built, tested (1130/1130), and measured against the
real app with `interrupted-then-crowd.sh`.

It did exactly what it said. 27 of the mounts came up on ntfs-3g against 3 on
ntfs3, the volumes were writable — a 100 KB file written to CROWD1's root
through the same mount, and a write into `crowd-write` itself, both succeeded
where before every one of the twelve refused everything.

And the copy still failed on all twelve:

    before   ditto: /Volumes/CROWDn/crowd-write: Invalid argument
             /Volumes/CROWDn has no crowd-write; the copy made nothing
    after    ditto: /Volumes/CROWDn/crowd-write/f10.bin: Input/output error
             find: '.': Input/output error
             never healed in 180 s
    files landed, either way   none

**So it moves EINVAL to EIO and nothing else.** ntfs-3g reads and writes that
entry inside the guest — measured, inode 27, a file created inside it — and
over NFS, which is the only route the app uses, it answers EIO on the same
entry exactly as ntfs3 answers EINVAL. ntfs-3g is not broken in general: an
ordinary write to the same volume through the same mount succeeds.

**Reverted.** Keeping it would put the slower metadata driver on every repaired
volume in exchange for a different error message. A change that costs speed and
buys no measured improvement is not a fix.

**Where the fix has to be.** The dangling index entry itself. Neither driver
can use that name over NFS, `ntfsfix` will not repair it, and the guest carries
no checker that would. The routes left are: teach the repair to drop an index
entry whose MFT reference has a stale sequence, or vendor a checker that can.
The first is a small, well-defined edit to a directory index — the entry refers
to a record that has been reused, so what it points at is already gone — and it
is what chkdsk does with one.

### `-o sync` does not prevent it either, and a ninety-second reproducer — 2026-09-03

Two things came out of trying to stop the damage rather than repair it.

**A reliable trigger, at last.** A folder written, deleted, and written again —
so the new entries land on MFT records the delete has just freed — with the
machine cut two seconds into the second write:

    round 1  plain      FOLDER BROKEN (Invalid argument)
    round 1  -o sync    FOLDER BROKEN (Invalid argument)
    round 2  plain      FOLDER BROKEN (Invalid argument)
    round 2  -o sync    FOLDER BROKEN (Invalid argument)

Four for four, about ninety seconds each, against one run in six at five
minutes through the twelve-volume harness.

**The delete is the whole recipe.** Without it, the same cut leaves nothing
wrong — three rounds, both arms:

    seq errors 0, the folder is not there

which is exactly what an interrupted copy should look like: the half-made
folder is simply absent afterwards. The damage needs a record that has been
freed and reused, because what breaks is a directory index entry keeping the
old sequence number while the record moves on. This corrects an earlier reading
in these notes: a first run appeared to show plain ntfs3 poisoning a name where
`-o sync` did not, and that was the leftover contents of the previous round,
not the mount option.

**So `-o sync` is not the fix.** Measured, not reasoned: identical outcome in
both arms of the reproduction. It is not applied.

**Two fixes tried and rejected on measurement now:** the driver order after a
repair, and a synchronous guest mount. What is left is the dangling index entry
itself — and neither driver, `ntfsfix`, nor anything else in the guest can
repair one. The route that remains is a checker the guest does not currently
carry.

### What can and cannot be repaired with what the guest already has — 2026-09-03

Everything below was measured against the ninety-second reproducer, on a volume
carrying the real damage.

**A rename frees the name.** Under ntfs3 itself, no extra tools:

    ls big            ->  Invalid argument
    mv big damaged    ->  succeeds
    mkdir big         ->  succeeds
    5 files written into the reclaimed name  ->  all 5 arrive

So the thing a person actually needs — to copy into their folder again — is
recoverable today, with a command the guest already has, and without
destroying anything: the damaged entry is moved aside rather than deleted.

**The remains cannot be removed.** The renamed entry is still unreadable, and:

    find damaged      ->  50 entries
    unlink each       ->  49 gone, 1 stuck
    second pass       ->  nothing further; readdir stops at the bad entry
    rmdir damaged     ->  Directory not empty, under ntfs3 and ntfs-3g alike
    rm -rf, ntfs-3g   ->  can't stat 'f1705.bin': I/O error

A fresh mount does not clear it, and `ntfsfix -d` before each attempt does not
either. So a repair built from what is here leaves a folder that looks empty
and cannot be deleted.

**Which puts the two routes plainly.**

Rename the poisoned entry aside and the person's copy works again. The residue
is one folder they did not make and cannot remove — and naming it with a
leading dot would keep it out of Finder, which hides dot-files by default, so
the cost of that route is a hidden directory rather than a visible mystery.
What it still needs is a way to *find* the poisoned entries without walking a
two-terabyte drive, and that is the open part.

Or vendor a checker into the guest that can drop an index entry whose MFT
reference has a stale sequence. That is what chkdsk does with one, it loses
nothing that is not already lost — the record has been reused, so what the
entry pointed at is gone — and it is the only route that leaves the volume
actually sound. The guest carries ntfsfix, ntfsinfo, ntfsls, ntfscat,
ntfsclone, ntfscmp, ntfscluster, ntfscp, ntfslabel, ntfsresize and
ntfsundelete, and no checker at all.

### The poisoned name is freed, through the app — 2026-09-03

A volume damaged by an interrupted copy, opened through the app, nothing else
done to it:

    root at once            .lukotta-unreadable-big
    into the reclaimed name 20 written, 0 refused
    read back               20 files, none the wrong size

Before this the same volume answered every write to that folder with "Invalid
argument" inside the guest and "Stale NFS file handle" through Finder, for
ever. The name is now free the moment the drive appears, the remains are kept
under a hidden name rather than destroyed, and nobody is asked anything.

**Four attempts came before it and each was killed by a measurement.**

    ntfs-3g after a repair   moved the errno from EINVAL to EIO, cured nothing
    -o sync on the guest     identical damage in both arms, four for four
    gated on the repair rung the damaged volume never reaches it
    gated on ntfs3 in dmesg  ntfs3 is not serving it; ntfs-3g is, silently

And two of my own bugs on the way, both caught by things that run rather than
things that are written down. A here-document made the TOML malformed and the
mount failed outright — caught by the check that refuses to report a mount that
did not happen, exit 74. And the walk replaced the repair on the repair rung, so
`ntfsfix` stopped running and a dirty volume went to a driver that refuses dirty
volumes — caught by `dirty-ntfs-repair.sh`, which was run out of habit rather
than by any system.

**Item 7 re-checked after all of it:** clean volume, corpus written, machine
taken away, confirmed dirty, opened by the app, takes a write, all 41 files
byte-identical. PASS.

### The ten items tied to checks that run, and what that exposed — 2026-09-03

`scripts/checks.tsv` and `scripts/verify.sh`: every claim this project makes
that something can check, with the check, run by one command. Tying them up
found three things that prose had been carrying.

**Item 2 has no check at all.** Its harness, `finder-copy-cycles.sh`, needs a
mounted volume passed to it, so the row as first written could never have run.
It says unchecked now rather than passing by omission.

**Item 3's check could not have seen its own fix.** `reused-record-interrupt.sh`
makes the damage and asks the guest about it — the right tool for judging a
candidate fix, and three were rejected on its evidence — but the reclaim runs
when the app opens a drive, and that harness never opens anything through the
app. As item 3's check it would have reported the fault unfixed for ever. It is
now checked by `reclaims-a-poisoned-name.sh`, which damages a volume, opens it
through the app, and requires the poisoned name gone, something moved aside
rather than destroyed, and twenty files written into the reclaimed name read
back whole. It holds.

**Item 1 passes on a fixture that cannot produce the fault.**

    1600 MB in 1 file, written in 3s
    n=82  p50 0.028s  p90 0.030s  p99 0.031s  worst 0.031s
    over 2s: 0   over 5s: 0

Set against the measurement the claim came from — thirteen gigabytes onto a
real USB drive: p50 28ms, p90 31ms, **p99 4.66s, worst 8.95s, nine requests past
five seconds**. The medians agree exactly and the tail is gone, and that is not
evidence the stall is fixed: 1600 MB went in three seconds, which is 533 MB/s,
because the fixture is a disk image on the internal SSD. The stall lived in
writeback to a slow drive, and this never reaches it.

So item 1's check is a regression guard, not a proof. It would catch the tail
coming back on this hardware; it cannot stand in for the drive the fault was
found on. What would make it real is the same write under the eight-gigabyte
ballast, where writeback has to compete, or a real slow drive — and until one of
those is run, item 1 rests on the 2026-09-01 measurement and not on this.

### Item 1 under the ballast: still cannot reach the fault — 2026-09-03

The route named in the last entry, taken. Same write, memory squeezed to what
an 8 GB Mac has:

    holding 8 GB, 63 MB free while it ran
    1600 MB in 1 file, written in 4s
    n=84  p50 0.028s  p90 0.031s  p99 0.059s  worst 0.059s
    over 2s: 0   over 5s: 0

Against the drive the stall was found on: p99 4.66s, worst 8.95s, nine requests
past five seconds.

**So memory pressure is not a stand-in for a slow drive.** Taking the memory
away doubled the tail — 0.031s to 0.059s — and left it two orders of magnitude
short of the threshold. The writeback still completes at SSD speed; what
starved was everything else. The fault needs a device that is actually slow to
write, and nothing on this Mac can make one.

**Item 1 therefore stands on the 2026-09-01 measurement and not on this check.**
The check is registered because it would catch the tail returning on this
hardware, and it is written down as a guard rather than a proof. The honest
gap: no automated check here can prove item 1, and proving it again needs the
USB drive it was found on.

### What the gate found when every row was made to run — 2026-09-03

The first full run reported six failures. Every one of them was the registry
and not the app:

    goal2, goal4, forks    the harness takes a mounted volume and the row
                           passed none, so it printed a usage line
    goal4 again            integrity-vectors.sh wants a path that exists and an
                           engine, and defaulted to a dev bundle not installed
    firstrun, heals        named /Applications/Lukotta Dev.app outright, so a
                           Mac without one reported "this build has no harness"
    homes                  ran 46 minutes and had to be killed by hand

That last one is the worst of them: nothing bounded a check, so everything
queued behind it never happened, and the run before that had stopped after
three rows entirely because a check read stdin and swallowed the rest of the
registry — printing "holds: 2" as though that were the whole picture.

**Three faults in the gate itself, all of the same family as the ones it
exists to catch:** it truncated itself in silence, it could hang for ever, and
it recorded its own bad rows as broken behaviour. Fixed: the list is read on a
separate descriptor with every check given /dev/null, each check is bounded
(1800s, 300s for the fast ones) and a check that outlives its bound fails
rather than stalling, and the harnesses that needed a mount point are handed
one by `with-a-drive-open.sh` rather than each growing its own copy of the
opening.

**With the rows fixed, one at a time:**

    goal1    holds -- as a guard only; the fixture cannot produce the fault
    goal3    holds -- damaged volume opened through the app, name reclaimed
    goal4    holds -- NTFS byte-identical through the app
    goal5    holds -- LUKS and the filesystems inside it
    goal6    holds -- every format the app advertises
    goal7    holds -- dirty volume repaired, 41 files byte-identical
    goal8    holds -- twelve served at every sample under the ballast
    goal9    holds -- every vector on every format
    goal10   holds -- 1144 checks
    firstrun holds -- once it could be pointed at a bundle that exists

**Item 4's claim is narrowed rather than left flattering.** There is no
BitLocker fixture here, so that half rests on the owner's own drive, and the
row now says so instead of implying the check covers it.

**Item 2 is the one real gap left.** No crash copying through Finder at both
extremes, which needs Finder driving the copy rather than ditto, and that is
what `finder-copy-cycles.sh` does -- now reachable, since the mount point is
handed to it.

### The resource fork is still dropped, and the route is closed at the protocol — 2026-09-03

The registry surfaced this on its first complete run, and it is not new: it was
found on 2026-09-01 and never fixed. A file carrying a resource fork is dropped
entirely during a copy, and a directory-wide `ditto` — which is what copying a
folder is — exits 0 having left it behind. Finder copies through the same
machinery.

Reproduced tonight against the app's own mount, with a real fork:

    ditto /tmp/rf/real.bin -> /Volumes/SWEEP/rf/real.bin
      ditto: /Volumes/SWEEP/rf/.BC.T_Wt441K: Invalid argument
      nothing arrives

Localised, one operation at a time, on the mounted volume:

    a plain ._ file, written directly        works
    an ordinary xattr on a file there        works, kept in ._plain.bin
    setxattr com.apple.ResourceFork          EINVAL
    writing ..namedfork/rsrc                 no error, and nothing stored

So AppleDouble emulation is working for ordinary attributes on this mount and
the resource fork alone fails.

**And mount_nfs(8) says why.** Named attributes — "used to store extended
attributes and named streams (e.g. FinderInfo and resource forks)" — are an
**NFSv4** feature, off by default, and available only "if the server appears to
support named attributes". Linux's nfsd has never implemented NFSv4 named
attributes. So there is no mount option and no export setting that makes this
work: the client can only store a resource fork over NFSv4 named attributes,
and the server can never offer them.

**What that means for the fix.** It is not a bug in the app's options, and no
amount of tuning reaches it. Serving resource forks would mean a protocol that
carries named streams — SMB does, natively, and macOS maps resource forks onto
it — which is an architectural change and not a setting. That is the honest
shape of it, and it is written down here rather than left as a check that
mysteriously fails.

**It stays a failing row.** Not withdrawn, not narrowed: the claim "extended
attributes and resource forks survive" is false today, a person loses a file
without being told, and the row says so every time the gate runs.

### Withdrawn: the resource fork was never dropped — 2026-09-03

Two hours ago this file recorded a resource fork as the most serious open
defect in the project: a file carrying one dropped entirely, `ditto` exiting 0
having left it behind, Finder using the same machinery, and mount_nfs(8) saying
the route was closed at the protocol. All of it wrong, and it had stood since
2026-09-01.

**The fixture wrote sixteen bytes and called them a resource fork.**
`printf 'RESOURCEFORKDATA' > f.bin/..namedfork/rsrc`. That is not a resource
fork, and macOS will not build an AppleDouble around it on any filesystem that
needs one.

Measured, both fixtures, both destinations:

    valid fork   -> local exFAT        data 13 bytes, fork 286 bytes
    valid fork   -> the app's mount    data 13 bytes, fork 286 bytes
    invalid one  -> local exFAT        ditto: .BC.T_PKvT4i: Invalid argument
    invalid one  -> the app's mount    ditto: .BC.T_hQ5awn: Invalid argument

A structurally valid fork — a 256-byte header and an empty resource map, which
is what an empty fork is on disk — copies through this app perfectly. The
malformed one fails identically on a plain local exFAT image with no NFS, no
guest, and none of this app anywhere near it.

**So it was never the NFS stack, never the client, and never this app.** The
earlier entry reasoned from a real error message to a real-sounding cause and
never asked whether the thing it was copying was what it claimed to be. The
mount_nfs(8) finding about NFSv4 named attributes is true and irrelevant: the
client stores forks in AppleDouble files perfectly well, which is what the 286
bytes are.

**`forks` holds now**, and it is the check that overturned it — a claim tied to
something that runs, run once, on a Mac. The same claim in prose survived two
days.

### Item 6 is narrower than the claim it checks — 2026-09-03

Item 6 is "every other format the app advertises. If the app claims it, it is
tested." What the website claims, against what `vectors-every-format.sh`
actually sweeps:

    claimed                          swept
    NTFS                             yes, ntfs-vectors
    ext2, ext3, ext4                 ext4 only
    btrfs                            yes, btrfs-vectors
    XFS                              inside LUKS only, never plain
    exFAT                            yes, exfat-vectors
    FAT                              no
    BitLocker                        no fixture exists; the owner's own drive
    LUKS1                            no
    LUKS2                            yes, as luks-ext4 and luks-xfs
    LVM inside LUKS                  no
    IMG, DMG                         implicitly, every fixture is one
    qcow2, VMDK, VDI, VHD, VHDX      no

So six of the twelve claims item 6 covers have never been through the vector
sweep, and the check has been reporting "every other format the app advertises"
as holding on six of them.

**Fixtures already exist for most of the gap** and are simply not swept:
`plain-xfs`, `plain-ext4`, `plain-exfat`, `luks1-lvm`, `luks2-direct`,
`luks2-lvm`, `luks-lvm-big`, `luks-multi`. They were built for other
experiments and never wired into the sweep, so the work of making them is
already done and the claim was still overstated.

What has no fixture at all: FAT, BitLocker, and the five virtual-disk formats.
BitLocker cannot be made here — nothing on macOS or Linux creates a BitLocker
volume, only reads one — so that half rests on the owner's drive and says so.
The rest can be built.

### Widening the sweep found a regression I had put in this morning — 2026-09-04

Eight more fixtures added to `vectors-every-format.sh`, covering the formats the
site claims that had never been swept. First run: **14 formats, 5 with
failures.** Four of the five were the same thing, and it was mine.

    luks1-lvm      the engine never mounted it
    luks2-lvm      the engine never mounted it
    luks-lvm-big   the engine never mounted it
    luks-multi     the engine never mounted it
    plain-exfat    11 passed, 1 failed (awkward names, the copy would not run)

**LVM inside LUKS was not broken. My guard was refusing it.** Traced by opening
one by hand: the group activates, three shares are served, and the helper
reports that nothing was —

    lvm-ubuntuvg.local:/run/disk5        -> /Volumes/disk5
    lvm-ubuntuvg.local:/run/disk5/ROOTFS -> /Volumes/disk5/ROOTFS
    lvm-ubuntuvg.local:/run/disk5/HOMEFS -> /Volumes/disk5/HOMEFS

    the mount script reported success and no volume is served
    open exit 74, drive torn down

The check added this morning — after an exFAT stick was reported as opened when
it had not — looked for `diskN.local:`, named after the device. A container of
logical volumes is named after the group. Narrowed to `.local:/mnt/` it was
still wrong: containers serve from `/run`. Both times it refused a mount that
had worked, and tore the drive down.

**Fixed and measured:** the same image now opens exit 0 with all three shares
served. It counts anything with `.local:` in it, before and after, and asks
whether this mount added one.

**What this says about the guard.** It was added to catch a mount that reported
success and served nothing, which is a real fault it does catch. It then caused
a worse one — refusing working mounts of an advertised feature — and nothing
noticed for a day, because no check covered LVM inside LUKS. The sweep that
found it exists because item 6 says "if the app claims it, it is tested", and
the app claims it.

### LVM inside LUKS, twelve vectors, first time — 2026-09-04

    ok   a killed copy leaves no corrupt file behind (40 whole, 0 wrong)
    ok   the volume still takes a write after a copy was killed
    ok   the volume mounts and reads after being unmounted under load
    ok   what was written before the unmount survived it
    ok   a full volume answers with an error, in 2s
    ok   three open/close cycles in a row (3 of 3)
    ok   everything written is readable by whoever wrote it (3 of 3)
    ok   awkward names and shapes survive a copy (10 whole, 0 wrong, 0 missing)
    ok   two writers and a reader at once leave nothing wrong (24 compared)
    ok   the filesystem comes back after the machine was killed mid-write
    ok   every fsynced file survived power loss (8 of 8 present, 0 wrong, 0 lost)
    ok   the volume takes a write again after power loss
    12 passed, 0 failed

The site has advertised "LVM inside LUKS: read yes, write yes" all along and
nothing had ever tested it.

**Getting there took four fixes, three of them to things that only looked like
the app failing.**

    the helper's guard      counted shares named after the device; a container
                            is named after its volume group, and serves from
                            /run rather than /mnt. It reported three working
                            mounts as none, exit 74, and tore the drive down.
    the harness's where()   looked for the same wrong name and said "the engine
                            never mounted it" about a group that had activated
    the harness's unmount   took one share of three, so the parent kept holding
                            the device and every reopen failed on a live lock:
                            0 of 3 open/close cycles, "never remounted" three
                            times over
    the disk                filled to 100% by 178 GB of fixture copies leaked
                            from killed runs, which showed up as exFAT failing
                            three vectors it had passed an hour before

Only the first was in the app, and it was mine, added this morning. The other
three were the harness reporting its own limits as the app's.

**What remains on the LVM fixtures:** `luks1-lvm` and `luks2-lvm` are too small
for the suite — 139 MB free where the vectors need 200 — and `luks-multi` still
does not mount. Both are written down rather than counted as passes.

### luks-multi: never asked, then never emptied — 2026-09-04

Two more harness faults, both of which had been reported as the app failing.

**"The engine never mounted it" was never being asked.** `--drive open=` takes
`/dev/diskNsM` and says so in its own usage line. `luks-multi` is a GPT image
with a Linux LVM partition, and the harness handed over the whole disk:

    open=/dev/disk5     ->  no drive at /dev/disk5, exit 2
    open=/dev/disk5s1   ->  exit 0, three volumes served
                            lvm-fedoravg.local:/run/disk5s1/FEDORAHOME
                            lvm-fedoravg.local:/run/disk5s1/FEDORAROOT
                            lvm-fedoravg.local:/run/disk5s1/FEDORABACKUP

**"The room comes back after a full volume (28 KB free)" was the harness's own
leftovers.** It filled the volume, removed only the directory it had filled, and
measured. On a 376 MB logical volume every earlier vector's data is most of the
space, so 28 KB came back. By hand, same kind of volume, clean:

    filled to           0 MB free
    deleted, +3s        242 MB free
    +6s, +9s            242 MB free

So the space is reclaimed at once and correctly. Every vector's data is cleared
at that point now.

**With both fixed:**

    luks-multi     12 passed, 0 failed
    luks-lvm-big   12 passed, 0 failed

That is LVM inside LUKS, two fixtures, twenty-four vectors, none failing —
against an advertised feature that had never been tested at all this morning.

### Eight fsynced files lost, on the second volume of an encrypted drive — 2026-09-04

Found only because the harness began choosing the roomiest logical volume
instead of the deepest-named one, which happened to be the first.

    luks1-lvm, before
      FAIL what was written before the unmount survived it
      FAIL every fsynced file survived power loss (0 of 8 present, 0 wrong, 8 lost)
      10 passed, 2 failed

    plain LUKS, same vector, same day        8 of 8 present, 0 wrong, 0 lost

**Why one volume of a drive was safe and the other was not.** A container's
first volume is bound from the mount the engine made, so it inherits everything
that mount was given -- including the `sync` a LUKS volume gets because the app
cannot read the filesystem inside it to choose anything cheaper. Every other
volume is mounted by the generated action:

    mount ${ro}/dev/<vg>/<lv> <scratch>/<name>

with nothing at all. The client-side option cannot reach them: those mounts are
made by the guest. So somebody with two logical volumes inside one encrypted
drive had one that survived a power cut and one that did not, and nothing
anywhere said which was which.

**Fixed and measured:**

    luks1-lvm, after      12 passed, 0 failed

The same intent is carried on the side that mounts them. Where the superblock
can be read the cheaper per-filesystem option is used instead of a blanket
sync, and a volume needing neither is given neither, because it is not free --
a gigabyte corpus costs 12 seconds against 17.

**This is the fourth defect the widened sweep has produced**, and the second
that was in the app rather than in the harness. Neither would have been found by
any check that existed yesterday: LVM inside LUKS had never been tested, and the
first volume of a container is the one that was always safe.

### Every advertised format, every vector, none failing — 2026-09-04

    ntfs-vectors    12 passed, 0 failed      luks1-lvm       12 passed, 0 failed
    ext4-vectors    12 passed, 0 failed      luks2-direct    12 passed, 0 failed
    btrfs-vectors   12 passed, 0 failed      luks2-lvm       12 passed, 0 failed
    exfat-vectors   12 passed, 0 failed      luks-lvm-big    12 passed, 0 failed
    luks-ext4       12 passed, 0 failed      luks-multi      12 passed, 0 failed
    luks-xfs        12 passed, 0 failed
    plain-xfs       12 passed, 0 failed
    plain-ext4      12 passed, 0 failed
    plain-exfat     12 passed, 0 failed

    14 formats run, 0 with failures

168 vectors. Twelve hours ago the same sweep covered six fixtures and reported
"every other format the app advertises" as holding; the eight added since found
two defects in the app and four in the harness, and every one of them read as
the app failing until it was chased.

The twelve vectors, on each of the fourteen: a killed copy leaving no corrupt
file, a write after that kill, unmount under load and what survived it, a full
volume answering with an error and the room coming back, three open/close
cycles, permissions, awkward names and shapes, two writers and a reader at once,
the filesystem coming back after the machine was killed mid-write, every fsynced
file surviving power loss, and a write after that.

**What is still not covered, said plainly.** FAT has no fixture and BitLocker
cannot have one -- nothing on macOS or Linux creates a BitLocker volume, only
reads one -- so that half of item 4 rests on the owner's own drive. The
virtual-disk formats the site marks experimental (qcow2, VMDK, VDI, VHD, VHDX)
have no fixtures either.

### What the durability options cost, from the sweep's own timings — 2026-09-04

The full-volume vector times one `dd` writing until the volume refuses, so the
number it reports is how long the volume took to fill, not how long the error
took to arrive. Across the fourteen:

    1 to 6 s     ntfs, ext4, btrfs, exfat, plain-ext4, plain-exfat,
                 luks2-lvm, luks-lvm-big
    76 to 156 s  luks-ext4 143, luks-xfs 156, plain-xfs 122, luks1-lvm 114,
                 luks2-direct 156, luks-multi 76

**It is not the encryption.** `plain-xfs` is unencrypted and takes 122 s where
`plain-ext4` takes 6. What the slow ones share is `sync`: XFS is given `-o sync`
in the guest because it has no data-journalling mode, and a LUKS container is
given a synchronous client because the app cannot read the superblock inside it
to choose anything cheaper. ext4 is given `data=journal` and is fast.

**As throughput, on roughly 1.9 GB:**

    plain-ext4, data=journal     6 s     about 316 MB/s
    plain-xfs, -o sync         122 s     about  16 MB/s

**This contradicts what is written in `ExtJournal.swift`**, which says `-o sync`
in the guest "costs nothing on a large file at all" and quotes 190 MB/s against
an ordinary client's 190. Both numbers cannot be right. The note was measured on
a fresh volume and this is a volume being filled to its last block, where an
allocator has to work harder — so the honest reading is that the two measure
different things and the cost of `sync` on a large write is currently unknown
rather than free.

**That is item 10's remaining question**, and it is now a specific one with a
cheap test: write a fixed large file to a fresh XFS volume through the app, with
the durability option and without it, and compare. Item 10 stays unmet until
that is a number.

### What the durability options actually cost — 2026-09-04

A 500 MB file, `conv=fsync`, the same volume mounted by the engine with the
option and without it, so the option is the only thing that changes:

    plain-xfs    no option          2 s    250 MB/s
                 -o sync            4 s    125 MB/s      2x

    plain-ext4   no option          2 s    250 MB/s
                 -o data=journal    3 s    166 MB/s      1.5x
                 -o sync            4 s    125 MB/s      2x

**Both earlier readings were wrong.** `ExtJournal.swift` says `-o sync` "costs
nothing on a large file at all" and quotes 190 MB/s — it is not free, it is
half. And this file's entry from two hours ago inferred 16 MB/s against 316
from the sweep's fill timings; that was allocator work as a volume reaches its
last block, not the option. Filling to ENOSPC and writing a fixed file are
different questions and the first is not a proxy for the second.

**What that means for item 10.** The options are not free and they are not a
degraded fallback either: without them a power cut loses 8 of 8 fsynced files,
with them it loses none. A copy at half speed against a copy that loses the
file is not a trade — it is the answer. They stay.

**Where there is something left to win.** A LUKS container gets the blanket
`sync` at 2x because the app cannot read the superblock inside it to choose
anything cheaper. An ext4 volume inside LUKS would take `data=journal` at 1.5x
if the app knew what was in there — and the engine reports `fs_type` once the
container is unlocked. That is a real improvement available to every encrypted
ext4 drive, and it is the next thing worth doing on item 10.

Two harness faults on the way to these numbers, both of the kind that has cost
this project whole afternoons: `dd`'s complaint went to `/dev/null`, so a write
that never happened was timed as "1 s, 1000 MB/s" — twice, identically, which is
what gave it away. And the engine was called without `--ignore-permissions`,
which the app always passes, so every write failed as "Permission denied" on a
root-owned volume.

### Item 10, settled: the durability options are correctness, not a fallback — 2026-09-04

The decision, taken here rather than handed back, by the rule that UX comes
first.

**The options stay.** Measured both ways on the same volume: without them a
power cut takes 8 of 8 fsynced files; with them, none. The cost is a 500 MB
write at 125 MB/s instead of 250 for `sync`, and 166 instead of 250 for
`data=journal`. A copy at half speed against a copy that loses the file is not
a trade, and a lost file is the worst user experience this app can produce.

**And the cost is narrow.** Only XFS, which has no data-journalling mode, and
LUKS containers, whose superblock the app cannot read. NTFS, ext4, btrfs and
exFAT pay nothing — their full-volume fills come back in 1 to 6 seconds against
76 to 156 for the others.

**The remaining 25% is not worth what it costs.** An ext4 volume inside LUKS
takes `sync` at 2x where `data=journal` at 1.5x would do, because nothing has
read what is inside. `anylinuxfs list -d` will say — by decrypting the container
in a machine of its own, which is about ten seconds added to every encrypted
open, before the drive appears. Ten seconds of waiting on every open, to make
large writes 25% faster on one kind of drive, is the wrong way round: a delay
before the drive appears is the most visible thing this app does, and a copy
finishing in 4 seconds instead of 3 is the least.

Caching the answer from a previous open was considered and refused. A cached
filesystem type that is wrong applies the wrong durability option, and that
loses data rather than time — the one thing not worth 25%.

**So item 10 holds on this evidence**: no new click, no new prompt, no new error
message, and the one performance cost in the app is the price of not losing
files, paid only by the two filesystems that cannot be served any other way.

### FAT, the last claim that could be built — 2026-09-04

    plain-fat    12 passed, 0 failed

The site lists FAT beside exFAT as read and write, and nothing had ever tested
it. `newfs_msdos` is part of macOS, so the fixture cost nothing to make and had
simply never been made — the same shape as the eight fixtures that existed and
were not swept.

**Item 6's claims and their fixtures, complete:**

    NTFS                   ntfs-vectors                12 of 12
    ext2, ext3, ext4       ext4-vectors, plain-ext4    12 of 12 each
    btrfs                  btrfs-vectors               12 of 12
    XFS                    plain-xfs, luks-xfs         12 of 12 each
    exFAT                  exfat-vectors, plain-exfat  12 of 12 each
    FAT                    plain-fat                   12 of 12
    LUKS1, LUKS2           luks1-lvm, luks2-direct     12 of 12 each
    LVM inside LUKS        luks2-lvm, luks-lvm-big,
                           luks-multi                  12 of 12 each
    BitLocker              no fixture can exist        the owner's own drive,
                                                       2026-09-02, byte-identical

**BitLocker is the only claim without an automated fixture**, and it cannot have
one: nothing on macOS or Linux creates a BitLocker volume, only reads one. It
was proven on the owner's Patriot stick on 2026-09-02 — Keychain unlock with
nothing typed, 205 files byte-identical, Finder copies at both extremes with
zero dialogs — and that is the strongest evidence obtainable on this hardware.

The virtual-disk formats the site marks experimental (qcow2, VMDK, VDI, VHD,
VHDX) still have no fixtures. They are marked experimental on the site, which
is the one place a claim is allowed to be narrower than the testing.

### An intermittent fsync loss on luks-multi, seen once and not reproduced — 2026-09-04

Inside a full gate:

    FAIL every fsynced file survived power loss (0 of 8 present, 0 wrong, 8 lost)
    note 0 of 30 in-flight files came back at full length
    11 passed, 1 failed

Not a partial loss — nothing came back at all. Chased immediately:

    the seven LUKS fixtures, standalone     7 formats, 0 with failures
    luks-multi alone, five runs             8 of 8 present every time
    two earlier full gates                  goal5 held in both

So roughly one in eight, and it has not been seen since. **It is written down
rather than closed**, because a total loss of fsynced data is the worst thing
this app could do and one occurrence is not noise until it is understood.

**What is known about why it is hard to trust either way.**
`kill-durability.sh` carries the caveat in its own head: a scratch image does
not reproduce the durability fault, because writes to an attached image reach
the backing file through the host's buffer cache, and killing the guest does
not discard that — macOS writes it out afterwards regardless. Only a real drive
is evidence. So on image fixtures this vector is approximate in the safe
direction: it under-reports. An intermittent total loss on an image is
therefore more likely the kill landing at an unlucky moment relative to the
host's flush than a fault in the app — and equally, five clean runs on an image
are not proof that there is none.

**What would settle it** is the same vector on a real drive, which is what
`kill-durability.sh` takes a device argument for. That needs a drive nobody
minds losing, plugged in.

### The real drive is not available for a power-loss test — 2026-09-04

`kill-durability.sh` takes a device because only a real drive settles the
durability question, and one is plugged in: `/dev/disk4`, 247.6 GB, NTFS.

It holds 212 GB of the owner's own data — `2024`, `2025`, `2026`,
`Laveg Архив` — with 20 GB free.

**It will not be used for this.** The vector kills a machine with writes in the
air, and an interrupted NTFS write is precisely what poisoned a directory entry
beyond recovery on 2026-09-03: unreadable, undeletable, and unrecreatable,
because `ntfsfix` is not a chkdsk and there is none here. That fault lands on
whatever directory was being written. Risking somebody's archive to chase an
intermittent that has been seen once is the wrong way round, and this whole goal
is about not losing their data.

What the drive is good for, and has been used for, is the non-destructive half:
a corpus copied on and read back byte-identical, Finder's own copies at both
extremes, the Keychain unlock. Those are on record from 2026-09-02.

So the intermittent stays open on the evidence available, and the route left is
to reproduce it on fixtures under the conditions it appeared in — inside a long
run, on a machine that has been busy — rather than on a drive that matters.

### Chasing the fsync loss: eighteen clean attempts, no reproduction — 2026-09-04

    the seven LUKS fixtures, standalone          7 runs, all clean
    luks-multi alone                             5 runs, all clean
    luks-multi and luks-lvm-big under ballast    6 runs, all clean, 63 MB free
    two earlier full gates                       goal5 held in both

Eighteen runs of the vector since the one failure, including six with memory
squeezed to what an 8 GB Mac has — which was the closest guess at what made the
failing run different, since it happened deep inside a long gate on a machine
that had been running microVMs for forty minutes. **Memory pressure is not the
trigger.**

So it stands at one occurrence in about nineteen, cause unknown. What has been
ruled out: the fixture, the filesystem inside it, repetition, and memory
pressure. What has not been tried is the only thing that would be evidence
either way — the same vector on a real drive — and the drive available holds
212 GB of the owner's archives, which is not a thing to kill a machine over.

## NTFS loses committed writes on a real drive — 2026-09-04

The owner confirmed the 247 GB stick at /dev/disk4 is a test drive with nothing
unique on it, so the vector that only a real drive can answer was finally run.

`dd conv=fsync` returns once the NFS client's COMMIT has been answered, so an
application that fsyncs and is told it succeeded has every guarantee the
platform offers at that moment. The machine is killed straight after.

    run 0    RESULT: present but changed -- 8388608 bytes,
             sha256 e8271900d5ec86ed... wanted de4342c21015f438...
    run 1    RESULT: the file is not there. A committed write was lost.
    run 2    RESULT: the file is not there. A committed write was lost.
    run 3    RESULT: the file is not there. A committed write was lost.

**Four for four.** Once corrupted at the right size, three times gone entirely.
This is NTFS, the format most of this app's users have, and it is the one
format given no durability option at all: `ExtJournal.durabilityOption` returns
`data=journal` for a journalled ext, `sync` for XFS, and nothing for NTFS.

**No fixture shows this.** Every image sweep passes the same vector, 168 vectors
across fourteen formats, because writes to an attached image reach the backing
file through the host's buffer cache and killing the guest does not discard it
-- macOS writes it out afterwards regardless. `kill-durability.sh` said so in
its own head and it was right. A real device has no such cache behind it.

**And the harness that says so had never run.** `open_device` is called by that
script and defined in no version of it in the history; neither is `where`. So it
has never got past that line, while its head states results as though it had
measured them. Both are written now, which is how these four runs happened at
all.

**This is item 9's power-loss vector failing on the app's commonest format**, and
it was invisible for as long as it was only ever asked of disk images.

### The NTFS loss survives `sync`, and the flush patches are already in — 2026-09-04

Two fixes were made and neither closed it.

**The option was not reaching NTFS at all.** `mountOptions` dropped `durability`
whenever a driver was named — `if let durability, driver == nil` — on the
reasoning that the named drivers are the NTFS ones and durability belongs to
ext. True of `data=journal`, which an ext volume without a journal will not
mount with; not true of `sync`, which is a plain VFS option. Fixed: the test is
what the option is, not whether a driver was named.

**And nothing chose one for this drive anyway.** It is BitLocker, and the app
reads `-FVE-FS-` where it looks for a filesystem. The fallback for a container
that hides its superblock existed and asked only about LUKS. Fixed: BitLocker
takes the same blunt `sync`.

Both verified in the mount itself:

    mount args: ["-t", "ntfs3", "/dev/mapper/btlk0", "/mnt/BACKUP2_TS",
                 "-o", "sync,iocharset=utf8,uid=501,gid=20"]

**And the drive still loses the write. Four for four:**

    run 1  RESULT: the file is not there. A committed write was lost.
    run 2  RESULT: the file is not there. A committed write was lost.
    run 3  RESULT: the file is not there. A committed write was lost.
    run 4  RESULT: the file is not there. A committed write was lost.

**The engine already carries both flush patches.** Read out of the shipped
bundle's own `PATCHES` file: `imago-flush-device-nodes` and
`krun-devices-raw-device-flush` are both there. So this is not an engine built
without them, which is what the harness's head supposed the fault to be.

**So the write is lost somewhere the guest's `sync` does not reach.** The file
is *absent* rather than short or wrong in three runs of four, which points at
NTFS metadata — the MFT entry naming the file — rather than at its data blocks.
A mount option that makes data writes synchronous need not make ntfs3 commit
metadata on the same schedule.

**What has not been separated yet** is BitLocker from NTFS. The loss is measured
through dm-crypt on `/dev/mapper/btlk0`, and a plain NTFS partition on a real
device would say whether the encryption layer is involved. The only real drive
here is the one carrying the BitLocker fixture that item 4's proof rests on, so
that separation costs the evidence for another item and has not been taken.

### On a real drive, nothing is on the disk until the volume is ejected — 2026-09-04

Three measurements, one conclusion.

    kill immediately after fsync returned      the file is not there
    kill 15 seconds after                      the file is not there
    kill 60 seconds after                      the file is not there
    clean unmount, then reopen                 survived, byte-identical

**So it is not writeback timing.** Waiting a minute changes nothing; ejecting
changes everything. The data is held somewhere that drains only on a clean
unmount, and a killed machine discards it entirely.

**What that means for somebody using the app.** Pull a drive out without
ejecting it — the thing every person does at least once — and everything written
since it was opened is gone. Not the last few seconds: everything. Files copied
an hour earlier, reported complete by Finder, fsynced and confirmed by the
platform, are not on the disk.

**And the guest is doing its part.** `/sys/block/vda/queue/write_cache` reads
`write back`, so the guest believes there is a volatile cache and issues a flush
on every fsync. The mount carries `-o sync`. The shipped engine's own `PATCHES`
file lists `imago-flush-device-nodes` and `krun-devices-raw-device-flush`. Every
layer above the host's device backend is asking for the write to be made
durable, and it is not being made durable.

**Why no fixture could show it.** An image is a file: imago writes reach the
host's page cache, which is the kernel's and survives the process being killed,
so macOS writes them out afterwards regardless. A raw device has no such cache
behind it — whatever is holding these writes belongs to the process, and dies
with it.

**This is the root of item 9's power-loss vector on real hardware**, and it is
below everything the app controls in the mount: the option is applied, the flush
is issued, and the write is still not on the disk.

### Every lever the app has, eliminated on the real drive — 2026-09-04

Each of these was applied, verified in the mount, and measured on the real
drive with `dd conv=fsync` returning before the machine was killed.

    guest -o sync on the filesystem      verified in the mount args   3 of 3 lost
    a synchronous NFS client             verified: General mount flags
                                         0x200002 sync,noowners      3 of 3 lost
    ntfs-3g instead of ntfs3             verified by the ladder       3 of 3 lost
    waiting 60 s before the kill                                      lost
    a clean unmount instead of a kill                                 survives

**So it is none of them.** Not the filesystem mount option, not the NFS client,
not the NTFS driver, not time. The shipped engine already carries
`imago-flush-device-nodes` and `krun-devices-raw-device-flush`. Every layer the
app can reach is asking for durability and not getting it, and the data is held
somewhere that only a clean unmount drains.

**This corrects a claim in this file.** An earlier entry says a synchronous
client fixes it — "8 of 8 kept, 30 of 30 in-flight files complete". It does not,
on a real drive. That measurement can only have been taken on a disk image,
where the host's page cache makes every arrangement look durable.

**The synchronous client is withdrawn.** It was wired up to test this and it
buys nothing measurable here, while `ExtJournal.swift` records what it costs: a
large file at 3 MB/s against 190. Paying sixty times the write for no durability
is the worst trade available, and it is not made.

**Where the fault has to be.** Below everything above: the engine's device write
path. patches/README.md reaches the same place from the other direction, saying
`krun-devices-raw-device-flush` "does not make fsync durable" and that the loss
is above it. Both ends now point at the same middle, and closing it is an engine
patch rather than an app change.

**What ships today is honest about it in one respect and not another.** A drive
ejected properly keeps everything, byte-identical, every time — that is measured
and it is the ordinary case. A drive pulled out without ejecting loses
everything written since it was opened.

### The guest does issue the flush — counted, not assumed — 2026-09-04

`/sys/block/vda/stat`'s sixteenth field is `flush_ios`, so the kernel will say
whether a barrier was ever asked for:

    before the write        flush_ios 1
    after dd conv=fsync     flush_ios 3
    after umount            flush_ios 12

So the guest issues flushes on fsync, two of them for one file, and eleven more
when the volume is put away. `/sys/block/vda/queue/write_cache` reads
`write back`, which is why: the guest believes there is a volatile cache to
flush and behaves accordingly.

**Which closes the last question above the engine.** The chain is: the client
asks (verified, `sync` in the mount flags), the filesystem is mounted
synchronously (verified in the mount args), the guest issues the barrier
(counted here), and `krun-devices-raw-device-flush` answers it by flushing
imago's own cache and then calling `sync()` on the file, which for a device node
is `DKIOCSYNCHRONIZECACHE`. Every link says it is doing its part, and on a real
drive the write is gone.

**What is left is instrumenting the engine itself**, which means building it
from `scripts/build-engine.sh` with a probe in the FLUSH arm to see whether the
request arrives and what the device answers. That is the next piece of work on
this, and it is a different kind of work from everything above it: the app has
no lever left to pull.

## The poisoned name happens on real hardware too — 2026-09-04

The durability harness stopped being able to write, and the reason was not the
drive and not durability. It was the fault found yesterday on fixtures,
reproduced on a real BitLocker/NTFS drive by the harness's own kills:

    mkdir lukotta-durability   Input/output error
    ls    lukotta-durability   Input/output error
    rmdir lukotta-durability   Input/output error
    a fresh name               created without complaint

The name is in the listing and cannot be read, removed, or recreated. Exactly
the shape of the fixture fault -- unreadable, undeletable, unrecreatable -- with
EIO here where ntfs3 said EINVAL on an image.

**Which means the reclaim does not cover this case.** It is gated on the ntfs-3g
rung, on the reasoning that reaching ntfs-3g means ntfs3 refused the volume and
that is the signal of damage. This drive mounts on ntfs3 and is damaged, so the
reclaim never runs and the name stays poisoned for good.

**And it corrects the durability finding above.** The first run's loss was real
-- it wrote 8 MiB, fsync returned, a sha was taken, and the file was gone after
the kill. The runs after it were not: each killed the machine while writing into
a name its predecessor had poisoned, so the write never happened at all and the
harness, which did not check, reported "a committed write was lost" about a
write that was never made. Three of the four, and every run since.

So the honest state of the durability question is **one measured loss, not
four**, and it needs re-running now that the harness refuses to give a verdict
when nothing was written and now that a fresh directory name is used each time.

### The NTFS durability option is withdrawn: it buys nothing — 2026-09-04

The counterfactual, on the real drive, a fresh witness directory each run:

    without the durability option    survived, byte-identical    3 of 3
    with it                          survived, byte-identical    3 of 3

**So `sync` on NTFS makes no difference to whether a committed write survives**,
and it costs half the throughput — 250 MB/s becomes 125, measured. Paying that
for nothing is not a trade, so the three changes made this evening on the
strength of the original reading are withdrawn:

    ExtJournal: NTFS -> "sync"                             withdrawn
    the container fallback extended to BitLocker           withdrawn
    mountOptions letting durability sit beside a driver    withdrawn

**And the original finding shrinks to one occurrence.** "Four for four" was
three runs writing into a name the first run's kill had poisoned; the harness
did not check its own write and reported a lost commit about a write never made.
What is left is a single run: 8 MiB written, `fsync` returned, a sha taken, the
file present afterwards at the right size with different bytes. One event, in
now more than a dozen runs of the same test, and not reproduced since the
harness was made honest.

**What ext4 and XFS need is unchanged and still measured.** Those lose eight of
eight fsynced files without their options, on images, which is where that was
established and where it holds. NTFS was never shown to need one and is not
given one.

**The lever stays.** `LUKOTTA_NO_DURABILITY` withholds the option so this
comparison can be made again in one command rather than by rebuilding twice.

### The counterfactual was not one, and the answer holds anyway — 2026-09-04

The comparison that justified withdrawing the NTFS durability option was
invalid. `LUKOTTA_NO_DURABILITY` was read in the privileged daemon, which does
not inherit the environment of whoever runs the app, so both arms of "with it
and without it" had it. Six runs of the same thing, presented as a controlled
comparison. The same flaw applied to `LUKOTTA_NTFS_FIRST`: the run meant to use
ntfs-3g reported `ntfs3` in its own mount args and had changed nothing.

Both levers are removed. An experiment lever that silently does nothing is worse
than none.

**Redone properly**, with the option genuinely absent from the build and the
mount args showing it:

    mount args: ["-t","ntfs3","/dev/mapper/btlk0","/mnt/BACKUP2_TS",
                 "-o","iocharset=utf8,uid=501,gid=20"]

    run 1  survived, byte-identical (8388608 bytes)
    run 2  survived, byte-identical (8388608 bytes)
    run 3  survived, byte-identical (8388608 bytes)

So NTFS survives a killed machine with no durability option, and the withdrawal
stands — on evidence this time rather than on a comparison that never happened.

### The poisoned name cannot be freed on real hardware — 2026-09-04

The reclaim was broadened to every writable NTFS mount, and made to say what it
did. On the real drive it says:

    could not move: /mnt/BACKUP2_TS/lukotta-durability

So it runs, it finds the entry, and the rename fails. From the host every call
on that name fails the same way -- `ls`, `stat`, `mv`, `rm`, `mkdir`, all EIO --
and `test -e` and `test -d` both answer no while the name sits in the listing.

**This is worse than the fixture case.** There the entry answered EINVAL and a
rename moved it aside, which freed the name. Here nothing touches it. The
reclaim is right to try and cannot succeed, so a name poisoned on real hardware
stays poisoned.

**What is left is a repair the platform does not have.** The entry is a
directory index record NTFS itself will not resolve; freeing it means editing
that index, which is what chkdsk does and which nothing on macOS or Linux
offers. The honest position is that this app cannot undo it, and the work that
matters is making sure it never happens -- which is item 3, and which is about
what an interrupted copy leaves behind rather than what can be recovered after.

### An interrupted copy on the real drive leaves a clean partial result — 2026-09-04

The vector item 3 is hardest on, run on the owner's drive: a 400-file copy
started, the machine killed two seconds in, the drive reopened, the folder
examined.

    round 1   10 files kept, writable yes, removable yes
    round 2   10 files kept, writable yes, removable yes
    round 3    9 files kept, writable yes, removable yes
    round 4    7 files kept, writable yes, removable yes

Four for four. The folder is listed, readable, holds the files that made it,
takes a new write, and can be deleted. That is exactly what an interrupted copy
should leave, and it is what a person pulling a drive out mid-copy now gets.

**Which leaves the poisoned `lukotta-durability` needing an explanation, since
this does not reproduce it.** What is different about it: it was made and killed
repeatedly during the runs where the app was applying `-o sync` to NTFS -- the
durability option added and withdrawn this evening. Every interrupted copy since
that option came out has been clean.

That is a correlation across a handful of runs, not a demonstration, and it is
written as one. What can be said without stretching: the fault has been seen
once on real hardware, in a window where an option was in force that is no
longer in force, and it has not been seen in four attempts since.

**And it makes the reclaim's position clear.** It cannot free a poisoned name on
real hardware -- measured, "could not move" -- so its value rests entirely on
the fixture case, where a rename does work. It stays for that, and it is not
what protects a real drive. What protects a real drive is the interrupted copy
leaving nothing broken in the first place, which is what these four runs show.

### Ten interrupted copies on the real drive, all clean — 2026-09-04

Six more rounds on the owner's drive, a 500-file copy killed three seconds in:

    round  5   7 files kept, writable, removable
    round  6   6 files kept, writable, removable
    round  7   7 files kept, writable, removable
    round  8   5 files kept, writable, removable
    round  9   7 files kept, writable, removable
    round 10   7 files kept, writable, removable

**Ten of ten**, counting the four before them. Every interrupted copy leaves a
folder that is listed, readable, holds the files that made it, takes a new
write, and deletes cleanly. Nothing poisoned, nothing stuck, nothing a person
would have to work around.

That is item 3's hardest vector — an interrupted copy — measured on real
hardware rather than on an image, ten times.

**One piece of litter is left on that drive and cannot be removed.** The folder
`lukotta-durability`, poisoned during this evening's earlier runs, refuses `ls`,
`rm`, `mv` and `mkdir` alike. Everything else this testing put there has been
cleared. It is recorded here rather than quietly left, because it is the
physical evidence of the fault and because the owner should know it is there.

### ntfs-3g cannot free it either, and Alpine has no checker — 2026-09-04

The earlier "ntfs-3g also fails" was taken through a lever that did nothing, so
it was never tried. Tried properly, by building the ladder the other way round
and confirming from the mount action which rung was in force:

    ls      Input/output error
    stat    Input/output error
    mv      Input/output error
    rm -rf  Input/output error

So neither driver can touch the entry on real hardware. On a fixture, ntfs-3g
could move it aside; here nothing can.

**And there is no checker to be had.** The guest is Alpine, and Alpine packages
only `ntfs-3g`, `ntfs-3g-libs` and `ntfs-3g-progs` — `ntfsfix`, `ntfsinfo`,
`ntfsls` and the rest, with no `ntfsck` among them and no separate ntfsprogs.
Freeing a poisoned index entry means a tool built from source and vendored into
the guest image, which is a piece of work in itself and is where this goes next.

**What the drive is today.** Ten interrupted copies clean, three committed
writes surviving a killed machine, copies byte-identical, the Keychain unlock
working with nothing typed. One folder from this evening's earlier runs cannot
be removed and everything else has been cleared.

## The twelve vectors on the real BitLocker drive — 2026-09-04

The suite taught to take a device, and pointed at the owner's stick:

    ok   a killed copy leaves no corrupt file behind (8 whole, 0 wrong)
    ok   the volume still takes a write after a copy was killed
    ok   the volume mounts and reads after being unmounted under load
    ok   what was written before the unmount survived it
    FAIL a full volume answers rather than hanging (still going after 303s)
    ok   three open/close cycles in a row (3 of 3)
    ok   everything written is readable by whoever wrote it (3 of 3)
    ok   awkward names and shapes survive a copy (10 whole, 0 wrong, 0 missing)
    ok   two writers and a reader at once leave nothing wrong (24 compared)
    ok   the filesystem comes back after the machine was killed mid-write
    ok   every fsynced file survived power loss (8 of 8 present, 0 wrong, 0 lost)
    ok   the volume takes a write again after power loss
    11 passed, 1 failed

**Eleven of twelve, on real hardware, through BitLocker.** Including the two
that no disk image can honestly answer: the filesystem coming back after the
machine was killed mid-write, and every fsynced file surviving power loss —
8 of 8, on a device with no host page cache behind it to make it look good.

**The one failure is the harness's bound.** 300 seconds fills a two-gigabyte
fixture many times over and does not come close to filling a drive with 20 GB
free, so the fill was cut off and reported as the app hanging. The bound is now
the free space at ten megabytes a second, which is a pessimistic floor for this
stack over USB, and never less than the old 300.

## A real NTFS checker exists, and it builds for the guest — 2026-09-04

The claim that freeing a poisoned index entry needs Windows was wrong. It needs
a checker, and one is being actively developed: **ntfsprogs-plus**, a fork of
ntfs-3g's utilities whose stated purpose is `ntfsck`, "a filesystem checking
utility comparable to Windows' chkdsk". GPLv2, 649 commits, and among its checks
are the two this fault is made of -- "directory structure verification and index
checking" and orphaned MFT scanning.

Built for the guest, in an Alpine 3.24 arm64 container matching the guest's own
distribution and architecture:

    ntfsck v1.0.0
    -a  auto-repair, no questions      -n  check without repairing
    -y  yes to every question          -S  aggressive salvage
    -f  repair even if Windows hibernated the volume

Run against one of this project's own NTFS fixtures:

    Parse #1: Reset logfile.                    100% completed
    Parse #2: Scan mft entries in volume.       100% completed
    Parse #3: Check system files.               100% completed
    Parse #4: Check index entries in volume.    100% completed
    Parse #5: Scan orphaned MFTs candidiates.   100% completed
    Parse #6: Check orphaned mft.               100% completed
    Clean, No errors found or left (errors:0, fixed:0), exit 0

Parses #4 and #5 are the ones that matter here: a poisoned name is an index
entry pointing at an MFT record that will not resolve.

**Docker is the build environment, not a dependency.** The binary is 1.6 MB of
aarch64 musl ELF and goes into the guest image beside `ntfsfix`, exactly as the
rest of the ntfs tools already do. Building the engine already needs Rust, llvm
and lld that no user installs; this is the same arrangement.

**Still to prove:** that it actually frees a poisoned entry. A clean volume
coming back clean says the tool runs, not that it repairs. The next measurement
is a deliberately poisoned fixture, before and after.
