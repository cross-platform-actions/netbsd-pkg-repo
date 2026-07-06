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
# a default in-core disklabel for an unlabelled MSCP disk.
mount_scratch() {  # $1=disk (e.g. ra1)  $2=mountpoint
    ( cd /dev && sh MAKEDEV "$1" )
    newfs "/dev/r${1}c"
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
# mount existed; copy onto the tree disk so `make package` reuses them.
mkdir -p "$PACKAGES_DIR/All"
if ls "$SEED_DIR"/*.tgz >/dev/null 2>&1; then
    cp "$SEED_DIR"/*.tgz "$PACKAGES_DIR/All/"
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
    # it in the /usr/pkgsrc mount.
    ( cd /usr && tar -xzf "$WRKOBJDIR/pkgsrc.tar.gz" )
    rm -f "$WRKOBJDIR/pkgsrc.tar.gz"
    df -h /usr/pkgsrc || true
fi

# --- Build each package -----------------------------------------------------
# BATCH=yes suppresses interactive prompts. DEPENDS_TARGET=package makes
# dependencies produce binary packages too (not just get installed), so the
# published repo is self-contained and pkg_add can resolve the full closure.
# A failing origin is recorded but does not abort the loop, so the rest still
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
    if make package BATCH=yes DEPENDS_TARGET=package; then
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
