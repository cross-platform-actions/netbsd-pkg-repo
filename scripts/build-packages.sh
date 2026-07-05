#!/bin/sh
# Build orchestration. Runs ON THE LINUX RUNNER, in a step AFTER the
# Cross-Platform Action's "Start VM" step has booted the NetBSD/vax VM
# (SIMH MicroVAX 3900) and left it running (shutdown_vm: false).
#
# We do NOT drive the build through the action's own `run:` mechanism: for
# vax it runs as the unprivileged `runner` user with no sudo (NetBSD base
# has no doas/sudo either), and it rejects file synchronization (the image
# lacks rsync). Instead we reuse the ssh setup the action leaves behind for
# subsequent steps:
#
#   - `/etc/hosts` has `127.0.0.1 cross_platform_actions_host`
#   - `~/.ssh/config` has a matching Host alias (NAT port, password auth)
#   - `SSH_ASKPASS` (+ SSH_ASKPASS_REQUIRE=force) is exported, supplying the
#     image password non-interactively
#
# The alias fixes only host/port/auth-method, not the user, and the image
# password is also root's password, so we ssh in as root to build standard
# /usr/pkg packages and scp them out. scp is in NetBSD base (only rsync is
# missing), so no sudo and no file-sync are needed.

set -eux

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PKGSRC_BRANCH="$(grep -v '^[[:space:]]*#' "$REPO_ROOT/config/pkgsrc_branch" \
    | grep -v '^[[:space:]]*$' | head -n1)"

HOST=root@cross_platform_actions_host
# -O forces the legacy scp transfer protocol, so we don't depend on the
# image's sshd having the sftp subsystem enabled.
SCP="scp -O"

# Seed the guest package dir from the restored cache so `make package` skips
# anything already built and up to date — this is what lets a progressive
# run resume where a previous timed-out run stopped.
if [ -d "$REPO_ROOT/packages/All" ] && \
   [ -n "$(ls -A "$REPO_ROOT/packages/All" 2>/dev/null)" ]; then
    echo "Seeding guest package dir from cache"
    ssh "$HOST" 'mkdir -p /usr/pkgsrc/packages/All'
    $SCP "$REPO_ROOT"/packages/All/*.tgz "$HOST":/usr/pkgsrc/packages/All/ || true
fi

# Copy the build inputs in and run the in-guest build as root. Wrap it in
# timeout(1) so we stop well before the GitHub Actions step timeout (300
# min), leaving room to collect whatever was built. Without this, a step
# timeout would kill the run before collect-packages.sh, losing all progress
# from this run. -k 60 escalates to SIGKILL if ssh ignores SIGTERM; `|| echo`
# keeps `set -e` from aborting so we always fall through to collect.
$SCP "$SCRIPT_DIR/remote-build.sh" "$REPO_ROOT/config/pkglist" "$HOST":/tmp/
timeout -k 60 270m \
    ssh "$HOST" "PKGSRC_BRANCH='$PKGSRC_BRANCH' PKGLIST=/tmp/pkglist \
        sh /tmp/remote-build.sh" \
    || echo "remote-build.sh did not complete normally (exit $?)"

# Collect built packages into the workspace for caching + deploy. Runs
# unconditionally so partial progress survives a timeout/failure.
sh "$SCRIPT_DIR/collect-packages.sh" \
    || echo "collect-packages.sh failed (exit $?)"
