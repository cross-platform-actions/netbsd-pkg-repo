#!/bin/sh
# Copy built packages out of the NetBSD/vax VM into the workspace, so they
# get cached and deployed. Runs ON THE LINUX RUNNER, after the in-guest
# build, reusing the ssh setup the Cross-Platform Action left behind (see
# build-packages.sh). Pulls the public package subset — the binary packages
# and the summary index — into $REPO_ROOT/packages/All.

set -eux

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HOST=root@cross_platform_actions_host
SCP="scp -O"

OUTPUT_DIR="$REPO_ROOT/packages"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/All"

# pkg_summary.gz is generated alongside the .tgz files in All/. Pulling
# All/ wholesale gives a self-contained pkg_add/pkgin repository.
$SCP "$HOST":'/usr/pkgsrc/packages/All/*' "$OUTPUT_DIR/All/" || true

echo "=== Collected packages ==="
ls -lR "$OUTPUT_DIR"
