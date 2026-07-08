#!/bin/sh
# Runs INSIDE the NetBSD/vax guest, over ssh, as root.
#
# NetBSD base already ships bmake and the pkg_install tools (pkg_add,
# pkg_info), so unlike non-NetBSD hosts there is no pkgsrc bootstrap step:
# we only need the pkgsrc tree, then `make package` for each origin.
#
# The 1.5 GB RA92 root disk is far too small for the pkgsrc tree (>1 GB
# extracted) plus build work, and the emulated MicroVAX 3900 caps any single
# MSCP disk at 2 GB. The action therefore attaches two 2 GB scratch disks
# (RQ1/RQ2 -> ra1/ra2); we newfs and mount them here: the tree and package
# output on ra1 (/usr/pkgsrc), the build work directory on ra2 (WRKOBJDIR),
# so nothing but the installed packages touches root.
#
# Required environment variables:
#   PKGSRC_BRANCH - quarterly branch/tag to fetch (e.g. pkgsrc-2026Q2)
# Optional:
#   PKGLIST  - path to the package-origin list (default /tmp/pkglist)
#   SEED_DIR - dir of cached .tgz packages to pre-seed (default /tmp/seed)
#
# Exit status: 0 only if every requested origin produced a binary package.
# A fatal setup error (scratch-disk setup, or pkgsrc fetch/extract) aborts
# immediately via `set -e`; a per-package build failure is recorded and
# reported at the end with a non-zero exit, so the caller never publishes an
# incomplete repository.

set -eux

# Non-interactive ssh shells get a minimal PATH without /sbin and /usr/sbin,
# where newfs, mount, disklabel and pkg_info/pkg_add live. Put them on PATH
# up front so every command below resolves.
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/pkg/sbin:/usr/pkg/bin
export PATH

PKGSRC_BRANCH="${PKGSRC_BRANCH:?PKGSRC_BRANCH must be set}"
PKGLIST="${PKGLIST:-/tmp/pkglist}"
SEED_DIR="${SEED_DIR:-/tmp/seed}"
PACKAGES_DIR=/usr/pkgsrc/packages
WRKOBJDIR=/wrk

# --- Mount the scratch disks ------------------------------------------------
# Fresh blank disks each run, so create the device nodes, newfs and mount.
# 'c' is the whole-disk partition on NetBSD/vax, which the kernel exposes via
# a default in-core disklabel for an unlabelled MSCP disk. That default label
# types the partition 'unused', so newfs needs -I to skip its "not 4.2BSD"
# check rather than us having to write a disklabel first.
#
# The pkgsrc tree is only ~633 MB of content but ~290k mostly-tiny files.
# newfs's defaults on a 2 GB disk give far too few inodes (~130k) and round
# every tiny file up to a 32 KB block, so the tree overflowed 2 GB partway
# through extraction. Force small blocks/fragments (8 KB/1 KB) and a high
# inode count (-i 4096 → ~520k inodes) so the whole tree fits with room to
# spare for the build.
mount_scratch() {  # $1=disk (e.g. ra1)  $2=mountpoint
    ( cd /dev && sh MAKEDEV "$1" )
    newfs -I -b 8192 -f 1024 -i 4096 "/dev/r${1}c"
    mkdir -p "$2"
    mount "/dev/${1}c" "$2"
}
mount_scratch ra1 /usr/pkgsrc
mount_scratch ra2 "$WRKOBJDIR"

# Send pkgsrc build work to the ra2 scratch disk instead of in-tree, so the
# tree disk only holds the tree and the package output.
echo "WRKOBJDIR=${WRKOBJDIR}" >> /etc/mk.conf

df -h / /usr/pkgsrc "$WRKOBJDIR" || true

