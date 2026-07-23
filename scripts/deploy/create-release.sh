#!/bin/sh
# Publish one target's package set as a DRAFT GitHub release.
#
# The package set (every .tgz plus the generated pkg_summary.gz) becomes the
# release assets. The release is created as a draft so it can be reviewed before
# going live; a draft is mutable and invisible to consumers. When a maintainer
# publishes it, the repo/org "Immutable releases" setting makes it immutable at
# that moment -- assets locked, tag protected, signed release attestation
# generated -- and it becomes the artifact store consumers pin PKG_PATH to.
#
# Usage: create-release.sh <package-dir>
#
# Required env vars:
#   GH_TOKEN          token with contents:write (github.token in Actions)
#   ABI_DIR           target ABI, e.g. NetBSD-10.1-vax
#   VERSION           version to tag with, from the pushed tag, e.g. v1.2.3
#   GITHUB_REPOSITORY owner/repo (set by GitHub Actions)
#   GITHUB_SHA        commit to tag (set by GitHub Actions)

set -eu

pkgdir="${1:?usage: create-release.sh <package-dir>}"
: "${GH_TOKEN:?GH_TOKEN must be set}"
: "${ABI_DIR:?ABI_DIR must be set}"
: "${VERSION:?VERSION must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
: "${GITHUB_SHA:?GITHUB_SHA must be set}"

# Tag = <abi>--<version>. The `--` separator lets the landing page split the ABI
# (which itself contains single dashes) back out cleanly; the version comes from
# the pushed git tag, so one `v1.2.3` push produces one release per target
# (a single tag can back only one release, hence the per-ABI derived tags). The
# tag ref is only created by GitHub when the draft is published.
tag="${ABI_DIR}--${VERSION}"
pkg_path="https://github.com/${GITHUB_REPOSITORY}/releases/download/${tag}"

# Collect the assets, and name a real one in the verify example so the release
# notes are copy-paste runnable.
sample="<package>.tgz"
set --
for f in "$pkgdir"/*.tgz; do
    [ -e "$f" ] || continue
    [ "$sample" = "<package>.tgz" ] && sample=$(basename "$f")
    set -- "$@" "$f"
done
[ -e "$pkgdir/pkg_summary.gz" ] && set -- "$@" "$pkgdir/pkg_summary.gz"
[ "$#" -gt 0 ] || { echo "no packages found in $pkgdir" >&2; exit 1; }

# Build the release body in a file (--notes-file) rather than inline, so the
# markdown -- backticks, apostrophes, fenced code -- needs no shell escaping.
notes_file=$(mktemp)
trap 'rm -f "$notes_file"' EXIT
cat > "$notes_file" <<NOTES
Immutable binary pkgsrc packages for **${ABI_DIR}**.

Install on a matching NetBSD system:

\`\`\`sh
export PKG_PATH="${pkg_path}"
pkg_add bash sudo rsync
\`\`\`

Verify this release and an asset against GitHub's signed attestation:

\`\`\`sh
gh release verify --repo ${GITHUB_REPOSITORY} ${tag}
gh release verify-asset --repo ${GITHUB_REPOSITORY} ${tag} ${sample}
\`\`\`
NOTES

echo "Creating draft release $tag with $# assets"
gh release create "$tag" \
    --repo "$GITHUB_REPOSITORY" \
    --target "$GITHUB_SHA" \
    --title "$ABI_DIR $VERSION" \
    --notes-file "$notes_file" \
    --draft \
    "$@"
