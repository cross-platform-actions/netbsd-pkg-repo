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
TOOLCHAIN_TARBALL="$TOOLCHAIN_CACHE_DIR/obj.tgz"
PKGSRCDIR="$HOME/pkgsrc"
SRCDIR="$HOME/src"
PKGSRC_MAKECONF="$PKGSRCDIR/mk.conf"
PACKAGES_DIR="$PKGSRCDIR/packages"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# fetch_retry URL OUTFILE: download with ftp(1), retrying transient failures.
# The pinned pkgsrc/src tarballs come from public mirrors (cdn.netbsd.org,
# codeload.github.com) that intermittently return 503s; a single ftp with no
# retry turns a momentary mirror hiccup into a wasted ~20-min CI run (the pkgsrc
# fetch is re-done every run since only the toolchain is cached). Retry a few
# times with backoff before giving up.
fetch_retry() {  # $1 = URL  $2 = output file
    _n=1
    while :; do
        if ftp -o "$2" "$1"; then return 0; fi
        if [ "$_n" -ge 5 ]; then
            echo "FATAL: fetch failed after $_n attempts: $1" >&2
            return 1
        fi
        echo "fetch attempt $_n failed, retrying in $((_n * 10))s: $1" >&2
        sleep "$((_n * 10))"
        _n=$((_n + 1))
    done
}

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
# Resolve sudo's real path: on NetBSD sudo is a pkgsrc binary in /usr/pkg/bin,
# NOT /usr/bin, so SU_CMD must use the actual location (pkgsrc runs SU_CMD from
# a make with its own PATH, where a bare `sudo` or a wrong absolute path is
# "not found" -> Error 127).
SUDO="$(command -v sudo)"
echo "passwordless sudo OK: $SUDO"

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
    ( cd "$OBJDIR" && tar -xzpf "$TOOLCHAIN_TARBALL" )
else
    echo "===== TOOLCHAIN CACHE MISS: building cross toolchain ====="
    if [ ! -f "$SRCDIR/build.sh" ]; then
        cd "$HOME"
        fetch_retry \
            "https://codeload.github.com/NetBSD/src/tar.gz/refs/heads/${SRC_BRANCH}" \
            src.tar.gz
        tar -xzf src.tar.gz
        mv "src-${SRC_BRANCH}" "$SRCDIR"
        rm -f src.tar.gz
    fi
    cd "$SRCDIR"
    ./build.sh -U -m "$TARGET_ARCH" -O "$OBJDIR" tools
    ./build.sh -U -m "$TARGET_ARCH" -O "$OBJDIR" distribution
    # Free the ~1-2 GB source tree; the toolchain + sysroot in $OBJDIR is all
    # the cross build needs from here on. Without this the guest disk fills
    # while writing the cache tarball ("tar: Write error" -> a truncated
    # obj.tar got cached and poisoned every later cache-hit run).
    rm -rf "$SRCDIR"
    echo "===== Writing toolchain tarball for caching ====="
    mkdir -p "$TOOLCHAIN_CACHE_DIR"
    # Cache ONLY the cross toolchain and the vax sysroot, gzip-compressed.
    # Taring the whole objdir (which also holds GBs of build intermediates the
    # package builds never need) as a raw tar overflowed the guest disk.
    # Paths are relative (tar'd from within $OBJDIR) so it extracts cleanly.
    ( cd "$OBJDIR" && tar -czpf "$TOOLCHAIN_TARBALL" tooldir.NetBSD-* "destdir.$TARGET_ARCH" )
    # Verify the tarball is complete before it can be cached, so a truncated
    # write fails loudly here instead of poisoning the cache for future runs.
    tar -tzf "$TOOLCHAIN_TARBALL" >/dev/null
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
    fetch_retry \
        "https://cdn.netbsd.org/pub/pkgsrc/${PKGSRC_BRANCH}/pkgsrc.tar.gz" \
        pkgsrc.tar.gz
    tar -xzf pkgsrc.tar.gz --exclude-vcs
    rm -f pkgsrc.tar.gz
fi