# --- Seed from cache (packages built in previous, timed-out runs) -----------
# Staged on root at $SEED_DIR by build-packages.sh before the /usr/pkgsrc
# mount existed; copy onto the tree disk, then install them so `make package`
# treats those deps as satisfied and skips rebuilding. Without installing
# them, every run rebuilds the whole closure from scratch and can't converge
# within the job time limit. PKG_PATH lets pkg_add resolve inter-package
# deps; errors (already-installed, version skew after a branch bump) are
# non-fatal.
mkdir -p "$PACKAGES_DIR/All"
if ls "$SEED_DIR"/*.tgz >/dev/null 2>&1; then
    cp "$SEED_DIR"/*.tgz "$PACKAGES_DIR/All/"
fi
if ls "$PACKAGES_DIR"/All/*.tgz >/dev/null 2>&1; then
    PKG_PATH="$PACKAGES_DIR/All" pkg_add "$PACKAGES_DIR"/All/*.tgz || true
fi

# --- Fetch the pkgsrc tree (pinned) onto ra1 --------------------------------
# Use base ftp(1) (tnftp), which speaks HTTPS — no curl/git needed, which is
# the whole reason this repo exists. Download to the ra2 work disk so the
# 96 MB tarball doesn't compete with the tree on ra1; extract into the
# /usr/pkgsrc mount. Under `set -e` a 404 or a truncated download aborts.
if [ ! -f /usr/pkgsrc/mk/bsd.pkg.mk ]; then
    ftp -o "$WRKOBJDIR/pkgsrc.tar.gz" \
        "https://cdn.netbsd.org/pub/pkgsrc/${PKGSRC_BRANCH}/pkgsrc.tar.gz"
    # The tarball's top-level dir is pkgsrc/, so extracting from /usr lands
    # it in the /usr/pkgsrc mount. --exclude-vcs skips the CVS metadata dirs
    # (~a third of the tarball's ~290k files), which pkgsrc doesn't need to
    # build — roughly halving the slow per-file extraction on emulated vax.
    ( cd /usr && tar -xzf "$WRKOBJDIR/pkgsrc.tar.gz" --exclude-vcs )
    rm -f "$WRKOBJDIR/pkgsrc.tar.gz"
    df -h /usr/pkgsrc || true
fi

# net/rsync buildlinks pkgsrc security/openssl unconditionally, and openssl
# needs perl to build — perl doesn't finish within the job time limit on the
# emulated VAX. rsync doesn't need openssl (it has built-in checksums and is
# used over ssh here), so strip the openssl buildlink from its Makefile; its
# configure then builds rsync without pulling in pkgsrc openssl/perl.
rsync_mk=/usr/pkgsrc/net/rsync/Makefile
if [ -f "$rsync_mk" ]; then
    grep -v 'security/openssl/buildlink3.mk' "$rsync_mk" > "$rsync_mk.tmp"
    mv "$rsync_mk.tmp" "$rsync_mk"
fi

# --- Build each package -----------------------------------------------------
# BATCH=yes suppresses interactive prompts. DEPENDS_TARGET=package-install
# makes each dependency both produce a binary package (so the published repo
# is self-contained and pkg_add can resolve the full closure) AND get
# installed (so dependents find it — plain `package` only packages, leaving
# the dependency uninstalled and the build failing its depends check). A
# failing origin is recorded but does not abort the loop, so the rest still
# build and partial progress is cached — but `failed` makes the whole run
# exit non-zero so an incomplete set is never treated as success.
failed=0
while IFS= read -r origin || [ -n "$origin" ]; do
    case "$origin" in ''|\#*) continue ;; esac
    if [ ! -d "/usr/pkgsrc/$origin" ]; then
        echo "MISSING ORIGIN: $origin" >&2
        failed=1
        continue
    fi
    cd "/usr/pkgsrc/$origin"
    if make package BATCH=yes DEPENDS_TARGET=package-install; then
        :
    else
        echo "BUILD FAILED: $origin (exit $?)" >&2
        failed=1
    fi
    # Free every work tree (including dependencies') after each origin so a
    # 2 GB work disk suffices even for the heavy closure (openssl, perl).
    # The binary packages already live in $PACKAGES_DIR and installed deps
    # stay registered, so a later origin reuses them without rebuilding.
    make clean CLEANDEPENDS=yes >/dev/null 2>&1 || true
done < "$PKGLIST"

# --- Generate the binary-package summary index ------------------------------
# pkg_add (via PKG_PATH) and pkgin both read pkg_summary.gz from the package
# directory. Guard on packages actually existing so a run that built nothing
# fails cleanly here instead of erroring on an empty glob.
if ls "$PACKAGES_DIR"/All/*.tgz >/dev/null 2>&1; then
    cd "$PACKAGES_DIR/All"
    # shellcheck disable=SC2035
    pkg_info -X *.tgz | gzip -9 > pkg_summary.gz
    echo "=== Built packages ==="
    ls -l "$PACKAGES_DIR/All"
else
    echo "No packages were built" >&2
    failed=1
fi

[ "$failed" -eq 0 ] || {
    echo "One or more requested packages did not build" >&2
    exit 1
}
