# Patches

Changes to upstream that are ours to carry. Nothing here is applied by the
build: the engine still comes from the pinned, checksummed bottle named in
`vendor/engine.lock`. These are written down so the work is not lost and so the
next person can see what was decided and why.

## anylinuxfs-vmdk.patch — not applied

**What it does.** Exposes VMDK. libkrun already reads the format — its header
defines `KRUN_DISK_FORMAT_VMDK = 2` alongside `RAW` and `QCOW2`, and the image
layer inside the engine's binary carries VMDK descriptor parsing — but
anylinuxfs's own `DiskFormat` enum stops at `Raw` and `Qcow2`, so nothing can
ask for it. The patch adds the third case, maps it to the constant, recognises
`.vmdk` by name, and replaces three `== DiskFormat::Qcow2` tests with
`is_encoded()`, since each of them was really asking "is this an encoded image
rather than a raw device" and VMDK is one too.

**Why it is not applied.** Building anylinuxfs from source needs a Homebrew
LLVM at `/opt/homebrew/opt/llvm/bin/clang`, to cross-compile the Linux init blob
that `krun-init-blob` builds:

    cc_linux: /opt/homebrew/opt/llvm/bin/clang: No such file or directory
    failed to compile .../krun-init-blob-0.1.0-1.19.3/init/init.c: exit status: 126

Everything up to that point works: the source tarball matches the checksum in
the lock, a Rust toolchain builds the workspace's other crates, and
`download-dependencies.sh` fetches the kernel and helpers. It is a missing
dependency, not a broken patch.

**What it would take.** `brew install llvm`, roughly 2 GB. Then the harder half:
the app currently vendors a checksummed upstream bottle, and building the engine
ourselves changes how it is vendored, how a release is reproduced, and what the
GPL corresponding-source offer has to cover — since we would be distributing a
modified anylinuxfs rather than upstream's. That is a deliberate change to the
release story, not a side effect of wanting one more format.

**The alternative** is upstream taking it. The patch is small and the support is
already in the libkrun underneath, so there is a decent case for it.

**Untested.** The patch is written and consistent but has never been compiled,
because the build stops before reaching it. Treat it as a starting point.

**A caveat that applies to qcow2 as well**, from libkrun's own header: formats
other than raw can reference other files — a qcow2 backing file, a VMDK
descriptor naming its extents — and libkrun opens them. A hostile image can
therefore make the guest read files the person who opened it could read.
Container files run unprivileged for exactly this sort of reason, so the reach
is limited to that user's own files, but it is worth knowing before widening
what is accepted.
