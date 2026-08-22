# Patches

Changes to upstream anylinuxfs that Lukotta carries. `scripts/build-engine.sh`
fetches the source pinned in `vendor/engine.lock` — the same checksum the
release verifies — applies everything here, and builds the two binaries that
change. Everything else still comes from the checksummed bottle.

`scripts/vendor-engine.sh` writes the names of the applied patches into
`engine/anylinuxfs/PATCHES`, and the app reads that rather than assuming what it
can do. **Building without this step produces a working app** — one without
these fixes, which then says so instead of failing oddly.

Both are GPL-3.0-or-later, like anylinuxfs and like Lukotta. `collect-sources.sh`
puts them in the corresponding source shipped with every release, so a recipient
gets the modification as well as the original.

## vmproxy-decrypt-what-it-probes.patch

**The bug.** Encryption inside a disk image was never unlocked. The host probes
an image only far enough to know that it is one — `unprobed_image` sets
`fs_type: "auto"` — so the list of devices to decrypt, which is built from that
type, comes out empty. Inside the guest, `blkid` then correctly reports
`crypto_LUKS`, and that string is passed to `mount` as a filesystem type:

    mount args: ["-t", "crypto_LUKS", "/dev/vda", "/mnt/container.qcow2"]
    mount: unknown filesystem type 'crypto_LUKS'

**The fix.** The guest already knows how to unlock — `activate_volume_managers`
does exactly this when the host said the type. So after `detect_fs_type` has
found the truth, if it is an encrypted volume and nothing was decrypted already,
unlock it and look again. `prepare_for_probed_encryption` picks the right tool
first, because the choice between `cryptsetup open` and `bitlkOpen` is otherwise
made from the type the host sent, which for an image is "auto".

**Verified.** A LUKS2 container inside a qcow2 mounts, and the file written into
it reads back. The end-to-end test covers it.

## anylinuxfs-vmdk.patch

**What it does.** Exposes VMDK. libkrun already reads the format —
`KRUN_DISK_FORMAT_VMDK = 2` sits in its header beside `RAW` and `QCOW2`, and the
image layer inside the engine carries VMDK descriptor parsing — but anylinuxfs's
own `DiskFormat` enum stopped at `Raw` and `Qcow2`, so nothing could ask for it.
The patch adds the case, maps the constant, recognises `.vmdk`, and replaces
three `== DiskFormat::Qcow2` tests with `is_encoded()`, since each was really
asking whether the image needed decoding at all.

**Tested.** A monolithicFlat VMDK — a text descriptor beside a raw extent, which
is what VMware writes — is read, mounted and ejected through the app, including
one holding a LUKS container. The end-to-end test builds one and opens it.

Sparse VMDKs and snapshot chains are not supported by the engine's image layer,
and the app says so by name rather than letting either fail obscurely.

## What this costs

Building the engine needs a Rust toolchain and, because vmproxy is a Linux
binary and libkrun embeds a Linux init, Homebrew's llvm, lld and util-linux:

    brew install llvm lld util-linux
    rustup target add aarch64-unknown-linux-musl
    ./scripts/build-engine.sh

## A note that outlives these patches

From libkrun's own header: formats other than raw **can reference other files,
which libkrun opens**. A qcow2 backing file, a VMDK descriptor naming its
extents. So an image can choose which other files the virtual machine reads.

Lukotta refuses any qcow2 that names another file, before the engine is told
anything about it — see `Qcow2Header.namesAnotherFile`.

A VMDK is different and needs its own rule: it **always** names another file.
The descriptor is read whole and capped at 2 MB, so the data cannot live inside
it — there is no self-contained form. So the rule there is that every extent
must be a plain file name sitting beside the descriptor: nothing absolute,
nothing with a separator, no `..`. That is exactly what VMware writes, and it
stops a descriptor reaching anywhere else on the disk. See
`VmdkDescriptor.namesAFileElsewhere`.

Container files also run unprivileged, which bounds the reach to what the person
who opened it could already read. None of that is a reason to relax the checks
when more formats are added.
