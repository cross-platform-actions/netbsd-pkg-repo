#!/bin/sh
# Copy built packages out of the SIMH guest into the workspace, so they get
# cached and deployed. Runs ON THE LINUX RUNNER, after the in-guest build.
#
# The guest is reachable on port 2222 (set up by build-packages.sh). We pull
# the public package subset — the binary packages and the summary index —
# into $REPO_ROOT/packages/All.

set -eux

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10"
SCP="sshpass -p runner scp -P 2222 $SSH_OPTS"

OUTPUT_DIR="$REPO_ROOT/packages"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/All"

# pkg_summary.gz is generated alongside the .tgz files in All/. Pulling
# All/ wholesale gives a self-contained pkg_add/pkgin repository.
$SCP root@127.0.0.1:'/usr/pkgsrc/packages/All/*' "$OUTPUT_DIR/All/" || true

echo "=== Collected packages ==="
ls -lR "$OUTPUT_DIR"
