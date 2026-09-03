# Measurements

Every number here was produced by running it on this Mac.

## Where the ten stand, 2026-09-03

Not a MET line. Read the entries themselves for the numbers; this is only so
that what is proven and what is not can be seen at a glance, and so that
"measured through the engine" is never again mistaken for "measured".

    1  writing does not stall     the nfsd COMMIT fault traced and worked
                                  around; the loopback livelock found and
                                  fixed today, 10 addresses to 12, with the
                                  before and after written down
    2  no crash through Finder    copies done by Finder on a real stick, both
                                  extremes, nothing user-visible
    3  nothing user-visible       held everywhere it has been looked at, and
                                  the silent stall found today was exactly
                                  this fault arriving from a new direction
    4  NTFS and BitLocker         byte-identical, unlock from the Keychain
    5  LUKS and Linux             byte-identical
    6  every other format         all seven writable formats, byte-identical
    7  dirty NTFS repaired        PROVEN ON BOTH SHAPES: a Microsoft partition
                                  type, and a whole disk with no partition
                                  table at all, 41 of 41 each, nothing shown
    8  a dozen at once            twelve opened through the app and written to
                                  and read back today, flat at 72-75 s each.
                                  NOT the 8 GB machine the item names, and the
                                  footprint and responsiveness at twelve are
                                  still unmeasured on this route
    9  every vector               twelve vectors pass twice -- through the
                                  ENGINE, not the app. Real for the storage
                                  path, unproven for the app's. THROUGH_APP=1
                                  now exists to close that
    10 no UX cost                 unmet for XFS writes on real drives: -o sync
                                  costs 47x on a device. Everything else free

The three measurements found today to have been taken off the route a person
takes -- the dozen, the eight-gigabyte figures, and item 9's vectors -- are all
noted in place rather than deleted. Each says what it does and does not cover.

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
