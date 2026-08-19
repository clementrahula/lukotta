#!/bin/bash
# One-time private setup. No Homebrew installation, no macFUSE, no system-wide files.
# Bash 3.2 compatible (the Bash version shipped with macOS).
set -u

RESOURCES="${BLM_RESOURCES:?BLM_RESOURCES is not set}"
USER_HOME="${BLM_USER_HOME:-$HOME}"
SUPPORT="$USER_HOME/Library/Application Support/BitLocker Mounter"
RUNTIME="$SUPPORT/runtime"
CACHE="$SUPPORT/cache"
LOG_DIR="$SUPPORT/logs"
BRIDGE="$SUPPORT/bridge"
NATIVE_DIR="$SUPPORT/native"
GUI_APP="$NATIVE_DIR/BitLocker Mounter.app"
GUI_VERSION="0.7.5"
GUI_DMG="$CACHE/anylinuxfs-gui_${GUI_VERSION}_aarch64.dmg"
GUI_SHA="701118b5d04368a5153fa0f39d4fb78206509f409d6088797802efbab462fa3f"
ALFS_VERSION="0.19.0"
MARKER="$RUNTIME/.ready-bitlocker-mounter-v5"
ENTITLEMENTS="$RESOURCES/anylinuxfs.entitlements"
DMG_MOUNT=""

mkdir -p "$RUNTIME" "$CACHE" "$LOG_DIR" "$BRIDGE" "$NATIVE_DIR"
chmod 700 "$SUPPORT" "$CACHE" "$BRIDGE" 2>/dev/null || true

progress() {
  printf 'PROGRESS|%s|%s\n' "$1" "$2"
}
fail() {
  code="$1"; shift
  printf 'ERROR|%s|%s\n' "$code" "$*" >&2
  exit "$code"
}
cleanup() {
  if [ -n "$DMG_MOUNT" ] && /sbin/mount | /usr/bin/grep -F " on $DMG_MOUNT (" >/dev/null 2>&1; then
    /usr/bin/hdiutil detach "$DMG_MOUNT" -quiet >/dev/null 2>&1 || true
  fi
  [ -z "$DMG_MOUNT" ] || /bin/rmdir "$DMG_MOUNT" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

sha_matches() {
  file="$1"; expected="$2"
  [ -f "$file" ] || return 1
  actual="$(/usr/bin/shasum -a 256 "$file" 2>/dev/null | /usr/bin/awk '{print $1}')"
  [ "$actual" = "$expected" ]
}
verify_sha() {
  file="$1"; expected="$2"; label="$3"
  sha_matches "$file" "$expected" || fail 31 "$label was downloaded but failed SHA-256 verification. The file was not used."
}
download_file() {
  url="$1"; out="$2"; label="$3"
  err="$CACHE/curl-error.txt"
  /bin/rm -f "$out.part" "$err"
  /usr/bin/curl --fail --location --retry 3 --retry-delay 1 --connect-timeout 20 \
    --show-error --silent --output "$out.part" "$url" 2>"$err"
  code=$?
  if [ "$code" -ne 0 ]; then
    reason="$(/usr/bin/tail -n 5 "$err" 2>/dev/null | /usr/bin/tr '\n' ' ')"
    /bin/rm -f "$out.part"
    fail 20 "Could not download $label (curl exit $code). $reason"
  fi
  /bin/mv -f "$out.part" "$out"
}
ghcr_download() {
  repo="$1"; digest="$2"; out="$3"; label="$4"
  token_err="$CACHE/ghcr-token-error.txt"
  blob_err="$CACHE/ghcr-blob-error.txt"
  /bin/rm -f "$out.part" "$token_err" "$blob_err"

  token_json="$(/usr/bin/curl --fail --location --retry 3 --connect-timeout 20 --show-error --silent \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull" 2>"$token_err")"
  code=$?
  if [ "$code" -ne 0 ]; then
    reason="$(/usr/bin/tail -n 4 "$token_err" 2>/dev/null | /usr/bin/tr '\n' ' ')"
    fail 21 "Could not obtain a registry token for $label (curl exit $code). $reason"
  fi
  token="$(printf '%s' "$token_json" | /usr/bin/plutil -extract token raw -o - - 2>/dev/null || true)"
  [ -n "$token" ] || fail 22 "The package registry returned no download token for $label."

  /usr/bin/curl --fail --location --retry 3 --retry-delay 1 --connect-timeout 20 \
    --show-error --silent -H "Authorization: Bearer $token" \
    --output "$out.part" "https://ghcr.io/v2/${repo}/blobs/sha256:${digest}" 2>"$blob_err"
  code=$?
  if [ "$code" -ne 0 ]; then
    reason="$(/usr/bin/tail -n 4 "$blob_err" 2>/dev/null | /usr/bin/tr '\n' ' ')"
    /bin/rm -f "$out.part"
    fail 23 "Could not download $label from GHCR (curl exit $code). $reason"
  fi
  /bin/mv -f "$out.part" "$out"
}

