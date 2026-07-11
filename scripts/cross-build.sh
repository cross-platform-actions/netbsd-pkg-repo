#!/bin/sh
# Cross-build NetBSD/vax pkgsrc binary packages on a NetBSD/amd64 host.
#
# Runs INSIDE the NetBSD/amd64 guest booted by cross-platform-actions/action,
# as the unprivileged `runner` user (which has passwordless sudo). This
# replaces the old emulated-vax build: instead of running `make package`
# inside a slow SIMH MicroVAX 3900 (where perl alone exceeds GitHub's 6-hour
# job limit), we build the vax packages by cross-compiling on the fast amd64
# host. pkgsrc's USE_CROSS_COMPILE builds the whole build-tool closure
# (perl/texinfo/bison) NATIVELY as tool-dependencies and never cross-builds a
# target perl, which is what makes this finish in minutes rather than hours.
#
# The vax cross toolchain + sysroot is produced once by NetBSD's build.sh and
# cached (see the workflow); a later run restores it and skips the ~90-minute
# rebuild.
#
# Required environment variables:
#   PKGSRC_BRANCH - pkgsrc quarterly branch/tag (e.g. pkgsrc-2026Q2)
#   SRC_BRANCH    - NetBSD src branch for the cross toolchain (e.g. netbsd-10)
#   TARGET_ARCH   - target MACHINE_ARCH to cross-build for (e.g. vax)
#   TARGET_VERSION- target NetBSD version (e.g. 10.1)
#   WORKSPACE     - shared workspace dir (== GITHUB_WORKSPACE). Synced both
#                   ways, so it is the only channel to/from the host runner.
#                   Built .tgz are copied here for upload, and the toolchain
#                   is transported as a single tarball here for actions/cache.
#
# Toolchain caching: the objdir (TOOLDIR + CROSS_DESTDIR) is ~multi-GB and
# ~100k files; rsyncing that many files each step is slow. So the objdir lives
# on the guest's fast local disk ($HOME/obj.<arch>), and we move it across the
# workspace boundary as ONE tarball ($WORKSPACE/toolchain-cache/obj.tar). The
# host runner caches that tarball with actions/cache keyed on SRC_BRANCH. On a
# cache hit the tarball is already in the workspace when the VM boots; we
# extract it and skip build.sh. On a miss we build and write a fresh tarball.
#
# Exit status: 0 only if every requested origin produced a binary package.

set -eux

# Non-interactive shells get a minimal PATH; add the sbin dirs (and pkg dirs)
# so build.sh's tools, pkg_info/pkg_add and sudo all resolve.
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/pkg/sbin:/usr/pkg/bin
export PATH

PKGSRC_BRANCH="${PKGSRC_BRANCH:?PKGSRC_BRANCH must be set}"
SRC_BRANCH="${SRC_BRANCH:?SRC_BRANCH must be set}"
TARGET_ARCH="${TARGET_ARCH:?TARGET_ARCH must be set}"
TARGET_VERSION="${TARGET_VERSION:?TARGET_VERSION must be set}"
WORKSPACE="${WORKSPACE:?WORKSPACE must be set}"

OBJDIR="$HOME/obj.$TARGET_ARCH"
TOOLCHAIN_CACHE_DIR="$WORKSPACE/toolchain-cache"
TOOLCHAIN_TARBALL="$TOOLCHAIN_CACHE_DIR/obj.tar"
PKGSRCDIR="$HOME/pkgsrc"
SRCDIR="$HOME/src"
PKGSRC_MAKECONF="$PKGSRCDIR/mk.conf"
PACKAGES_DIR="$PKGSRCDIR/packages"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# CROSS_OPSYS_VERSION is the packed integer form of the version, e.g. 10.1 ->
# 101000 (MMmm00). Derive it so bumping config/versions needs no code change.
opsys_version_int() {  # $1 = version like "10.1"
    _maj="${1%%.*}"
    _min="${1#*.}"
    case "$_min" in "$1") _min=0 ;; esac
    printf '%d%02d00\n' "$_maj" "$_min"
}
CROSS_OPSYS_VERSION="$(opsys_version_int "$TARGET_VERSION")"

# --- 0. Verify passwordless sudo works non-interactively --------------------
# pkgsrc's package-install step escalates to root via SU_CMD. The guest
# `runner` user has passwordless sudo (usable non-interactively, unlike su
# which fails with "Conversation failure" with no TTY). Fail loud otherwise.
echo "===== VERIFYING PASSWORDLESS SUDO ====="
id
sudo -n true
echo "passwordless sudo OK"

# --- 1. Cross toolchain + sysroot (build.sh) --------------------------------
# CRITICAL (see LESSONS): NetBSD base make reads /etc/mk.conf by default, and
# our pkgsrc mk.conf must NOT leak into build.sh (it breaks distribution /
# postinstall). So build.sh runs with a clean default MAKECONF, and we only
# write the pkgsrc cross settings AFTER build.sh finishes. Guard against a
# stale /etc/mk.conf from a previous step.
sudo rm -f /etc/mk.conf

CROSS_DESTDIR="$OBJDIR/destdir.$TARGET_ARCH"

