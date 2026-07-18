# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- Initial scaffold
- Build NetBSD binary pkgsrc packages for architectures with no official
    binary mirror (starting with vax) by **cross-compiling on a NetBSD/amd64
    host** booted by the Cross-Platform Action, using a NetBSD `build.sh`
    cross toolchain + sysroot and pkgsrc `USE_CROSS_COMPILE=yes`
- Build targets `bash`, `sudo` and `rsync` (with dependencies)
- Host the resulting pkg_add/pkgin repository on GitHub Pages
- Automate builds with GitHub Actions; the in-guest cross build is driven by
    `scripts/cross-build.sh`, which escalates dependency installs via
    passwordless `sudo` (`SU_CMD`) and scopes the pkgsrc cross `MAKECONF` to
    the pkgsrc make invocations only (keeping `build.sh` on a clean default)
- Cache the expensive (~90 min) `build.sh` cross toolchain + sysroot as a
    single tarball keyed on the NetBSD src branch, so later runs restore it
    and finish in minutes
- Configurable packages and pkgsrc branch via plain-text lists
    (`config/pkglist`, `config/pkgsrc_branch`); the build target matrix
    (arch × version) is defined inline on the workflow's `build` job
- Gate the GitHub Pages deploy to `master`; branch pushes build and upload
    artifacts but do not deploy
- Target NetBSD 10.1 vax packages

### Changed
- Replace the emulated-vax build engine (full-system SIMH MicroVAX 3900,
    ssh-as-root, two `newfs`ed scratch disks, 330-min timeout, `pkg_add`
    resume, rsync openssl-strip patch) with cross-compilation on NetBSD/amd64.
    Cross-compiling builds perl/openssl's build tools natively, removing the
    6-hour-limit blocker that made the emulated build infeasible

[Unreleased]: https://github.com/cross-platform-actions/netbsd-pkg-repo/commits/master