install_native_gui() {
  progress 6 "Downloading the native macOS interface (anylinuxfs GUI $GUI_VERSION)"
  if [ -f "$GUI_DMG" ] && ! sha_matches "$GUI_DMG" "$GUI_SHA"; then
    progress 7 "Cached GUI failed checksum; downloading a clean official copy"
    /bin/rm -f "$GUI_DMG"
  fi
  if [ ! -f "$GUI_DMG" ]; then
    download_file \
      "https://github.com/fenio/anylinuxfs-gui/releases/download/v${GUI_VERSION}/anylinuxfs-gui_${GUI_VERSION}_aarch64.dmg" \
      "$GUI_DMG" "native macOS interface $GUI_VERSION"
  fi
  verify_sha "$GUI_DMG" "$GUI_SHA" "native macOS interface $GUI_VERSION"

  progress 12 "Installing the native interface privately"
  DMG_MOUNT="$(/usr/bin/mktemp -d "$CACHE/gui-mount.XXXXXX")" || fail 24 "Could not create the private GUI mount directory."
  /usr/bin/hdiutil attach "$GUI_DMG" -nobrowse -readonly -mountpoint "$DMG_MOUNT" -quiet
  code=$?
  [ "$code" -eq 0 ] || fail 25 "macOS could not open the verified GUI disk image (hdiutil exit $code)."

  source_app="$(/usr/bin/find "$DMG_MOUNT" -maxdepth 2 -type d -name '*.app' -print -quit)"
  [ -n "$source_app" ] || fail 26 "The verified GUI disk image did not contain a macOS application."
  /bin/rm -rf "$GUI_APP"
  /usr/bin/ditto "$source_app" "$GUI_APP"
  code=$?
  [ "$code" -eq 0 ] || fail 27 "Could not copy the native GUI into Application Support (ditto exit $code)."

  /usr/bin/hdiutil detach "$DMG_MOUNT" -quiet >/dev/null 2>&1 || fail 28 "Could not detach the temporary GUI disk image."
  /bin/rmdir "$DMG_MOUNT" >/dev/null 2>&1 || true
  DMG_MOUNT=""

  # Brand the private copy, then ad-hoc sign the modified app. Failure to change
  # display metadata is cosmetic; signature verification is not.
  /usr/bin/plutil -replace CFBundleDisplayName -string "BitLocker Mounter" "$GUI_APP/Contents/Info.plist" >/dev/null 2>&1 || \
    /usr/bin/plutil -insert CFBundleDisplayName -string "BitLocker Mounter" "$GUI_APP/Contents/Info.plist" >/dev/null 2>&1 || true
  /usr/bin/plutil -replace CFBundleName -string "BitLocker Mounter" "$GUI_APP/Contents/Info.plist" >/dev/null 2>&1 || true
  if [ -f "$GUI_APP/Contents/Resources/icon.icns" ] && [ -f "$RESOURCES/AppIcon.icns" ]; then
    /bin/cp -f "$RESOURCES/AppIcon.icns" "$GUI_APP/Contents/Resources/icon.icns" || true
  fi
  /usr/bin/xattr -cr "$GUI_APP" >/dev/null 2>&1 || true
  /usr/bin/codesign --force --deep --sign - "$GUI_APP" >/dev/null 2>&1 || fail 29 "macOS could not ad-hoc sign the private native GUI."
  /usr/bin/codesign --verify --deep --strict "$GUI_APP" >/dev/null 2>&1 || fail 30 "The native GUI failed code-signature verification after private installation."

  gui_bin="$(/usr/bin/find "$GUI_APP/Contents/MacOS" -type f -perm -111 -print -quit 2>/dev/null)"
  [ -n "$gui_bin" ] || fail 32 "The installed native GUI has no executable."
}

