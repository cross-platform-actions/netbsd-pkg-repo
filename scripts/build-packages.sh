#!/bin/sh
# Main build orchestration script. Runs ON THE LINUX RUNNER.
#
# Unlike the FreeBSD repo — which runs poudriere + qemu-user-static inside a
# FreeBSD VM via Cross-Platform Action — there is no qemu-user backend for
# these CPUs, so the build happens inside a full-system SIMH emulator booted
# from a prebuilt NetBSD disk image. We drive it over ssh (port 2222 ->
# guest 10.0.2.15:22, the slirp NAT redirect set up in setup-simh.sh).
#
# Required environment variables (from the GitHub Actions matrix + workflow):
#   ARCH, VERSION, SIMH_BINARY, DISK_TYPE, IMAGE_BASE_URL
#
# The guest is the netbsd-builder artifact: sshd enabled, root password
# "vagrant", a passwordless secondary user. We log in as root (needed to
# write /usr/pkgsrc) with sshpass.

set -eux

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SIMH_DIR="$REPO_ROOT/.simh"

PKGSRC_BRANCH="$(grep -v '^[[:space:]]*#' "$REPO_ROOT/config/pkgsrc_branch" \
    | grep -v '^[[:space:]]*$' | head -n1)"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -o ServerAliveInterval=30"
SSH="sshpass -p vagrant ssh -p 2222 $SSH_OPTS root@127.0.0.1"
SCP="sshpass -p vagrant scp -P 2222 $SSH_OPTS"

# Step 1: build SIMH, fetch the image, write the boot command file.
sh "$SCRIPT_DIR/setup-simh.sh"

# Step 2: boot the guest in the background, logging the console.
"$SIMH_DIR/$SIMH_BINARY" "$SIMH_DIR/boot.ini" > "$SIMH_DIR/console.log" 2>&1 &
SIMH_PID=$!
# Best-effort console halt + simulator kill on exit.
trap '$SSH "halt -p" || true; kill "$SIMH_PID" 2>/dev/null || true' EXIT

# Step 3: wait for sshd in the guest. A cold vax boot under emulation is
# slow, so allow generous time.
echo "Waiting for ssh in the guest..."
i=0
until $SSH true 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 120 ]; then    # 120 * 10s = 20 min
        echo "Guest never became reachable over ssh" >&2
        tail -n 50 "$SIMH_DIR/console.log" >&2 || true
        exit 1
    fi
    sleep 10
done

# Step 4: seed the guest's package dir from the restored cache so
# `make package` skips anything already built — this is what lets a
# progressive run resume where a previous timed-out run stopped.
if [ -d "$REPO_ROOT/packages/All" ] && \
   [ -n "$(ls -A "$REPO_ROOT/packages/All" 2>/dev/null)" ]; then
    echo "Seeding guest package dir from cache"
    $SSH "mkdir -p /usr/pkgsrc/packages/All"
    $SCP "$REPO_ROOT"/packages/All/*.tgz root@127.0.0.1:/usr/pkgsrc/packages/All/ \
        || true
fi

# Step 5: copy the build inputs in and run the in-guest build.
$SCP "$SCRIPT_DIR/remote-build.sh" "$REPO_ROOT/config/pkglist" \
    root@127.0.0.1:/tmp/
$SSH "PKGSRC_BRANCH='$PKGSRC_BRANCH' PKGLIST=/tmp/pkglist \
    sh /tmp/remote-build.sh" \
    || echo "remote-build.sh did not complete normally (exit $?)"

# Step 6: collect built packages into the workspace for caching + deploy.
# Runs unconditionally so partial progress survives a timeout/failure.
sh "$SCRIPT_DIR/collect-packages.sh" \
    || echo "collect-packages.sh failed (exit $?)"
