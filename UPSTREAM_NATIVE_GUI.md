# Native GUI provenance

The permanent disk interface is the official **anylinuxfs-gui 0.7.5** macOS
Apple-Silicon release from:

- https://github.com/fenio/anylinuxfs-gui/releases/tag/v0.7.5
- source tag: https://github.com/fenio/anylinuxfs-gui/tree/v0.7.5

The wrapper downloads the release DMG on first setup and verifies SHA-256:

`701118b5d04368a5153fa0f39d4fb78206509f409d6088797802efbab462fa3f`

Relevant upstream 0.7.5 behavior used by this wrapper:

- `ANYLINUXFS_PATH` can point the GUI at a specific anylinuxfs executable.
- the encrypted-volume dialog accepts a passphrase/recovery key and includes a
  Show/Hide control, so a pasted 48-digit recovery password can be inspected.
- Native and Interactive Terminal elevation policies exist; Native is upstream's
  default. BitLocker Mounter also writes `mode = "native"` before every launch,
  so it does not inherit Interactive Terminal mode.
- mount errors are surfaced in the GUI, and encrypted-volume failures are kept
  in the recovery-key flow for retry.

The private bridge deliberately narrows the upstream GUI to this product's use
case: BitLocker recovery passwords, NTFS3 read/write, Finder-friendly ownership,
and a privately installed anylinuxfs runtime.
