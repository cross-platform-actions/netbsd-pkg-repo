# NetBSD Package Repository

Binary NetBSD [pkgsrc] packages built for CPU architectures not covered by
the official NetBSD package mirrors (e.g. vax).

The packages are **cross-compiled on a NetBSD/amd64 host** (booted by the
[Cross-Platform Action]) using a [NetBSD `build.sh`][build.sh] cross toolchain
and sysroot, then published to GitHub Pages on every push to `master`.

[Cross-Platform Action]: https://github.com/cross-platform-actions/action

[pkgsrc]: https://www.pkgsrc.org/
[build.sh]: https://www.netbsd.org/docs/guide/en/chap-build.html
[netbsd-builder]: https://github.com/cross-platform-actions/netbsd-builder

## Why cross-compile instead of emulate?

The sibling [freebsd-pkg-repo] builds with poudriere + **QEMU user-mode
emulation** (`binmiscctl`), running the host natively and only emulating
target binaries — fast (5–10× slowdown). That is impossible for vax: **there
is no qemu-user backend for vax**, only full-system [SIMH] MicroVAX 3900
emulation, which is far slower.

Building *inside* emulated vax proved structurally infeasible: `perl` (a
transitive build dependency of nearly everything, via texinfo/bison, and of
openssl) takes **longer than GitHub's 6-hour job limit** to compile on the
single-CPU emulated VAX and cannot resume mid-compile, so it can never finish.

Cross-compiling fixes this at the root. With pkgsrc's `USE_CROSS_COMPILE=yes`,
the entire build-tool closure (perl, texinfo, bison, …) is built **natively as
tool-dependencies for the amd64 host**, and a target (vax) perl is *never*
built. Only the actual target libraries and programs are cross-compiled, on a
fast KVM-accelerated NetBSD/amd64 VM. This keeps freebsd-pkg-repo's structure
(config-driven lists, matrix → build → deploy, GitHub Pages) but replaces the
build engine:

| FreeBSD | NetBSD (here) |
|---|---|
| poudriere | `bmake package` (pkgsrc) with `USE_CROSS_COMPILE=yes` |
| qemu-user-static + `binmiscctl` | NetBSD `build.sh` cross toolchain + sysroot |
| Cross-Platform Action FreeBSD VM | Cross-Platform Action **NetBSD/amd64** VM |
| `pkg` + `repos/custom.conf` | `pkg_add` + `PKG_PATH` |

[freebsd-pkg-repo]: https://github.com/cross-platform-actions/freebsd-pkg-repo
[SIMH]: https://opensimh.org/

## How the build works

Everything runs inside the NetBSD/amd64 guest booted by the Cross-Platform
Action, as the unprivileged `runner` user (which has passwordless `sudo`).
`scripts/cross-build.sh` orchestrates it:

1. **Cross toolchain + sysroot.** If the cached toolchain tarball is present
   it is extracted; otherwise `build.sh -U -m vax -O <objdir> tools`
   (~12 min) then `distribution` (~75 min) produce the cross gcc/binutils
   (`TOOLDIR`) and the target headers+libraries sysroot (`CROSS_DESTDIR`).
   `build.sh` runs **unprivileged** and with a clean default `MAKECONF` — the
   pkgsrc cross settings are deliberately kept out of it.
2. **pkgsrc.** The pinned quarterly tree is fetched with base `ftp(1)` (no
   git/curl needed) and extracted.
3. **Cross-build.** Each origin in `config/pkglist` is built with
   `make package BATCH=yes DEPENDS_TARGET=package-install`, using a dedicated
   pkgsrc `MAKECONF` (`$HOME/pkgsrc/mk.conf`) passed only on the pkgsrc make
   command lines. That `MAKECONF` sets the cross variables plus
   `SU_CMD=/usr/bin/sudo /bin/sh -c` so pkgsrc escalates for dependency
   installation via passwordless `sudo` (base `su` fails non-interactively).
4. **Publish.** The resulting vax `.tgz` and a generated `pkg_summary.gz` are
   copied into the workspace, pulled back to the runner, and uploaded as an
   artifact for the deploy job.

An early, cheap assertion confirms pkgsrc actually resolves `SU_CMD` to sudo,
`MACHINE_ARCH=vax` and `USE_CROSS_COMPILE=yes` **before** any long build, so a
mis-wired `MAKECONF` fails in seconds rather than after hours.

### MAKECONF scoping (important)

NetBSD base `make` reads `/etc/mk.conf` by default; `$HOME/pkgsrc/mk.conf` is
**not** read unless `MAKECONF` points at it. The pkgsrc cross config is
therefore applied **only** to the pkgsrc `make` invocations (via
`MAKECONF=$HOME/pkgsrc/mk.conf` on those command lines) and is **never**
exported globally, so it cannot leak into `build.sh` and break its
`distribution`/postinstall.

## Toolchain caching

The `build.sh` toolchain + sysroot is expensive (~90 min) but stable, so it is
cached and reused: later runs restore it and finish in minutes instead of
hours. The objdir is multi-GB and ~100k files, which is slow to rsync across
the guest/runner boundary, so it is moved as a **single tarball**
(`toolchain-cache/obj.tar`) under the workspace and persisted on the runner
with `actions/cache`, keyed on the target arch+version and the NetBSD
`SRC_BRANCH`. Bumping `SRC_BRANCH` invalidates the cache and rebuilds the
toolchain.

## Supported targets

| Architecture | NetBSD version |
|--------------|----------------|
| vax          | 10.1           |

## Using the repository

On a NetBSD vax system, point `PKG_PATH` at the target's `All/` directory and
install with the base `pkg_add` (no pkgin bootstrap required):

```sh
export PKG_PATH="https://<user>.github.io/netbsd-pkg-repo/NetBSD-10.1-vax/All"
pkg_add bash sudo rsync
```

Replace `<user>` with the GitHub user or organization hosting this repository.

## Adding things

All configuration is driven by plain-text lists. Add a line, push to
`master`, and the workflow rebuilds the repository.

| File | Purpose |
|------|---------|
| `config/pkglist` | One pkgsrc origin per line (e.g. `net/rsync`) |
| `config/architectures` | One target architecture per line (see below) |
| `config/versions` | One NetBSD version per line (e.g. `10.1`) |
| `config/pkgsrc_branch` | The pinned pkgsrc quarterly branch to build from |

### `config/architectures` format

One architecture per line — the target `MACHINE_ARCH` to cross-build for
(e.g. `vax`). Lines starting with `#` and blank lines are ignored.

## How the workflow is structured

The workflow runs three jobs per push:

1. **generate-matrix** — reads `config/architectures` and `config/versions`
   and emits a JSON matrix (architecture × version).
2. **build** — one job per matrix entry, on `ubuntu-latest`. It restores the
   toolchain cache, boots a NetBSD/amd64 VM via the Cross-Platform Action
   (KVM-accelerated, `memory: 12G`, `cpu_count: 4`) and runs
   `scripts/cross-build.sh` inside it (see *How the build works*). The built
   vax packages are uploaded as an artifact.
3. **deploy** — **runs only on `master`.** It merges all artifacts into one
   tree (`NetBSD-<version>-<arch>/All/...`), generates a landing page and
   directory indexes, and deploys to GitHub Pages. Branch pushes build and
   upload artifacts but do not deploy.

## Setup

GitHub Pages must be enabled with source set to **GitHub Actions**
(Settings → Pages → Build and deployment source).

## License

See [LICENSE](LICENSE).