# A cache hit means the host runner restored the tarball into the workspace;
# extract it to the local objdir. Otherwise build the toolchain (tools ~12 min,
# distribution ~75 min) unprivileged (-U) with obj out of tree (-O), then write
# a fresh tarball into the workspace for the host runner to cache.
rm -rf "$OBJDIR"
mkdir -p "$OBJDIR"
if [ -f "$TOOLCHAIN_TARBALL" ]; then
    echo "===== TOOLCHAIN CACHE HIT: extracting $TOOLCHAIN_TARBALL ====="
    ( cd "$OBJDIR" && tar -xpf "$TOOLCHAIN_TARBALL" )
else
    echo "===== TOOLCHAIN CACHE MISS: building cross toolchain ====="
    if [ ! -f "$SRCDIR/build.sh" ]; then
        cd "$HOME"
        ftp -o src.tar.gz \
            "https://codeload.github.com/NetBSD/src/tar.gz/refs/heads/${SRC_BRANCH}"
        tar -xzf src.tar.gz
        mv "src-${SRC_BRANCH}" "$SRCDIR"
        rm -f src.tar.gz
    fi
    cd "$SRCDIR"
    ./build.sh -U -m "$TARGET_ARCH" -O "$OBJDIR" tools
    ./build.sh -U -m "$TARGET_ARCH" -O "$OBJDIR" distribution
    echo "===== Writing toolchain tarball for caching ====="
    mkdir -p "$TOOLCHAIN_CACHE_DIR"
    # Tar the whole objdir (TOOLDIR + destdir) from within it so paths are
    # relative and it extracts cleanly on the next run.
    ( cd "$OBJDIR" && tar -cpf "$TOOLCHAIN_TARBALL" . )
fi

# Resolve the real (glob-expanded) toolchain path and assert it exists, so a
# bad path fails now, not deep in a package build.
TOOLDIR="$(echo "$OBJDIR"/tooldir.NetBSD-*)"
[ -d "$TOOLDIR" ] || { echo "FATAL: TOOLDIR not found: $TOOLDIR"; exit 1; }
[ -d "$CROSS_DESTDIR" ] || { echo "FATAL: CROSS_DESTDIR not found: $CROSS_DESTDIR"; exit 1; }
echo "TOOLDIR=$TOOLDIR"
echo "CROSS_DESTDIR=$CROSS_DESTDIR"

# --- 2. Fetch pinned pkgsrc -------------------------------------------------
# base ftp(1) (tnftp) speaks HTTPS, so no curl/git needed. --exclude-vcs drops
# the CVS metadata pkgsrc does not need to build.
if [ ! -f "$PKGSRCDIR/mk/bsd.pkg.mk" ]; then
    cd "$HOME"
    ftp -o pkgsrc.tar.gz \
        "https://cdn.netbsd.org/pub/pkgsrc/${PKGSRC_BRANCH}/pkgsrc.tar.gz"
    tar -xzf pkgsrc.tar.gz --exclude-vcs
    rm -f pkgsrc.tar.gz
fi

# --- 3. Derive the native platform values for the CROSS_ vars ---------------
# pkgsrc's bsd.prefs.mk requires a CROSS_ counterpart for every entry in
# CROSSVARS; several (LOWER_VENDOR, LOWER_OPSYS_VERSUFFIX,
# LOWER_VARIANT_VERSION, OS_VARIANT) are empty on NetBSD but must still be
# DEFINED or pkgsrc aborts with "USE_CROSS_COMPILE=yes but missing cross
# variable settings" (this is exactly what sank the spike). Rather than
# hardcode, ask this NetBSD host for its own values with a clean MAKECONF, so
# they always match the pkgsrc version in use. The target only differs from
# the host in MACHINE_ARCH/OBJECT_FMT/versions, which we override explicitly.
show_native() {  # $1 = VARNAME -> prints its value on this host
    ( cd "$PKGSRCDIR/pkgtools/digest" && \
      env -u MAKECONF MAKECONF=/dev/null make show-var VARNAME="$1" )
}
CROSS_LOWER_OPSYS="$(show_native LOWER_OPSYS)"
CROSS_LOWER_OPSYS_VERSUFFIX="$(show_native LOWER_OPSYS_VERSUFFIX)"
CROSS_LOWER_VARIANT_VERSION="$(show_native LOWER_VARIANT_VERSION)"
CROSS_LOWER_VENDOR="$(show_native LOWER_VENDOR)"
CROSS_OS_VARIANT="$(show_native OS_VARIANT)"

