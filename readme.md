# NetBSD Package Repository

Binary NetBSD [pkgsrc] packages built for CPU architectures not covered by
the official NetBSD package mirrors (e.g. vax).

The packages are built **natively inside a full-system [SIMH] emulator**,
booted from the same prebuilt [netbsd-builder] disk image the
[Cross-Platform Action] publishes for NetBSD/vax, and published to GitHub
Pages on every push to `master`.

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
| qemu-user-static + `binmiscctl` | full-system SIMH |
| Cross-Platform Action FreeBSD VM | SIMH on the Ubuntu runner, driven over ssh |
| `pkg` + `repos/custom.conf` | `pkg_add` + `PKG_PATH` |

Full-system emulation is **slower** than qemu-user, so the 6-hour GitHub
Actions job limit is a real ceiling. The build caches progress between runs
(see *How it works*) so it converges across multiple runs.

[freebsd-pkg-repo]: https://github.com/cross-platform-actions/freebsd-pkg-repo

### Why not the action's `run:`?

The action *does* now support NetBSD/vax, and we reuse the disk image it
publishes. But we do **not** run the build through the action's `run:`
mechanism, because for vax it:

- runs commands as the unprivileged `runner` user with **no sudo** (NetBSD
  base has no `doas`/`sudo` either) — but building standard `/usr/pkg`
  packages needs root; and
- **rejects file synchronization** (the image has no `rsync`), so there is
  no built-in way to get the `.tgz` files back out.

Instead we boot SIMH ourselves and ssh in as **root** (the image enables
`PermitRootLogin` + password auth; root's password is `runner`). That makes
sudo irrelevant, and packages come out with plain **`scp`** — which *is* in
NetBSD base; only `rsync` is missing. The emulated MicroVAX 3900 is also
given its full **512 MB** (8× netbsd-builder's own 64 MB build cap), which
is what makes the heavy closure (openssl, perl) tractable.

## Status

⚠️ **Not yet proven.** The disk image and its URL are confirmed to exist,
but the end-to-end SIMH build (expect-driven boot, in-guest `make package`
of the full closure within the disk/time budget) has not been run green
yet.

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

Space-separated fields, one architecture per line:

```
<arch> <simh_binary> <disk_type>
```

| Field | Description | Example |
|-------|-------------|---------|
| `arch` | MACHINE_ARCH / pkgsrc arch; also the image arch name | `vax` |
| `simh_binary` | SIMH simulator that runs this arch | `vax` |
| `disk_type` | SIMH RQ0 disk type the image was built with | `RA92` |

Lines starting with `#` and blank lines are ignored.

## How it works

The workflow runs three jobs per push:

1. **generate-matrix** — reads `config/architectures` and `config/versions`
    and emits a JSON matrix (architecture × version).
2. **build** — one job per matrix entry, on `ubuntu-latest`. Builds SIMH from
    source, downloads and decompresses the action's published NetBSD disk
    image (raw RA92, `img.zst`), boots it in SIMH (an `expect` script sends
    `boot dua0` at the `>>>` firmware prompt) with a slirp NAT redirect (host
    `2222` → guest `10.0.2.15:22`), then over ssh **as root**: fetches the
    pinned pkgsrc tree and runs `make package` for every origin in
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