# --- 3+4. Write the pkgsrc cross mk.conf ------------------------------------
# pkgsrc's bsd.prefs.mk requires a CROSS_<var> for EVERY entry in its
# CROSSVARS list, or it aborts ("USE_CROSS_COMPILE=yes but missing cross
# variable settings"). Hand-enumerating that list is fragile -- an earlier
# attempt set CROSS_OS_VARIANT but the list actually wants
# CROSS_LOWER_OS_VARIANT, and hand-computed CROSS_OPSYS_VERSION. Host and
# target are both NetBSD ${TARGET_VERSION}, differing only in MACHINE_ARCH, so
# derive every CROSS_<var> from THIS host's own value (with a clean MAKECONF
# so our file doesn't recurse) and override only MACHINE_ARCH. Deriving the
# whole list means a pkgsrc CROSSVARS change can't silently break us.
# SU_CMD escalates via passwordless sudo (not su, which has no TTY). This file
# is passed as MAKECONF ONLY on the pkgsrc make lines below -- never exported,
# or it would leak into build.sh.
show_native() {  # $1 = VARNAME -> its value on this host
    ( cd "$PKGSRCDIR/pkgtools/digest" && \
      env -u MAKECONF MAKECONF=/dev/null make show-var VARNAME="$1" )
}
# cross/cross-libtool-base is why sudo/rsync need TARGET_*: it declares
# LIBTOOL_CROSS_COMPILE=yes, which makes bsd.prefs.mk run its "switcheroo" --
# `${_v_}=${TARGET_${_v_}}` for every CROSSVARS entry -- so the package is
# BUILT natively but NAMED for the target. With TARGET_MACHINE_ARCH unset there
# MACHINE_ARCH (hence MACHINE_PLATFORM) comes out empty and its PKGNAME/WRKDIR
# degrade to `NetBSD-10.1-`, so pkg_add can't find the built pkg -- the exact
# sudo/rsync blocker.
#
# TARGET_* must reach cross-libtool-base in TWO places, each with its own trap:
#
#  * Its BUILD make: pkgsrc's own CROSSTARGETSETTINGS passes TARGET_* here as
#    ENV, so the build already gets them. We ALSO pass them on the make command
#    line (TARGET_VARS, below) -- present at make startup, which matters because
#    bsd.prefs.mk's `.ifdef TARGET_MACHINE_ARCH` block (which DEFINES
#    TARGET_MACHINE_GNU_ARCH etc.) runs BEFORE it loads MAKECONF, yet a later
#    conditional references ${TARGET_MACHINE_GNU_ARCH}. A TARGET_* arriving via
#    mk.conf would be too late -> empty derived var -> "Malformed conditional".
#
#  * Its ROOT INSTALL re-make (DEPENDS_TARGET=package-install escalates via
#    SU_CMD): pkgsrc only re-passes a CURATED set across the su boundary
#    (MAKECONF via PKGSRC_MAKE_ENV, USE_CROSS_COMPILE in _ROOT_CMD) -- NOT
#    TARGET_*, and sudo resets the environment, so the root make loses them and
#    the install path degrades to `NetBSD-10.1-` again. So bake TARGET_* into
#    SU_CMD via `env` INSIDE the sudo call (`sudo env TARGET_...=... /bin/sh -c`):
#    env's args survive sudo's env reset, whereas a plain prefix before sudo
#    would be stripped. Present at the root make's startup, so its .ifdef block
#    defines the derived vars too.
#
# Host and target are the same NetBSD ${TARGET_VERSION} differing only in
# MACHINE_ARCH, so each TARGET_<var> == the native value except the arch.
TARGET_VARS="TARGET_OBJECT_FMT=ELF"
CROSS_LINES=""
for _v in OPSYS OS_VERSION OPSYS_VERSION LOWER_OPSYS \
          LOWER_OPSYS_VERSUFFIX LOWER_VARIANT_VERSION LOWER_VENDOR \
          LOWER_OS_VARIANT MACHINE_ARCH; do
    if [ "$_v" = MACHINE_ARCH ]; then
        _val="${TARGET_ARCH}"
    else
        _val="$(show_native "$_v")"
    fi
    CROSS_LINES="${CROSS_LINES}CROSS_${_v}=${_val}
