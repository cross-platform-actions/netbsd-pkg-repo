# NetBSD Package Repository

Binary NetBSD [pkgsrc] packages built for CPU architectures not covered by the
official NetBSD package mirrors (e.g. vax).

The packages are **cross-compiled on a NetBSD/amd64 host** using a
[NetBSD `build.sh`][build.sh] cross toolchain and sysroot, then published as
**immutable GitHub releases**. Pushing a version tag (`v*`) builds the packages
and creates a **draft** release per target; a maintainer reviews and publishes
it. Publishing is what makes the release immutable — its assets are locked, its
tag is protected, and GitHub generates a signed
[release attestation][immutable-releases] — so a consumer that pins a release
gets exactly those bytes, and not even a compromised maintainer account can
tamper with an already-published release. Publishing also refreshes the GitHub
Pages landing page, which hosts only a small index of the releases.

Cross-compiling is used because the target architectures are slow or
impractical to build on natively: a full package set built under system
emulation cannot finish within CI time limits. With pkgsrc's
`USE_CROSS_COMPILE=yes` the entire build-tool closure (perl, texinfo, bison, …)
is built **natively as tool-dependencies for the amd64 host**, and only the
actual target libraries and programs are cross-compiled, on a fast
KVM-accelerated NetBSD/amd64 VM.

[pkgsrc]: https://www.pkgsrc.org/
[build.sh]: https://www.netbsd.org/docs/guide/en/chap-build.html
[Cross-Platform Action]: https://github.com/cross-platform-actions/action
[immutable-releases]: https://docs.github.com/en/code-security/supply-chain-security/understanding-your-software-supply-chain/immutable-releases

## Supported targets

| Architecture | NetBSD version |
|--------------|----------------|
| vax          | 10.1           |

## Using the repository

Each version tag publishes a per-target immutable release tagged
`<abi>--<version>` (e.g. `NetBSD-10.1-vax--v1.2.0`), whose flat set of `.tgz`
assets plus `pkg_summary.gz` is exactly what pkgsrc's `PKG_PATH` fetches. The
[landing page] lists the newest published release per target with a
ready-to-copy `PKG_PATH`; the [releases page] lists every version.

On a NetBSD vax system, point `PKG_PATH` at a release's download URL and install
with the base `pkg_add` (no pkgin bootstrap required):

```sh
export PKG_PATH="https://github.com/<user>/netbsd-pkg-repo/releases/download/<tag>"
pkg_add bash sudo rsync
```

Replace `<user>` with the GitHub user or organization hosting this repository
and `<tag>` with the release tag you want to pin.

### Verifying integrity

Pinning a tag makes a build reproducible; the release attestation lets you
verify the bytes have not been tampered with. With the [GitHub CLI]:

```sh
gh release verify --repo <user>/netbsd-pkg-repo <tag>
gh release verify-asset --repo <user>/netbsd-pkg-repo <tag> <package>.tgz
```

`verify` confirms the release has a valid attestation; `verify-asset` confirms a
local file matches the attested asset.

[landing page]: https://<user>.github.io/netbsd-pkg-repo/
[releases page]: https://github.com/<user>/netbsd-pkg-repo/releases
[GitHub CLI]: https://cli.github.com/

## How the build works

Everything runs inside the NetBSD/amd64 guest booted by the
[Cross-Platform Action], as the unprivileged `runner` user (which has
passwordless `sudo`). `scripts/cross-build.sh` orchestrates it:

1. **Cross toolchain + sysroot.** If the cached toolchain tarball is present it
   is extracted; otherwise `build.sh -U -m vax -O <objdir> tools` (~12 min) then
   `distribution` (~75 min) produce the cross gcc/binutils (`TOOLDIR`) and the
   target headers+libraries sysroot (`CROSS_DESTDIR`). `build.sh` runs
   **unprivileged** and with a clean default `MAKECONF` — the pkgsrc cross
   settings are deliberately kept out of it.
2. **pkgsrc.** The pinned quarterly tree is fetched with base `ftp(1)` (no
   git/curl needed) and extracted.
