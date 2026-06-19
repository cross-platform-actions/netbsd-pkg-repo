#!/bin/sh
# Build SIMH and stage the bootable NetBSD disk image + boot command file.
# Runs on the Linux runner (not inside the guest).
#
# Required environment variables:
#   ARCH          - e.g. vax
#   VERSION       - e.g. 10.1
#   SIMH_BINARY   - SIMH simulator name (e.g. vax)
#   DISK_TYPE     - SIMH RQ0 disk type (e.g. RA92)
#   IMAGE_BASE_URL- base URL the disk image (and optional NVRAM) live under
#
# Outputs, under $REPO_ROOT/.simh/:
#   <simh_binary>   the built simulator binary
#   disk.img        the (decompressed) bootable system disk
#   nvram.img       the NVRAM image, if one was published
#   boot.ini        the SIMH command file build-packages.sh boots
#
# NOTE: netbsd-builder does not yet publish a vax image (its CI matrix is
# x86-64 and arm64 only; vax lives on a branch). Until it does, point
# IMAGE_BASE_URL at a release that carries NetBSD-<version>-<arch>.img.gz
# (raw VHD, the format SIMH boots), or build the image in a preceding job.

set -eux

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SIMH_DIR="$REPO_ROOT/.simh"

mkdir -p "$SIMH_DIR"

# --- Build SIMH from source -------------------------------------------------
# Open SIMH builds the VAX simulator with a plain `make <arch>`, producing
# BIN/<arch>. Building from a pinned source is more reproducible than the
# distro package (whose binary names and version drift).
if [ ! -x "$SIMH_DIR/$SIMH_BINARY" ]; then
    git clone --depth 1 https://github.com/open-simh/simh "$SIMH_DIR/src"
    make -C "$SIMH_DIR/src" "$SIMH_BINARY"
    cp "$SIMH_DIR/src/BIN/$SIMH_BINARY" "$SIMH_DIR/$SIMH_BINARY"
fi

# --- Fetch the bootable disk image ------------------------------------------
img_name="NetBSD-${VERSION}-${ARCH}.img"
if [ ! -f "$SIMH_DIR/disk.img" ]; then
    curl -fL "${IMAGE_BASE_URL}/${img_name}.gz" -o "$SIMH_DIR/disk.img.gz"
    gunzip -f "$SIMH_DIR/disk.img.gz"
    mv "$SIMH_DIR/${img_name}" "$SIMH_DIR/disk.img" 2>/dev/null || true
fi

# NVRAM is optional: with it, BOOT CPU auto-boots from the default device
# the installer set (DUA0); without it we boot the disk device directly.
nvram_name="NetBSD-${VERSION}-${ARCH}.nvram.img"
have_nvram=false
if [ ! -f "$SIMH_DIR/nvram.img" ]; then
    if curl -fL "${IMAGE_BASE_URL}/${nvram_name}" -o "$SIMH_DIR/nvram.img"; then
        have_nvram=true
    else
        rm -f "$SIMH_DIR/nvram.img"
    fi
elif [ -f "$SIMH_DIR/nvram.img" ]; then
    have_nvram=true
fi

# --- Write the SIMH boot command file ---------------------------------------
# Mirrors netbsd-builder's run-vax.sh: the artifact boots cleanly in a
# fresh SIMH process. The slirp NAT redirect exposes the guest's static
# IP (10.0.2.15:22) on host port 2222 for ssh-driven provisioning.
{
    echo "SET CPU 64M"
    echo "SET CPU IDLE=NETBSD"
    if [ "$have_nvram" = true ]; then
        echo "ATTACH NVR $SIMH_DIR/nvram.img"
    fi
    echo "SET RQ0 $DISK_TYPE"
    echo "SET RQ0 FORMAT=VHD"
    echo "ATTACH RQ0 $SIMH_DIR/disk.img"
    echo "ATTACH XQ nat:tcp=2222:10.0.2.15:22"
    if [ "$have_nvram" = true ]; then
        echo "BOOT CPU"
    else
        echo "BOOT RQ0"
    fi
} > "$SIMH_DIR/boot.ini"

echo "=== boot.ini ==="
cat "$SIMH_DIR/boot.ini"
