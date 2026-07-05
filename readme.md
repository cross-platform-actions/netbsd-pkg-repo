# NetBSD Package Repository

Binary NetBSD [pkgsrc] packages built for CPU architectures not covered by
the official NetBSD package mirrors (e.g. vax).

The packages are built **natively inside the NetBSD/vax VM** the
[Cross-Platform Action] boots (a full-system [SIMH] MicroVAX 3900), from the
prebuilt [netbsd-builder] disk image, and published to GitHub Pages on every
push to `master`.

[Cross-Platform Action]: https://github.com/cross-platform-actions/action

[pkgsrc]: https://www.pkgsrc.org/
[SIMH]: https://opensimh.org/
[netbsd-builder]: https://github.com/cross-platform-actions/netbsd-builder

## Why not the FreeBSD approach?

The sibling [freebsd-pkg-repo] builds with poudriere + **QEMU user-mode
emulation** (`binmiscctl`), running the host natively and only emulating
target binaries — fast (5–10× slowdown). That is impossible here: **there is
no qemu-user backend for vax**, only full-system SIMH emulation. So this repo
keeps freebsd-pkg-repo's structure (config-driven lists, matrix → build →
deploy, GitHub Pages) but replaces the entire build engine:

| FreeBSD | NetBSD (here) |
|---|---|
| poudriere | `bmake package` (pkgsrc) |
| qemu-user-static + `binmiscctl` | full-system SIMH (via the action) |
| Cross-Platform Action FreeBSD VM | Cross-Platform Action NetBSD/vax VM |
| `pkg` + `repos/custom.conf` | `pkg_add` + `PKG_PATH` |

Full-system emulation is **slower** than qemu-user, so the 6-hour GitHub
Actions job limit is a real ceiling. The build caches progress between runs
(see *How it works*) so it converges across multiple runs.

[freebsd-pkg-repo]: https://github.com/cross-platform-actions/freebsd-pkg-repo

### How the build reaches the VM

The action boots the VM but we do **not** run the build through its `run:`
mechanism, because for vax that runs as the unprivileged `runner` user with
**no sudo** (NetBSD base has no `doas`/`sudo` either) and **rejects file
synchronization** (the image has no `rsync`) — yet building standard
`/usr/pkg` packages needs root, and the `.tgz` files need a way back out.

Instead we boot the VM with `shutdown_vm: false` and reuse the ssh setup the
action leaves behind for later steps: an `/etc/hosts` entry and
`~/.ssh/config` alias for `cross_platform_actions_host`, plus an
`SSH_ASKPASS` helper that supplies the image password. The alias fixes only
host/port/auth-method — not the user — and the image password is also
**root's** password (`runner`, and `PermitRootLogin` is enabled), so a build
step just does:

```sh
ssh  root@cross_platform_actions_host '…build…'
scp  -O 'root@cross_platform_actions_host:/usr/pkgsrc/packages/All/*' packages/All/
```

That yields standard `/usr/pkg` packages and pulls them out with plain
**`scp`** — which *is* in NetBSD base; only `rsync` is missing. The MicroVAX
3900 is given its full **512 MB** (8× netbsd-builder's own 64 MB build cap),
which is what makes the heavy closure (openssl, perl) tractable.

### Disk layout

The 1.5 GB RA92 root image can't hold the pkgsrc tree (>1 GB extracted) plus
build work, and the emulated MicroVAX 3900's MSCP controller caps **any
single disk at 2 GB** — a 12 GB disk like the QEMU-based ports is impossible.
So the action attaches **two 2 GB scratch disks**, which `remote-build.sh`
`newfs`es and mounts inside the guest:

| Disk | Mount | Holds |
|------|-------|-------|
| ra0 (root, 1.5 GB) | `/` | base + comp + installed deps (`/usr/pkg`) |
| ra1 (scratch, 2 GB) | `/usr/pkgsrc` | the pkgsrc tree + `.tgz` output |
| ra2 (scratch, 2 GB) | `/wrk` | `WRKOBJDIR` (build work; freed after each origin) |

## Status

⚠️ **Bootstrap phase — not yet proven.** The action is pinned to its
`worktree-vax` branch until NetBSD/vax support is released; the end-to-end
build (in-guest `make package` of the full closure within the disk/time
budget) has not been run green yet.

## Supported targets

| Architecture | NetBSD version |
|--------------|----------------|
| vax          | 10.1           |

## Using the repository

On a NetBSD vax system, point `PKG_PATH` at the target's `All/` directory and
install with the base `pkg_add` (no pkgin bootstrap required):

```sh
export PKG_PATH="https://<user>.github.io/netbsd-pkg-repo/NetBSD-10.1-vax/All"
pkg_add bash sudo curl rsync
```

Replace `<user>` with the GitHub user or organization hosting this repository.

## Adding things

All configuration is driven by plain-text lists. Add a line, push to
`master`, and the workflow rebuilds the repository.

| File | Purpose |
|------|---------|
| `config/pkglist` | One pkgsrc origin per line (e.g. `www/curl`) |
| `config/architectures` | One target architecture per line (see below) |
| `config/versions` | One NetBSD version per line (e.g. `10.1`) |
| `config/pkgsrc_branch` | The pinned pkgsrc quarterly branch to build from |

### `config/architectures` format

One architecture per line — the value passed to the action's `architecture`
input (e.g. `vax`). Lines starting with `#` and blank lines are ignored.

## How it works

The workflow runs three jobs per push:

1. **generate-matrix** — reads `config/architectures` and `config/versions`
    and emits a JSON matrix (architecture × version).
2. **build** — one job per matrix entry, on `ubuntu-latest`. A `Start VM`
    step boots the NetBSD/vax VM via the Cross-Platform Action
    (`sync_files: false`, `shutdown_vm: false`, `memory: 512M`); the build
    step then, over ssh **as root** to `cross_platform_actions_host`: mounts
    the two scratch disks (see *Disk layout*), fetches the pinned pkgsrc tree
    onto `/usr/pkgsrc` and runs `make package` for every origin in
    `config/pkglist`. Built packages are pulled back out with `scp` and
    uploaded as an artifact.
3. **deploy** — merges all artifacts into one tree
    (`NetBSD-<version>-<arch>/All/...`), generates a landing page and
    directory indexes, and deploys to GitHub Pages.

### Resuming across the 6-hour limit

Because full-system emulation is slow, a single run may not finish the whole
package set. Each run:

- **restores** the previous run's `packages/` from the Actions cache,
- **seeds** them into the guest's `/usr/pkgsrc/packages/All` before building
  (so `make package` skips anything already built and up to date), and
- **saves** the (grown) `packages/` on completion — even on timeout or
  failure (`always()`).

Successive runs therefore converge to a complete build. The heaviest part of
the closure is `curl → openssl → perl`; expect several runs before it's
complete.

## Setup

GitHub Pages must be enabled with source set to **GitHub Actions**
(Settings → Pages → Build and deployment source).

## License

See [LICENSE](LICENSE).