3. **Cross-build.** Each origin in `config/pkglist` is built with
   `make package BATCH=yes DEPENDS_TARGET=package-install`, using a dedicated
   pkgsrc `MAKECONF` (`$HOME/pkgsrc/mk.conf`) passed only on the pkgsrc make
   command lines. That `MAKECONF` sets the cross variables plus
   `SU_CMD=/usr/bin/sudo /bin/sh -c` so pkgsrc escalates for dependency
   installation via passwordless `sudo` (base `su` fails non-interactively).
4. **Publish.** The resulting vax `.tgz` and a generated `pkg_summary.gz` are
   copied into the workspace and pulled back to the runner. On a version-tag
   push the build job then creates a draft GitHub release from them, which
   becomes immutable once a maintainer publishes it.

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
cached and reused: later runs restore it and finish in minutes instead of hours.
The objdir is multi-GB and ~100k files, which is slow to rsync across the
guest/runner boundary, so it is moved as a **single tarball**
(`toolchain-cache/obj.tar`) under the workspace and persisted on the runner with
`actions/cache`, keyed on the target arch+version and the NetBSD `SRC_BRANCH`.
Bumping `SRC_BRANCH` invalidates the cache and rebuilds the toolchain.

## Adding things

All configuration is driven by plain-text lists. Add a line, then cut a release
by pushing a version tag (below) to rebuild the repository.

| File | Purpose |
|------|---------|
| `config/pkglist` | One pkgsrc origin per line (e.g. `net/rsync`) |
| `config/pkgsrc_branch` | The pinned pkgsrc quarterly branch to build from |

The set of NetBSD targets to build is the `matrix.include` list on the `build`
job in [`.github/workflows/build-and-deploy.yml`](.github/workflows/build-and-deploy.yml)
(each row is `arch` / `version` / `abi_dir` / `build_name`). Add a target by
adding a row there.

## Cutting a release

```sh
git tag v1.2.0
git push origin v1.2.0
```

This builds every target and creates a **draft** release per target (tagged
`<abi>--v1.2.0`). Review the drafts on the repository's releases page, then
**publish** each one. Publishing makes it immutable and refreshes the landing
page. Nothing is served to consumers until you publish.

## How the workflow is structured

The workflow has two independent entry points and two jobs:

1. **build** — runs on any push (a version tag `v*` or a plain branch) and on
   manual dispatch. One job per target in the build matrix, on `ubuntu-latest`:
   it restores the toolchain cache, boots a NetBSD/amd64 VM via the
   Cross-Platform Action (KVM-accelerated, `memory: 12G`, `cpu_count: 4`) and
   runs `scripts/cross-build.sh` inside it (see *How the build works*). The built
   package set (`.tgz` + `pkg_summary.gz`) is uploaded as an artifact. On a
   version-tag push (or manual dispatch) a final step then creates a **draft**
   release for that target (`scripts/deploy/create-release.sh`), tagged
   `<abi>--<version>`, with the packages as assets — created straight from the
   local package dir using `matrix.abi_dir`, so there is no artifact round-trip
   or second matrix. A plain branch push stops before that step: it validates
   the change without releasing.
2. **deploy** — runs on the separate `release: published` event. Regenerates the
   Pages landing page from the currently *published* releases
   (`scripts/deploy/generate-landing-page.sh`, read live via `gh`; drafts are
   excluded) and deploys it. Serialized via a `pages` concurrency group.

A manual `workflow_dispatch` (optionally with `mock_build`) also runs build +
draft-release, for exercising the pipeline without cutting a real version.

## Setup

Two one-time repository settings are required:

1. **Immutable releases** must be enabled (Settings → Code security, or the
   org-level setting). With it on, a release becomes immutable the moment it is
   **published** — assets locked, tag protected, attestation generated — with no
   extra workflow configuration. Drafts stay mutable until then. See the
   [immutable releases docs][immutable-releases].
2. **GitHub Pages** source set to **GitHub Actions** (Settings → Pages → Build
   and deployment source), for the landing page.

## License

See [LICENSE](LICENSE).