extract_anylinuxfs() {
  archive="$1"
  staging="$(/usr/bin/mktemp -d "$CACHE/anylinuxfs.XXXXXX")" || fail 33 "Could not create an extraction directory for anylinuxfs."
  /usr/bin/tar -xzf "$archive" -C "$staging"
  code=$?
  if [ "$code" -ne 0 ]; then
    /bin/rm -rf "$staging"
    fail 34 "The verified anylinuxfs archive could not be extracted (tar exit $code)."
  fi
  found="$(/usr/bin/find "$staging" -type f -path '*/bin/anylinuxfs' -print -quit)"
  if [ -z "$found" ]; then
    /bin/rm -rf "$staging"
    fail 35 "The verified anylinuxfs archive did not contain bin/anylinuxfs."
  fi
  prefix="${found%/bin/anylinuxfs}"
  /bin/rm -rf "$RUNTIME/anylinuxfs"
  /bin/mkdir -p "$RUNTIME/anylinuxfs"
  /bin/cp -R "$prefix"/. "$RUNTIME/anylinuxfs"/
  code=$?
  /bin/rm -rf "$staging"
  [ "$code" -eq 0 ] || fail 36 "Could not copy the anylinuxfs runtime into Application Support."
}

install_bottle() {
  name="$1"; digest="$2"; pct="$3"
  destination="$RUNTIME/deps/$name"
  archive="$CACHE/${name}-${BOTTLE_TAG}-${digest}.tar.gz"
  progress "$pct" "Downloading private runtime dependency: $name"
  if [ -f "$archive" ] && ! sha_matches "$archive" "$digest"; then
    progress "$pct" "Cached $name failed checksum; downloading a clean copy"
    /bin/rm -f "$archive"
  fi
  [ -f "$archive" ] || ghcr_download "homebrew/core/$name" "$digest" "$archive" "$name"
  verify_sha "$archive" "$digest" "$name"

  staging="$(/usr/bin/mktemp -d "$CACHE/${name}.XXXXXX")" || fail 40 "Could not create an extraction directory for $name."
  /usr/bin/tar -xzf "$archive" -C "$staging"
  code=$?
  if [ "$code" -ne 0 ]; then
    /bin/rm -rf "$staging"
    fail 41 "The verified $name archive could not be extracted (tar exit $code)."
  fi

  top="$(/usr/bin/find "$staging" -type d -print | /usr/bin/awk -v base="$staging/" '
    index($0, base) == 1 {
      rest = substr($0, length(base) + 1)
      n = split(rest, part, "/")
      if (n == 2 && part[2] != ".brew") { print $0; exit }
    }')"
  if [ -z "$top" ]; then
    /bin/rm -rf "$staging"
    fail 42 "The $name bottle had an unexpected directory layout."
  fi
  /bin/rm -rf "$destination"
  /bin/mkdir -p "$destination"
  /bin/cp -R "$top"/. "$destination"/
  code=$?
  /bin/rm -rf "$staging"
  [ "$code" -eq 0 ] || fail 43 "Could not install the private $name runtime."
}

