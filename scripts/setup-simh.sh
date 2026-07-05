#!/bin/sh
# Build SIMH and stage the bootable NetBSD disk image + boot command file.
# Runs on the Linux runner (not inside the guest).
#
# Required environment variables:
#   ARCH          - e.g. vax
#   VERSION       - e.g. 10.1
#   SIMH_BINARY   - SIMH simulator name (e.g. vax)
#   DISK_TYPE     - SIMH RQ0 disk type (e.g. RA92)
#   IMAGE_BASE_URL- release download base the disk image lives under
#
# The image is the one the Cross-Platform Action publishes and consumes:
# cross-platform-actions/netbsd-builder releases, named
# netbsd-<version>-<arch>.img.zst — a raw SIMH RA92 disk, zstd-compressed
# (not qcow2, not VHD).
#
# Outputs, under $REPO_ROOT/.simh/:
#   <simh_binary>   the built simulator binary
#   disk.img        the decompressed bootable system disk
#   simh.ini        the SIMH command file build-packages.sh spawns
#
# We deliberately do NOT drive the build through the action itself: the
# action runs commands as the unprivileged `runner` user with no sudo and
# no file synchronization, whereas building standard /usr/pkg packages
# needs root and getting the .tgz files back out needs a transport. Booting
# SIMH ourselves lets us ssh in as root (password auth is enabled on the
# image) and scp the packages out — scp is in NetBSD base, only rsync is
# missing.

set -eux

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SIMH_DIR="$REPO_ROOT/.simh"

# The MicroVAX 3900 (KA655X) tops out at 512 MB — 8x netbsd-builder's own
# 64 MB build cap, which is what makes the heavy closure (openssl, perl)
# feasible here.
MEMORY="${MEMORY:-512M}"

mkdir -p "$SIMH_DIR"

# --- Build SIMH from source -------------------------------------------------
# Open SIMH builds the VAX simulator with a plain `make <arch>`, producing
# BIN/<arch>. Building from source is more reproducible than the distro
# package (whose binary names and version drift).
if [ ! -x "$SIMH_DIR/$SIMH_BINARY" ]; then
    git clone --depth 1 https://github.com/open-simh/simh "$SIMH_DIR/src"
    make -C "$SIMH_DIR/src" "$SIMH_BINARY"
    cp "$SIMH_DIR/src/BIN/$SIMH_BINARY" "$SIMH_DIR/$SIMH_BINARY"
fi

# --- Fetch and decompress the bootable disk image ---------------------------
# The published asset name is lowercase (netbsd-<version>-<arch>), distinct
# from the capitalized ABI directory (NetBSD-...) we publish under.
img_name="netbsd-${VERSION}-${ARCH}.img.zst"
if [ ! -f "$SIMH_DIR/disk.img" ]; then
    curl -fL "${IMAGE_BASE_URL}/${img_name}" -o "$SIMH_DIR/disk.img.zst"
    # zstd was told to use a 128 MiB window at compression, its default
    # decompression limit, so no --long flag is needed.
    zstd -d -f "$SIMH_DIR/disk.img.zst" -o "$SIMH_DIR/disk.img"
    rm -f "$SIMH_DIR/disk.img.zst"
fi

# --- Write the SIMH command file --------------------------------------------
# Replicates the command file the action generates (src/simh_vm.ts +
# src/operating_systems/netbsd/simh_vm.ts): console detached to a buffered
# telnet port so the simulator boots fully headless, the machine setup, then
# SIMH-native expect/send to drive the KA655 firmware. `boot cpu` runs the
# ROM, which stops at the `>>>` prompt (no NVRAM sets a default boot device);
# the armed `expect ">>>" send "BOOT DUA0\r"; continue` fires and boots the
# system disk (RQ0 = DUA0). The trailing `exit` quits SIMH cleanly after the
# guest halts (`set cpu simhalt` traps the guest HALT back to SCP). The slirp
# NAT redirect exposes the guest's static IP (10.0.2.15:22) on host port 2222
# for ssh. The image is a raw RA92 disk — SIMH's default format — so no
# `set rq0 format` is needed.
disk_type_lc=$(echo "$DISK_TYPE" | tr '[:upper:]' '[:lower:]')
{
    echo "set console telnet=127.0.0.1:2848"
    echo "set console telnet=buffered"
    echo "set console log=$SIMH_DIR/console.log"
    echo "set cpu $MEMORY"
    echo "set cpu simhalt"
    echo "set cpu idle=NETBSD"
    echo "set rq0 $disk_type_lc"
    echo "attach rq0 $SIMH_DIR/disk.img"
    echo "set rq1 disable"
    echo "set rq2 disable"
    echo "set rq3 disable"
    echo "attach xq nat:tcp=2222:10.0.2.15:22"
    echo 'expect ">>>" send "BOOT DUA0\r"; continue'
    echo "boot cpu"
    echo "exit"
} > "$SIMH_DIR/simh.ini"

echo "=== simh.ini ==="
cat "$SIMH_DIR/simh.ini"
