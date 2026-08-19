BitLocker Mounter 0.5

Installerless Apple-Silicon macOS launcher for a private anylinuxfs 0.19.0 runtime
and the native anylinuxfs-gui 0.7.5 interface.

First launch prepares all private components before the disk interface is opened.
No Homebrew installation, macFUSE, kernel extension, or system-wide package is used.

Private files are stored under:
~/Library/Application Support/BitLocker Mounter/

The BitLocker numerical recovery password is validated and normalized by the
private anylinuxfs bridge before any mount attempt. Dashes/spaces are accepted;
invalid 48-digit recovery-password blocks are rejected before reaching cryptsetup.

BitLocker mounts are forced to Linux NTFS3 with --ignore-permissions and remain
read/write unless the native UI explicitly requests the 'ro' mount option.

Native administrator authentication is forced on every launch; Interactive Terminal/compatibility modes are not used.
