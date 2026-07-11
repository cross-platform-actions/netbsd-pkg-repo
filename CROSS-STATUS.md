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

## The remaining blocker
`sudo` and `rsync` both die building `cross/cross-libtool-base`:

    pkg_add: Can't process .../cross/cross-libtool-base/work.NetBSD-10.1-/.packages/cross-libtool-base-NetBSD-10*: No such file or directory

Root cause: that package's `PKGNAME=${DISTNAME:S/^libtool-/cross-libtool-base-${MACHINE_PLATFORM}-/}`
and `MACHINE_PLATFORM` = `OPSYS-OS_VERSION-MACHINE_ARCH` resolves to
`NetBSD-10.1-` — **`MACHINE_ARCH` is empty** when this package is evaluated, so
the work dir / package name are malformed and pkg_add can't find the built pkg.
`cross/cross-libtool-base` is pkgsrc's self-described "kludgerific copypasta"
cross-libtool corner.

## Next steps (candidates)
1. Probe why `MACHINE_ARCH` (hence `MACHINE_PLATFORM`) is empty specifically for
   `cross/cross-libtool-base` — likely an interaction between the recursive
   native-tool build (`USE_CROSS_COMPILE=no`) and our derived `CROSS_*` vars.
   Fast probe: in the guest, `cd cross/cross-libtool-base && make show-var
   VARNAME=MACHINE_ARCH` (and `MACHINE_PLATFORM`, `USE_CROSS_COMPILE`) with our
   mk.conf as MAKECONF.
2. Or sidestep pkgsrc's cross-libtool for sudo/rsync (use the sysroot's libtool
   / a `LIBTOOL`-related override) so they don't pull `cross-libtool-base`.
3. Add a second cache layer for the native tool closure to speed iteration.
4. Once sudo/rsync build: confirm all three `.tgz` are `MACHINE_ARCH=vax`, wire
   collection/upload, then consider re-adding `curl` (cross removes its
   perl/openssl blocker).

## Retrigger
Push to `cross-build`, or `gh workflow run build-and-deploy.yml --ref cross-build`.
The toolchain cache persists across runs (key above); bump `SRC_BRANCH` or the
`-v2-` suffix to force a fresh toolchain.