"
    TARGET_VARS="${TARGET_VARS} TARGET_${_v}=${_val}"
done

{
    # SU_CMD escalates to root for package-install (via passwordless sudo, not
    # su, which has no TTY). The `env ${TARGET_VARS}` wrapper carries TARGET_*
    # into the root make -- see the block comment above.
    echo "SU_CMD=${SUDO} /usr/bin/env ${TARGET_VARS} /bin/sh -c"
    # sudo's configure resolves the TARGET compiler fine, then runs a SECOND
    # probe (autoconf-archive's AX_PROG_CC_FOR_BUILD) for a NATIVE *build*
    # compiler to build host-side codegen tools. Left to itself it falls back to
    # bare `gcc`, which under a pkgsrc cross build is the WRAPPER pointing at the
    # vax cross-compiler -> the probe's run-test builds a vax binary that can't
    # execute on amd64 ("cannot run C compiled programs", exit 77). bash/rsync
    # never probe a build compiler, so only sudo hits this.
    #
    # Feed that probe pkgsrc's own native build compiler via CC_FOR_BUILD, the
    # exact recipe pkgsrc's cross HOWTO and its own packages (devel/gmp,
    # lang/gcc14) use. Write the make-variable references literally (mk.conf is
    # read as a makefile): ${NATIVE_CC} is `/usr/bin/cc -B /usr/libexec -B
    # /usr/bin` (mk/tools/tools.NetBSD.mk) -- the -B flags make cc use the NATIVE
    # as/ld from /usr/libexec and /usr/bin instead of the vax cross as/ld the
    # pkgsrc wrapper puts first on PATH (a bare /usr/bin/gcc without -B picked up
    # the vax as/ld and failed with "C compiler cannot create executables"). The
    # :Q quoting is required: NATIVE_CC contains spaces and CONFIGURE_ENV is a
    # token list, so :Q keeps each value one argument. A native build compiler is
    # correct for ANY cross package, so set it globally. Single-quoted so the
    # shell doesn't try to expand ${...} -- pkgsrc make expands them at use time.
    echo 'CONFIGURE_ENV+=CC_FOR_BUILD=${NATIVE_CC:Q}'
    echo 'CONFIGURE_ENV+=CXX_FOR_BUILD=${NATIVE_CXX:Q}'
    echo 'CONFIGURE_ENV+=LD_FOR_BUILD=${NATIVE_LD:Q}'
    # NOTE the ?= (per pkgsrc's HOWTO-use-crosscompile): it's a DEFAULT, not a
    # force. Target packages cross-build, but pkgsrc recursively sets
    # USE_CROSS_COMPILE=no for bootstrap/tool dependencies that must run on the
    # host (libnbcompat, perl, texinfo, bison...), so those build NATIVELY for
    # amd64 -- where their configure run-tests (AC_RUN "cannot run test program
    # while cross compiling") execute fine. A hard = would force even host
    # tools to cross-build and fail those probes.
    echo "USE_CROSS_COMPILE?=yes"
    echo "TOOLDIR=${TOOLDIR}"
    echo "CROSS_DESTDIR=${CROSS_DESTDIR}"
    echo "CROSS_OBJECT_FMT=ELF"
    # The full pkgsrc CROSSVARS list except OBJECT_FMT (set above). Deriving
    # every CROSS_<var> from THIS host and overriding only MACHINE_ARCH means a
    # pkgsrc CROSSVARS change can't silently leave one missing (bsd.prefs.mk
    # aborts on any absent CROSS_<var>).
    printf '%s' "$CROSS_LINES"
} > "$PKGSRC_MAKECONF"
echo "===== pkgsrc mk.conf ====="
cat "$PKGSRC_MAKECONF"
echo "===== TARGET_* (make command-line + SU_CMD env) ====="
echo "$TARGET_VARS"

