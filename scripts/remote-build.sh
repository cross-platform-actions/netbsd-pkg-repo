#!/bin/sh
# Runs INSIDE the NetBSD/vax guest, over ssh, as root.
#
# NetBSD base already ships bmake and the pkg_install tools (pkg_add,
# pkg_info), so unlike non-NetBSD hosts there is no pkgsrc bootstrap step:
# we only need the pkgsrc tree, then `make package` for each origin.
#
# Required environment variables:
#   PKGSRC_BRANCH - quarterly branch/tag to fetch (e.g. pkgsrc-2026Q2)
# Optional:
#   PKGLIST       - path to the package-origin list (default /tmp/pkglist)
#
# Exit status: 0 only if every requested origin produced a binary package.
# A fatal setup error (pkgsrc fetch/extract failed — e.g. the ~1.5 GB RA92
# disk filling up) aborts immediately via `set -e`; a per-package build
# failure is recorded and reported at the end with a non-zero exit, so the
# caller never publishes an incomplete repository.

set -eux

PKGSRC_BRANCH="${PKGSRC_BRANCH:?PKGSRC_BRANCH must be set}"
PKGLIST="${PKGLIST:-/tmp/pkglist}"
PACKAGES_DIR=/usr/pkgsrc/packages

# Disk is the tight constraint on this image, so report it up front and
# after fetching the tree.
df -h /usr || true

# --- Fetch the pkgsrc tree (pinned) -----------------------------------------
# Use base ftp(1) (tnftp), which speaks HTTPS — no curl/git needed, which
# is the whole reason this repo exists. Under `set -e` a 404 or a tar that
# runs out of disk aborts the script (non-zero), which the caller turns into
# a red job — we must not silently continue with a missing/partial tree.
if [ ! -f /usr/pkgsrc/mk/bsd.pkg.mk ]; then
    cd /usr
    ftp -o pkgsrc.tar.gz \
        "https://cdn.netbsd.org/pub/pkgsrc/${PKGSRC_BRANCH}/pkgsrc.tar.gz"
    tar -xzf pkgsrc.tar.gz
    rm -f pkgsrc.tar.gz
    df -h /usr || true
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
    # The RA92 image is only ~1.5 GB and openssl/perl work dirs are large,
    # so free every work tree (including dependencies') after each origin.
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
