#!/bin/sh
# Generate a JSON matrix from config/architectures and config/versions
# for use with GitHub Actions' fromJSON() matrix strategy.
#
# Runs on the Linux runner, so must be plain sh-compatible.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ARCH_FILE="$REPO_ROOT/config/architectures"
VERSIONS_FILE="$REPO_ROOT/config/versions"

first=true
printf '['

while IFS= read -r version || [ -n "$version" ]; do
    # Skip empty lines and comments
    case "$version" in ''|\#*) continue ;; esac

    while IFS= read -r arch || [ -n "$arch" ]; do
        # Skip empty lines and comments; trim surrounding whitespace
        arch=$(printf '%s' "$arch" | tr -d '[:space:]')
        case "$arch" in ''|\#*) continue ;; esac

        # ABI directory, matching netbsd-builder's image naming, e.g.
        # NetBSD-10.1-vax. This is the published per-target subtree under
        # the Pages site and what the consumer points PKG_PATH at.
        abi_dir="NetBSD-${version}-${arch}"

        # Short, filesystem-friendly name for cache keys and logs, e.g.
        # vax-101.
        version_compact=$(echo "$version" | tr -d '.')
        build_name="${arch}-${version_compact}"

        if [ "$first" = true ]; then
            first=false
        else
            printf ','
        fi

        printf '{"arch":"%s","version":"%s","abi_dir":"%s","build_name":"%s"}' \
            "$arch" "$version" "$abi_dir" "$build_name"

    done < "$ARCH_FILE"
done < "$VERSIONS_FILE"

printf ']'
