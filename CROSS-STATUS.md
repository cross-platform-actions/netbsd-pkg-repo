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

## Status: cross-libtool-base blocker SOLVED; bash + rsync build; sudo parked
- ✅ `bash-5.3.15` and `rsync-3.4.4` **cross-built for vax** (run 29482043027).
- ✅ The `cross/cross-libtool-base` blocker that stopped both libtool-using
  packages is fully fixed (three-part fix below). rsync now cross-builds clean.
- ⏸️ `sudo` is TEMPORARILY removed from `config/pkglist`: it cross-builds all its
  deps (incl. cross-libtool-base) but its OWN `configure` dies with "cannot run
  C compiled programs" — a nested configure inside sudo runs a just-built vax
  test binary on the amd64 host because that inner configure isn't given
  `--build`. Distinct from the (solved) libtool blocker; see "sudo" below.

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

**Fix (commits on `cross-build`):** `scripts/cross-build.sh` now supplies, for
every CROSSVARS entry, `TARGET_<var>` (same value as `CROSS_<var>`; arch=vax)
plus `TARGET_OBJECT_FMT=ELF` — so cross-libtool-base always sees
`TARGET_MACHINE_ARCH=vax` regardless of the CROSSTARGETSETTINGS propagation. A
fast pre-build assertion checks `cross/cross-libtool-base`'s `MACHINE_PLATFORM`
ends in `-vax` and aborts in seconds otherwise.

**Subtlety (2nd commit):** `TARGET_*` must be passed on the make COMMAND LINE,
NOT in mk.conf. bsd.prefs.mk's `.ifdef TARGET_MACHINE_ARCH` block — which
*defines* `TARGET_MACHINE_GNU_ARCH` — runs BEFORE it loads MAKECONF, but a
later conditional (`.if defined(TARGET_MACHINE_ARCH) && … ${TARGET_MACHINE_GNU_ARCH} == "arm" …`)
references it. A `TARGET_*` arriving via mk.conf is too late → the derived var
stays empty → `make: Malformed conditional`. Command-line assignments are
present at startup (so the block defines the GNU-arch var). The script builds a
`TARGET_VARS` string and appends it to every pkgsrc make line.

**Su-boundary (3rd commit) — confirmed working for the BUILD:** run 29480298572
showed `cross-libtool-base MACHINE_PLATFORM = [NetBSD-10.1-vax]`, bash built,
the whole native tool closure built, and cross-libtool-base itself **built and
packaged** as `...-NetBSD-10.1-vax-...tgz`. But its `package-install` re-make
(escalated via `SU_CMD`) again saw an empty arch (`work.NetBSD-10.1-`). Cause:
pkgsrc only re-passes a *curated* set across the su boundary
(`PKGSRC_MAKE_ENV` carries `MAKECONF`; `_ROOT_CMD` re-passes `USE_CROSS_COMPILE`)
— NOT `TARGET_*` — and `sudo` resets the environment. Fix: bake `TARGET_*` into
`SU_CMD` as `sudo /usr/bin/env TARGET_…=… /bin/sh -c` (env's args survive
sudo's reset; present at the root make's startup).

Run 29482043027 confirmed the su-boundary fix: `cross-libtool-base` installs and
**rsync cross-builds clean**. (Only sudo then failed, on its own configure.)

**Publish dir (4th commit):** cross-built target packages don't land in
`packages/All` — pkgsrc writes them to `packages.${MACHINE_PLATFORM}/All`
(`packages.NetBSD-10.1-vax/All`), while the native tool closure goes to the
plain `packages/All`. The result check now reads `PACKAGES` (`make show-var`)
from a built origin, collects every `.tgz` there (target + any vax runtime
deps), verifies each requested origin's `PKGNAME` is present and vax, and
publishes those to `$WORKSPACE/packages/All`.

## sudo (the remaining package)
`sudo`'s top-level configure detects cross-compiling correctly, but a NESTED
configure it spawns dies: `configure: error: cannot run C compiled programs. If
you meant to cross compile, use '--build'.` The inner configure isn't given
`--build`, so autoconf thinks it's native and tries to run a vax test binary on
amd64. Next probes: capture the failing `config.log`; check whether sudo uses
`AC_CONFIG_SUBDIRS`/a bundled lib whose configure loses `--build`; try adding
`CONFIGURE_ARGS+=--build=${MACHINE_GNU_PLATFORM}` (or the pkgsrc cross
`--build`) and/or `CONFIG_SITE`. rsync (also libtool) works, so this is
sudo-specific, not an infra gap.

## Next steps (candidates)
1. Confirm the current run goes GREEN (bash + rsync published; deploy skipped on
   branch). Then re-enable `security/sudo` and tackle its nested-configure issue.
2. Add a second cache layer for the native tool closure (perl/bison/texinfo/
   libtool ~16 min/run) to speed iteration.
3. Consider re-adding `curl` (cross removes its perl/openssl blocker).

## Retrigger
Push to `cross-build`, or `gh workflow run build-and-deploy.yml --ref cross-build`.
The toolchain cache persists across runs (key above); bump `SRC_BRANCH` or the
`-v2-` suffix to force a fresh toolchain.