find_private_dylib() {
  /usr/bin/find "$RUNTIME/deps" \( -type f -o -type l \) -name "$1" -print 2>/dev/null | /usr/bin/head -n 1
}
relocate_one() {
  f="$1"
  /usr/bin/file "$f" 2>/dev/null | /usr/bin/grep -q 'Mach-O' || return 0
  result="$CACHE/relocate-one.txt"
  : > "$result"

  /usr/bin/otool -L "$f" 2>/dev/null | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}' | \
  while IFS= read -r dep; do
    case "$dep" in
      /opt/homebrew/*|/usr/local/*|*HOMEBREW_PREFIX*|*HOMEBREW_CELLAR*)
        base="${dep##*/}"
        target="$(find_private_dylib "$base")"
        if [ -z "$target" ]; then
          printf 'UNRESOLVED|%s\n' "$dep"
        else
          /usr/bin/install_name_tool -change "$dep" "$target" "$f" || exit 91
          printf 'CHANGED\n'
        fi
        ;;
    esac
  done > "$result"
  code=$?
  [ "$code" -eq 0 ] || fail 50 "install_name_tool failed while relocating $(/usr/bin/basename "$f")."

  unresolved="$(/usr/bin/grep '^UNRESOLVED|' "$result" | /usr/bin/head -n 1 || true)"
  [ -z "$unresolved" ] || fail 51 "A private runtime dependency could not be resolved for $(/usr/bin/basename "$f"): ${unresolved#UNRESOLVED|}"

  case "$f" in
    *.dylib)
      ident="$(/usr/bin/otool -D "$f" 2>/dev/null | /usr/bin/tail -n +2 | /usr/bin/head -n 1 || true)"
      case "$ident" in
        /opt/homebrew/*|/usr/local/*|*HOMEBREW_PREFIX*|*HOMEBREW_CELLAR*)
          /usr/bin/install_name_tool -id "$f" "$f" || fail 52 "Could not relocate install ID for $(/usr/bin/basename "$f")."
          printf 'CHANGED\n' >> "$result"
          ;;
      esac
      ;;
  esac

  if /usr/bin/grep -q '^CHANGED$' "$result" 2>/dev/null; then
    /usr/bin/codesign --force --sign - "$f" >/dev/null 2>&1 || fail 53 "Could not ad-hoc sign relocated file $(/usr/bin/basename "$f")."
  fi
}
verify_no_homebrew_links() {
  f="$1"
  /usr/bin/file "$f" 2>/dev/null | /usr/bin/grep -q 'Mach-O' || return 0
  bad="$(/usr/bin/otool -L "$f" 2>/dev/null | /usr/bin/awk '{print $1}' | /usr/bin/grep -E '^(/opt/homebrew|/usr/local)|HOMEBREW_(PREFIX|CELLAR)' | /usr/bin/head -n 1 || true)"
  [ -z "$bad" ] || fail 54 "$(/usr/bin/basename "$f") still references an external package-manager path: $bad"
}

progress 1 "Checking this Mac"
[ "$(/usr/bin/uname -m)" = "arm64" ] || fail 10 "BitLocker Mounter requires an Apple Silicon Mac."
OS_VERSION="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
OS_MAJOR="${OS_VERSION%%.*}"
case "$OS_MAJOR" in ''|*[!0-9]*) fail 11 "Could not determine the macOS version." ;; esac

if [ "$OS_MAJOR" -ge 26 ]; then
  BOTTLE_TAG="arm64_tahoe"
  ALFS_ASSET="anylinuxfs-${ALFS_VERSION}.arm64_tahoe.bottle.tar.gz"
  ALFS_SHA="2a0cb477920586660feda67197ebeeb05fa42621f0fb284bf4b15d1d071a0274"
  UTIL_SHA="3b2174542f34178348f62bccf804a06d8a1adb3dbd6767ce6b01fd618d63f9db"
  GETTEXT_SHA="2b713227e438f51d025d76df24cfa45a2b813b61718df7bb91a6cedb1091037b"
  JSONC_SHA="4095feba36f7d453ae23ddb2656038e0784e857e1c860e70fe26a7c5089c36f5"
  UNISTRING_SHA="bae6d6d8dffc573c039a850a96e36f1b7fd846abd9ccada8260b7e888b5a3646"
elif [ "$OS_MAJOR" -ge 15 ]; then
  BOTTLE_TAG="arm64_sequoia"
  ALFS_ASSET="anylinuxfs-${ALFS_VERSION}.arm64_sequoia.bottle.tar.gz"
  ALFS_SHA="723586666ffae512c543546356678f30de45d341595b9028f4058969dfb32dac"
  UTIL_SHA="190141242ffdeb5cf236a3b040342097019fce761e655a4c5a12eae18591d628"
  GETTEXT_SHA="dde3cd0db0d7549fadf762b901f8c548dae99e3c592a6e6d41f60e1436253e5e"
  JSONC_SHA="760e09935d633a49e8a25121969022ef158eed40b739bd142063aadbfed41730"
  UNISTRING_SHA="463b68c92d30d845df10b1b137aa8e41a744f1ce2d2cab024dd26c766335b797"
else
  fail 12 "BitLocker Mounter requires macOS 15 Sequoia or later."
fi

# Refresh bridge scripts before any readiness check. The native GUI points at
# this private proxy rather than /opt/homebrew/bin/anylinuxfs.
/bin/cp -f "$RESOURCES/helpers/alfs-proxy.sh" "$BRIDGE/anylinuxfs" || fail 13 "Could not install the private anylinuxfs bridge."
/bin/cp -f "$RESOURCES/helpers/validate-key.sh" "$BRIDGE/validate-key.sh" || fail 13 "Could not install the recovery-key validator."
/bin/chmod 755 "$BRIDGE/anylinuxfs" "$BRIDGE/validate-key.sh" || fail 13 "Could not set bridge executable permissions."

if [ -x "$RESOURCES/helpers/runtime-ready.sh" ]; then
  BLM_RESOURCES="$RESOURCES" BLM_USER_HOME="$USER_HOME" "$RESOURCES/helpers/runtime-ready.sh" >/dev/null 2>&1 && {
    progress 100 "All private components are already verified"
    exit 0
  }
fi

# v5 is a clean runtime rebuild. Verified downloads remain cached and reusable.
/bin/rm -f "$MARKER"
/bin/rm -rf "$RUNTIME/anylinuxfs" "$RUNTIME/deps"

install_native_gui

progress 18 "Downloading anylinuxfs $ALFS_VERSION"
ALFS_ARCHIVE="$CACHE/$ALFS_ASSET"
if [ -f "$ALFS_ARCHIVE" ] && ! sha_matches "$ALFS_ARCHIVE" "$ALFS_SHA"; then
  progress 19 "Cached anylinuxfs failed checksum; downloading a clean copy"
  /bin/rm -f "$ALFS_ARCHIVE"
fi
if [ ! -f "$ALFS_ARCHIVE" ]; then
  download_file "https://github.com/nohajc/homebrew-anylinuxfs/releases/download/v${ALFS_VERSION}/${ALFS_ASSET}" "$ALFS_ARCHIVE" "anylinuxfs $ALFS_VERSION"
fi
verify_sha "$ALFS_ARCHIVE" "$ALFS_SHA" "anylinuxfs $ALFS_VERSION"

progress 27 "Extracting the BitLocker mounting engine"
extract_anylinuxfs "$ALFS_ARCHIVE"
[ -x "$RUNTIME/anylinuxfs/bin/anylinuxfs" ] || fail 37 "The extracted anylinuxfs executable is missing."

# vmnet-helper is rootless on Tahoe (26+) but requires elevation on Sequoia.
# First-run initialization deliberately happens before any admin/disk prompt, so
# use upstream's gvproxy network helper in our *private* config on macOS 15.
if [ "$OS_MAJOR" -lt 26 ]; then
  progress 30 "Configuring rootless VM networking for macOS Sequoia"
  PRIVATE_CFG="$RUNTIME/anylinuxfs/etc/anylinuxfs.toml"
  [ -f "$PRIVATE_CFG" ] || fail 38 "The private anylinuxfs configuration file is missing."
  CFG_TMP="$CACHE/anylinuxfs-config.tmp"
  /usr/bin/sed 's/^helper = "vmnet"$/helper = "gvproxy"/' "$PRIVATE_CFG" > "$CFG_TMP" || fail 39 "Could not prepare the Sequoia network configuration."
  /bin/mv -f "$CFG_TMP" "$PRIVATE_CFG"
  /usr/bin/grep -q '^helper = "gvproxy"$' "$PRIVATE_CFG" || fail 39 "Sequoia rootless network configuration was not applied."
fi

/bin/mkdir -p "$RUNTIME/deps"
install_bottle "util-linux" "$UTIL_SHA" 35
install_bottle "gettext" "$GETTEXT_SHA" 44
install_bottle "json-c" "$JSONC_SHA" 52
install_bottle "libunistring" "$UNISTRING_SHA" 59

progress 66 "Relocating private runtime libraries"
/usr/bin/find "$RUNTIME/deps" "$RUNTIME/anylinuxfs/bin" "$RUNTIME/anylinuxfs/libexec" -type f -print 2>/dev/null | \
while IFS= read -r f; do relocate_one "$f"; done
code=$?
[ "$code" -eq 0 ] || fail 55 "Private runtime relocation stopped unexpectedly (exit $code)."

progress 73 "Signing and verifying the private hypervisor runtime"
for f in "$RUNTIME/anylinuxfs/bin/anylinuxfs" "$RUNTIME/anylinuxfs/libexec/init-rootfs"; do
  [ -x "$f" ] || fail 56 "Required runtime executable is missing: $f"
  /usr/bin/codesign --force --sign - --entitlements "$ENTITLEMENTS" "$f" >/dev/null 2>&1 || \
    fail 57 "macOS could not sign $(/usr/bin/basename "$f") with the required hypervisor entitlement."
done

progress 77 "Checking for accidental Homebrew dependencies"
/usr/bin/find "$RUNTIME/deps" "$RUNTIME/anylinuxfs/bin" "$RUNTIME/anylinuxfs/libexec" -type f -print 2>/dev/null | \
while IFS= read -r f; do verify_no_homebrew_links "$f"; done
code=$?
[ "$code" -eq 0 ] || fail 58 "Private runtime linkage verification stopped unexpectedly (exit $code)."

progress 80 "Starting the private mounting engine"
BLM_USER_HOME="$USER_HOME" "$BRIDGE/anylinuxfs" --version
code=$?
[ "$code" -eq 0 ] || fail 59 "The private anylinuxfs executable could not start (exit $code)."

progress 83 "Downloading Linux guest components and BitLocker/NTFS tools"
INIT_LOG="$LOG_DIR/anylinuxfs-init.log"
: > "$INIT_LOG"
BLM_USER_HOME="$USER_HOME" "$BRIDGE/anylinuxfs" init >"$INIT_LOG" 2>&1 &
init_pid=$!
heartbeat=0
while /bin/kill -0 "$init_pid" >/dev/null 2>&1; do
  last="$(/usr/bin/tail -n 1 "$INIT_LOG" 2>/dev/null | /usr/bin/tr '\n' ' ' | /usr/bin/cut -c 1-140)"
  if [ -n "$last" ]; then
    progress 88 "Initializing Linux environment: $last"
  else
    progress 88 "Initializing the private Linux environment"
  fi
  /bin/sleep 3
  heartbeat=$((heartbeat + 1))
  [ "$heartbeat" -lt 400 ] || {
    /bin/kill "$init_pid" >/dev/null 2>&1 || true
    fail 60 "Linux environment initialization exceeded 20 minutes. See $INIT_LOG"
  }
done
wait "$init_pid"
code=$?
if [ "$code" -ne 0 ]; then
  reason="$(/usr/bin/tail -n 12 "$INIT_LOG" 2>/dev/null | /usr/bin/tr '\n' ' ')"
  fail 61 "anylinuxfs init failed (exit $code). $reason"
fi

ROOTFS="$USER_HOME/.anylinuxfs/alpine/rootfs"
[ -d "$ROOTFS" ] || fail 62 "Initialization completed without creating the Linux root filesystem."

progress 95 "Verifying cryptsetup, NFS and the Finder mount path"
CRYPT="$(/usr/bin/find "$ROOTFS" -type f -name cryptsetup -print -quit 2>/dev/null)"
NFS="$(/usr/bin/find "$ROOTFS" -type f \( -name rpc.nfsd -o -name exportfs \) -print -quit 2>/dev/null)"
MOUNTBIN="$(/usr/bin/find "$ROOTFS" -type f -name mount -print -quit 2>/dev/null)"
[ -n "$CRYPT" ] || fail 63 "The initialized Linux environment is missing cryptsetup; BitLocker cannot be unlocked."
[ -n "$NFS" ] || fail 64 "The initialized Linux environment is missing NFS utilities required by Finder."
[ -n "$MOUNTBIN" ] || fail 65 "The initialized Linux environment is missing its mount utility."

/usr/bin/touch "$MARKER"
BLM_RESOURCES="$RESOURCES" BLM_USER_HOME="$USER_HOME" "$RESOURCES/helpers/runtime-ready.sh" || {
  /bin/rm -f "$MARKER"
  fail 66 "Final end-to-end readiness verification failed."
}

progress 100 "Setup verified — opening the native BitLocker interface"
exit 0