# --- 5. Early assertion: pkgsrc honours the cross config --------------------
# Cheap (seconds) sanity check BEFORE building packages, so a mis-wired
# mk.conf or missing CROSS_ var fails fast instead of after a long build.
echo "===== pkgsrc cross-config resolution ====="
assert_var() {  # $1=VARNAME  $2=expected-substring
    _v="$( cd "$PKGSRCDIR/pkgtools/digest" && \
           make show-var VARNAME="$1" MAKECONF="$PKGSRC_MAKECONF" $TARGET_VARS )"
    echo "$1 = [$_v]"
    case "$_v" in
        *"$2"*) : ;;
        *) echo "FATAL: $1 resolved to [$_v], expected to contain [$2]"; exit 1 ;;
    esac
}
assert_var SU_CMD sudo
assert_var MACHINE_ARCH "$TARGET_ARCH"
assert_var USE_CROSS_COMPILE yes
# NATIVE_CC feeds sudo's build-compiler probe (CC_FOR_BUILD); confirm it resolves
# to a native compiler with the -B flags that force native as/ld. Not fatal (it
# only matters to sudo) -- just surface it in the log for diagnosis.
_ncc="$( cd "$PKGSRCDIR/pkgtools/digest" && \
         make show-var VARNAME=NATIVE_CC MAKECONF="$PKGSRC_MAKECONF" $TARGET_VARS )"
echo "NATIVE_CC = [$_ncc]"

# cross/cross-libtool-base is the sudo/rsync blocker: its LIBTOOL_CROSS_COMPILE
# switcheroo derives MACHINE_PLATFORM from TARGET_MACHINE_ARCH, so confirm that
# resolves to a target-arch platform (not the empty `NetBSD-<ver>-`) before we
# spend a package build discovering it the hard way.
if [ -d "$PKGSRCDIR/cross/cross-libtool-base" ]; then
    _p="$( cd "$PKGSRCDIR/cross/cross-libtool-base" && \
           make show-var VARNAME=MACHINE_PLATFORM MAKECONF="$PKGSRC_MAKECONF" $TARGET_VARS )"
    echo "cross-libtool-base MACHINE_PLATFORM = [$_p]"
    case "$_p" in
        *-"$TARGET_ARCH") : ;;
        *) echo "FATAL: cross-libtool-base MACHINE_PLATFORM [$_p] does not end in -$TARGET_ARCH (TARGET_MACHINE_ARCH unset?)"; exit 1 ;;
    esac
fi
echo "cross-config OK"

# --- 6. Cross-build each requested origin -----------------------------------
# BATCH=yes suppresses prompts. DEPENDS_TARGET=package-install both packages
# each dependency (so the repo is self-contained) and installs it (so
# dependents resolve their depends check); the escalation for install goes
# through SU_CMD (sudo). Build all origins even if one fails, but record
# failures so the job exits non-zero: a green run must mean every origin built.
mkdir -p "$PACKAGES_DIR/All"
failed=""
target_pkgs=""
TARGET_PKGDIR=""
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
              MAKECONF="$PKGSRC_MAKECONF" $TARGET_VARS ); then
        echo "CROSS BUILD OK: $origin"
        # Record the expected package name (step 7 requires each to exist as a
        # $TARGET_ARCH package) and, once, the cross PACKAGES dir. pkgsrc writes
        # cross-built target packages to packages.${MACHINE_PLATFORM}/All (e.g.
        # packages.NetBSD-10.1-vax/All), SEPARATE from the native tool closure
        # it drops in the plain packages/All -- so we collect from PACKAGES.
        _pkgname="$( cd "$PKGSRCDIR/$origin" && \
                     make show-var VARNAME=PKGNAME \
                          MAKECONF="$PKGSRC_MAKECONF" $TARGET_VARS )"
        target_pkgs="$target_pkgs $_pkgname"
        if [ -z "$TARGET_PKGDIR" ]; then
            TARGET_PKGDIR="$( cd "$PKGSRCDIR/$origin" && \
                make show-var VARNAME=PACKAGES \
                     MAKECONF="$PKGSRC_MAKECONF" $TARGET_VARS )/All"
        fi
    else
        echo "CROSS BUILD FAILED: $origin" >&2
        failed="$failed $origin"
        # Surface config.log context so a cross-configure failure (e.g. "cannot
        # run C compiled programs") is diagnosable from this run's log without
        # another ~20-min CI round-trip. There can be several (nested configs).
        # The confdefs.h dump lives at the END of config.log, so a plain tail
        # misses the actual compiler/linker error -- also grep the error-bearing
        # lines (the conftest command + gcc/ld/collect2/"cannot" output) which
        # sit near the top for a first-probe failure.
        find "$PKGSRCDIR/$origin"/work* -name config.log 2>/dev/null | while IFS= read -r _cl; do
            echo "----- config.log: $_cl (error lines) -----"
            grep -nE "configure:[0-9]+:|error|cannot|conftest|gcc|/ld|collect2|C compiler|CC_FOR_BUILD" \
                "$_cl" 2>/dev/null | head -n 60 || true
            echo "----- config.log: $_cl (last 25 lines) -----"
            tail -n 25 "$_cl" 2>/dev/null || true
        done
    fi
    # Free work trees (deps included) between origins to bound disk use.
    ( cd "$PKGSRCDIR/$origin" && \
      make clean CLEANDEPENDS=yes MAKECONF="$PKGSRC_MAKECONF" $TARGET_VARS ) \
        >/dev/null 2>&1 || true