# --- 4. Write the pkgsrc cross mk.conf --------------------------------------
# This file is passed as MAKECONF ONLY on the pkgsrc make command lines below;
# it is NEVER exported globally (that would leak into any base `make` and, in
# the spike design, into build.sh). SU_CMD makes pkgsrc escalate via
# passwordless sudo instead of su.
cat > "$PKGSRC_MAKECONF" <<EOF
SU_CMD=/usr/bin/sudo /bin/sh -c
USE_CROSS_COMPILE=yes
TOOLDIR=${TOOLDIR}
CROSS_DESTDIR=${CROSS_DESTDIR}
CROSS_MACHINE_ARCH=${TARGET_ARCH}
CROSS_OPSYS=NetBSD
CROSS_OS_VERSION=${TARGET_VERSION}
CROSS_OPSYS_VERSION=${CROSS_OPSYS_VERSION}
CROSS_LOWER_OPSYS=${CROSS_LOWER_OPSYS}
CROSS_LOWER_OPSYS_VERSUFFIX=${CROSS_LOWER_OPSYS_VERSUFFIX}
CROSS_LOWER_VARIANT_VERSION=${CROSS_LOWER_VARIANT_VERSION}
CROSS_LOWER_VENDOR=${CROSS_LOWER_VENDOR}
CROSS_OS_VARIANT=${CROSS_OS_VARIANT}
CROSS_OBJECT_FMT=ELF
EOF
echo "===== pkgsrc mk.conf ====="
cat "$PKGSRC_MAKECONF"

# --- 5. Early assertion: pkgsrc honours the cross config --------------------
# Cheap (seconds) sanity check BEFORE building packages, so a mis-wired
# mk.conf or missing CROSS_ var fails fast instead of after a long build.
echo "===== pkgsrc cross-config resolution ====="
assert_var() {  # $1=VARNAME  $2=expected-substring
    _v="$( cd "$PKGSRCDIR/pkgtools/digest" && \
           make show-var VARNAME="$1" MAKECONF="$PKGSRC_MAKECONF" )"
    echo "$1 = [$_v]"
    case "$_v" in
        *"$2"*) : ;;
        *) echo "FATAL: $1 resolved to [$_v], expected to contain [$2]"; exit 1 ;;
    esac
}
assert_var SU_CMD sudo
assert_var MACHINE_ARCH "$TARGET_ARCH"
assert_var USE_CROSS_COMPILE yes
echo "cross-config OK"

# --- 6. Cross-build each requested origin -----------------------------------
# BATCH=yes suppresses prompts. DEPENDS_TARGET=package-install both packages
# each dependency (so the repo is self-contained) and installs it (so
# dependents resolve their depends check); the escalation for install goes
# through SU_CMD (sudo). Build all origins even if one fails, but record
# failures so the job exits non-zero: a green run must mean every origin built.
mkdir -p "$PACKAGES_DIR/All"
failed=""
while IFS= read -r origin || [ -n "$origin" ]; do
    case "$origin" in ''|\#*) continue ;; esac
    # Trim surrounding whitespace.
    origin="$(printf '%s' "$origin" | tr -d '[:space:]')"
    [ -n "$origin" ] || continue
    echo "===== CROSS-BUILDING $origin ====="
    if [ ! -d "$PKGSRCDIR/$origin" ]; then
        echo "MISSING ORIGIN: $origin" >&2
        failed="$failed $origin"
        continue
    fi
    if ( cd "$PKGSRCDIR/$origin" && \
         make package BATCH=yes DEPENDS_TARGET=package-install \
              MAKECONF="$PKGSRC_MAKECONF" ); then
        echo "CROSS BUILD OK: $origin"
    else
        echo "CROSS BUILD FAILED: $origin" >&2
        failed="$failed $origin"
    fi
    # Free work trees (deps included) between origins to bound disk use.
    ( cd "$PKGSRCDIR/$origin" && \
      make clean CLEANDEPENDS=yes MAKECONF="$PKGSRC_MAKECONF" ) \
        >/dev/null 2>&1 || true
done < "$SCRIPT_DIR/../config/pkglist"

# --- 7. Confirm target arch and generate the summary index ------------------
echo "===== RESULT: built packages ====="
if ls "$PACKAGES_DIR"/All/*.tgz >/dev/null 2>&1; then
    for tgz in "$PACKAGES_DIR"/All/*.tgz; do
        arch="$(pkg_info -Q MACHINE_ARCH "$tgz" 2>/dev/null || true)"
        echo "$tgz -> MACHINE_ARCH=$arch"
        if [ "$arch" != "$TARGET_ARCH" ]; then
            echo "FATAL: $tgz is $arch, expected $TARGET_ARCH" >&2
            failed="$failed $tgz(arch=$arch)"
        fi
    done
    ( cd "$PACKAGES_DIR/All" && \
      pkg_info -X ./*.tgz | gzip -9 > pkg_summary.gz )
else
    echo "No packages were built" >&2
    failed="$failed (none-built)"
fi

# --- 8. Copy outputs into the shared workspace ------------------------------
# Only WORKSPACE is synced back to the host runner; package output lives under
# $HOME/pkgsrc/packages/All (outside it), so publish a copy here.
OUT="$WORKSPACE/packages"
rm -rf "$OUT"
mkdir -p "$OUT/All"
cp "$PACKAGES_DIR"/All/* "$OUT/All/" 2>/dev/null || true
ls -l "$OUT/All" || true

if [ -n "$failed" ]; then
    echo "===== FAILED:$failed =====" >&2
    exit 1
fi
echo "===== OK: all requested origins cross-built for $TARGET_ARCH ====="
