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

## Status: bash + rsync + sudo all cross-build GREEN (all blockers SOLVED)
- ✅ GREEN end-to-end run 29607713768 (build job success; deploy skipped on
  branch). Published vax set: `bash-5.3.15`, `rsync-3.4.4`, `sudo-1.9.17p1`,
  plus rsync's vax runtime deps `lz4`, `popt`, `xxhash`, `zstd` — host tool
  closure excluded.
- ✅ `bash-5.3.15`, `rsync-3.4.4` and `sudo-1.9.17p1` **cross-built for vax**.
- ✅ The `cross/cross-libtool-base` blocker that stopped both libtool-using
  packages is fully fixed (three-part fix below). rsync + sudo cross-build clean.
- ✅ `sudo`'s own-configure blocker is SOLVED (run 29607713768): its second
  compiler probe (`AX_PROG_CC_FOR_BUILD`) needed a native BUILD compiler; feeding
  it pkgsrc's `${NATIVE_CC}` via `CONFIGURE_ENV` fixed it. See "sudo" below.
- ✅ Fetch is now mirror-resilient: `cdn.netbsd.org` 503 outages fall back to the
  `NetBSD/pkgsrc` GitHub mirror (see "Fetch resilience" below).

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

## The cross-libtool-base blocker — SOLVED
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

## sudo — SOLVED (run 29607713768; fix in scripts/cross-build.sh)
`sudo`'s configure resolves the TARGET compiler fine (`vax--netbsdelf-gcc`,
`cross compiling... yes`), then runs a SECOND compiler probe —
autoconf-archive's `AX_PROG_CC_FOR_BUILD` (`security/sudo` calls it via
`configure.ac`) — for a NATIVE **build** compiler to build host-side codegen
tools. Left alone it searched `x86_64--netbsd-gcc` (`${build_alias}-gcc`, absent)
then fell back to bare `gcc`, which in a pkgsrc cross build is the compiler
WRAPPER pointing at the vax cross-compiler → its run-test built a vax binary that
can't run on amd64 → `cannot run C compiled programs` (exit 77). bash/rsync never
probe a build compiler, so only sudo hit this.

**Fix (the pkgsrc-blessed recipe, per `doc/HOWTO-dev-crosscompile`; mirrors
`devel/gmp` and `lang/gcc14`):** feed the probe a native build compiler via
`CONFIGURE_ENV`, written as literal make-variable references in our mk.conf
(read as a makefile, so pkgsrc expands them at use time):

    CONFIGURE_ENV+=CC_FOR_BUILD=${NATIVE_CC:Q}
    CONFIGURE_ENV+=CXX_FOR_BUILD=${NATIVE_CXX:Q}
    CONFIGURE_ENV+=LD_FOR_BUILD=${NATIVE_LD:Q}

`AX_PROG_CC_FOR_BUILD` does `pushdef([CC], CC_FOR_BUILD)` then `AC_PROG_CC`, and
`AC_PROG_CC` honours a preset `$CC` — so a set `CC_FOR_BUILD` wins over the
`build_alias-gcc`/`gcc` search. The value that matters is pkgsrc's `NATIVE_CC`
(`mk/tools/tools.NetBSD.mk`): `/usr/bin/cc -B /usr/libexec -B /usr/bin`. The
**`-B` flags are the crux** — they force cc to use the NATIVE as/ld from
/usr/libexec and /usr/bin instead of the vax cross as/ld that the pkgsrc wrapper
puts first on PATH. (A first attempt with a bare `CC_FOR_BUILD=/usr/bin/gcc`
cleared the "cannot run" error but then failed one step earlier with "C compiler
cannot create executables" precisely because it linked with the vax ld.) `:Q`
quoting is required because `NATIVE_CC` contains spaces and `CONFIGURE_ENV` is a
token list.

## Fetch resilience — mirror fallback (scripts/cross-build.sh)
The pinned pkgsrc tree is re-fetched every run (only the toolchain is cached),
and `cdn.netbsd.org` had a *sustained* 503 outage that failed two consecutive
runs. `fetch_retry OUTFILE URL...` now takes a list of mirrors and tries each in
order over several rounds; the pkgsrc fetch falls back from `cdn.netbsd.org` to
the `NetBSD/pkgsrc` GitHub mirror (codeload, the same reliable host used for the
src tree). The two tarballs unpack to different top dirs (`pkgsrc/` vs
`pkgsrc-${PKGSRC_BRANCH}/`), so the GitHub layout is normalized into `$PKGSRCDIR`.
The on-failure config.log dump also now greps the compiler/linker error lines
(the confdefs.h block at the file end had pushed the real error out of tail).

## Next steps (candidates)
1. Add a second cache layer for the native tool closure (perl/bison/texinfo/
   libtool ~16 min/run) to speed iteration.
2. Consider re-adding `curl` (cross removes its perl/openssl blocker).
3. This branch is ready to merge to master (delete this file on merge); the
   deploy job is gated to master and will publish the vax set on merge.

## Retrigger
Push to `cross-build`, or `gh workflow run build-and-deploy.yml --ref cross-build`.
The toolchain cache persists across runs (key above); bump `SRC_BRANCH` or the
`-v2-` suffix to force a fresh toolchain.
