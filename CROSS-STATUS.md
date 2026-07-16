# Cross-compile retarget — status & resume notes

Work-in-progress on branch `cross-build`. Retargets the build from emulating
NetBSD/vax under SIMH to **cross-compiling** on a NetBSD/amd64 host (via
`cross-platform-actions/action`). Delete this file before merging to master.

## Why (the wall this escapes)
Building inside the emulated VAX is dead: `perl` (a transitive *build-time*
dependency of nearly everything, via texinfo/bison) takes far longer than
GitHub's 6-hour job limit to compile on the single-CPU emulated VAX and cannot
resume mid-build, so it never converges. Cross-compiling builds the entire
build-tool closure (perl, texinfo, bison, libtool, libnbcompat…) **natively for
amd64** and only cross-compiles the target's own code — no emulated perl.

## Status: PROVEN, one blocker left
- ✅ `bash-5.3.15.tgz` **cross-built for vax** end-to-end (run 29160941941).
  Cross-compiling works.
- ❌ `sudo` and `rsync` both fail at the **same** blocker (see below). bash has
  no libtool dependency and sailed through; sudo+rsync do.

## How it works (pipeline)
1. `Restore toolchain cache` (key `toolchain-vax-101-netbsd-10-v2-…`).
2. `Start VM`: `cross-platform-actions/action@v1.3.0`, `operating_system: netbsd`,
   `architecture: x86-64`, `version: 10.1`, `memory: 12G` (KVM → near-native).
3. `scripts/cross-build.sh` in the guest (unprivileged `runner`, passwordless
   sudo):
   - Cache hit → extract the gzipped toolchain tarball (tooldir + destdir only);
     miss → `build.sh -U -m vax tools + distribution` (~90 min), then tar+gzip
     *only* `tooldir.NetBSD-*` + `destdir.vax` (taring the whole objdir once
     overflowed the guest disk → truncated cache) and verify with `tar -tzf`.
   - Write `$PKGSRCDIR/mk.conf` (used as MAKECONF **only** on pkgsrc make lines,
     never exported → must not leak into build.sh):
     - `SU_CMD=$(command -v sudo) /bin/sh -c` — sudo is `/usr/pkg/bin/sudo` on
       NetBSD, not `/usr/bin/sudo`.
     - `USE_CROSS_COMPILE?=yes` — **the `?=` matters**: pkgsrc recursively sets
       `USE_CROSS_COMPILE=no` for host/bootstrap tool-deps so they build native.
     - Every entry of pkgsrc's `CROSSVARS` derived from the native host
       (`make show-var`), overriding only `CROSS_MACHINE_ARCH=vax`. (Missing
       `CROSS_LOWER_OS_VARIANT` had aborted with "missing cross variable
       settings".)
   - `make package BATCH=yes DEPENDS_TARGET=package-install` per origin in
     `config/pkglist` (bash, sudo, rsync).
4. Deploy job publishes to Pages — **gated to master**, so branch runs build +
   upload only.

Cache-hit runs are ~3 min to reach packages; the native tool closure (perl,
bison, texinfo, libtool-base) rebuilds each run (~16 min) — candidate for a
second cache layer.

## The remaining blocker — DIAGNOSED & FIX PUSHED (awaiting CI)
`sudo` and `rsync` both died building `cross/cross-libtool-base`:

    pkg_add: Can't process .../cross/cross-libtool-base/work.NetBSD-10.1-/.packages/cross-libtool-base-NetBSD-10*: No such file or directory

**Root cause (confirmed against pkgsrc-trunk source, not guessed):**
`cross/cross-libtool-base/Makefile` sets `LIBTOOL_CROSS_COMPILE=yes`. That flag
makes `mk/bsd.prefs.mk` run its cross-libtool "switcheroo":

    .if ${LIBTOOL_CROSS_COMPILE:U:tl} == "yes"
    .  for _v_ in ${CROSSVARS}
    ${_v_}=  ${TARGET_${_v_}}      # MACHINE_ARCH := ${TARGET_MACHINE_ARCH}, etc.
    .  endfor

i.e. the package is *built natively but named for the target*, taking its
`MACHINE_ARCH` (hence `MACHINE_PLATFORM`, hence `PKGNAME`/`WRKDIR`) from
`TARGET_MACHINE_ARCH`. We never set `TARGET_MACHINE_ARCH`, so it expanded to
empty → `MACHINE_PLATFORM=NetBSD-10.1-` → malformed pkg. (bsd.prefs.mk even has
`PKG_FAIL_REASON+= "Must set TARGET_MACHINE_ARCH for cross-libtool."` for this.)

pkgsrc is *supposed* to feed `TARGET_*` into the tool-dep build via
`CROSSTARGETSETTINGS` (`mk/pkgformat/pkg/depends.mk` builds it from the parent's
CROSSVARS), but under our top-level `make package DEPENDS_TARGET=package-install`
that didn't reach `cross-libtool-base`. bash never hit this because it has no
`USE_LIBTOOL`; sudo/rsync do, and `mk/bsd.pkg.use.mk` swaps in
`cross-libtool-base` as a `TOOL_DEPENDS` under `USE_CROSS_COMPILE=yes`.

**Fix (commit on `cross-build`):** `scripts/cross-build.sh` now writes, for every
CROSSVARS entry, BOTH `CROSS_<var>` and `TARGET_<var>` (same value; arch=vax)
plus `TARGET_OBJECT_FMT=ELF` into mk.conf — so cross-libtool-base always sees
`TARGET_MACHINE_ARCH=vax` regardless of the CROSSTARGETSETTINGS propagation. A
fast pre-build assertion now checks `cross/cross-libtool-base`'s
`MACHINE_PLATFORM` ends in `-vax` and aborts in seconds otherwise.

## Next steps (candidates)
1. Verify the pushed fix on CI: watch that the `cross-config` assertion prints
   `cross-libtool-base MACHINE_PLATFORM = [NetBSD-10.1-vax]` and that sudo+rsync
   build to completion.
2. Add a second cache layer for the native tool closure (perl/bison/texinfo/
   libtool ~16 min/run) to speed iteration.
3. Once sudo/rsync build: confirm all three `.tgz` are `MACHINE_ARCH=vax`, wire
   collection/upload, then consider re-adding `curl` (cross removes its
   perl/openssl blocker).

## Retrigger
Push to `cross-build`, or `gh workflow run build-and-deploy.yml --ref cross-build`.
The toolchain cache persists across runs (key above); bump `SRC_BRANCH` or the
`-v2-` suffix to force a fresh toolchain.