done < "$SCRIPT_DIR/../config/pkglist"

# --- 7. Confirm target arch and generate the summary index ------------------
# Collect every $TARGET_ARCH package from the cross PACKAGES dir (target build
# packages plus any vax runtime deps pkgsrc cross-built). The native host tool
# closure lives in the separate plain packages/All and is intentionally ignored.
echo "===== RESULT: built target packages ====="
echo "target package dir: ${TARGET_PKGDIR:-<none>}"
PUBLISH_DIR="$PKGSRCDIR/publish"
rm -rf "$PUBLISH_DIR"
mkdir -p "$PUBLISH_DIR"
if [ -n "$TARGET_PKGDIR" ] && ls "$TARGET_PKGDIR"/*.tgz >/dev/null 2>&1; then
    for tgz in "$TARGET_PKGDIR"/*.tgz; do
        arch="$(pkg_info -Q MACHINE_ARCH "$tgz" 2>/dev/null || true)"
        echo "  $(basename "$tgz") ($arch)"
        cp "$tgz" "$PUBLISH_DIR/"
    done
else
    echo "No target packages were built" >&2
    failed="$failed (none-built)"
fi

# Every requested origin must have produced a $TARGET_ARCH package.
for _want in $target_pkgs; do
    _f="$PUBLISH_DIR/$_want.tgz"
    _a="$(pkg_info -Q MACHINE_ARCH "$_f" 2>/dev/null || true)"
    if [ -f "$_f" ] && [ "$_a" = "$TARGET_ARCH" ]; then
        echo "target package OK: $_want.tgz ($_a)"
    else
        echo "FATAL: target package $_want.tgz missing or not $TARGET_ARCH (arch=$_a)" >&2
        failed="$failed $_want(missing-or-wrong-arch)"
    fi
done

# Summary index over the published ($TARGET_ARCH) packages only.
if ls "$PUBLISH_DIR"/*.tgz >/dev/null 2>&1; then
    ( cd "$PUBLISH_DIR" && pkg_info -X ./*.tgz | gzip -9 > pkg_summary.gz )
fi

# --- 8. Copy outputs into the shared workspace ------------------------------
# Only WORKSPACE is synced back to the host runner; package output lives under
# $HOME/pkgsrc/packages (outside it), so publish the $TARGET_ARCH set here.
OUT="$WORKSPACE/packages"
rm -rf "$OUT"
mkdir -p "$OUT/All"
cp "$PUBLISH_DIR"/* "$OUT/All/" 2>/dev/null || true
ls -l "$OUT/All" || true

if [ -n "$failed" ]; then
    echo "===== FAILED:$failed =====" >&2
    exit 1
fi
echo "===== OK: all requested origins cross-built for $TARGET_ARCH ====="
