# Measurements

Every number here was produced by running it on this Mac.

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
