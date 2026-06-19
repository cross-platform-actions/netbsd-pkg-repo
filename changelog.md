# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- Initial scaffold
- Build NetBSD binary pkgsrc packages for architectures with no official
    binary mirror (starting with vax), natively inside a full-system SIMH
    emulator booted from a netbsd-builder disk image
- Build targets `bash`, `sudo`, `curl` and `rsync` (with dependencies)
- Host the resulting pkg_add/pkgin repository on GitHub Pages
- Automate builds with GitHub Actions; drive the SIMH guest over ssh
- Configurable build matrix via plain-text lists: `config/architectures`,
    `config/versions`, `config/pkglist` and `config/pkgsrc_branch`
- Resume across the 6-hour job limit by caching and re-seeding partially
    built packages between runs
- Target NetBSD 10.1 vax packages

[Unreleased]: https://github.com/cross-platform-actions/netbsd-pkg-repo/commits/master
