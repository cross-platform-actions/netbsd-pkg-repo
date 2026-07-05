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

# Stage the restored cache into the guest so `make package` skips anything
# already built — this is what lets a progressive run resume where a
# previous timed-out run stopped. It goes to /tmp/seed on root, because
# /usr/pkgsrc doesn't exist yet: remote-build.sh mounts the scratch disk
# there first, then copies the seed onto it.
if [ -d "$REPO_ROOT/packages/All" ] && \
   [ -n "$(ls -A "$REPO_ROOT/packages/All" 2>/dev/null)" ]; then
    echo "Staging cached packages into the guest"
    ssh "$HOST" 'mkdir -p /tmp/seed'
    $SCP "$REPO_ROOT"/packages/All/*.tgz "$HOST":/tmp/seed/ || true
fi

# Copy the build inputs in and run the in-guest build as root. Wrap it in
# timeout(1) so we stop well before the GitHub Actions step timeout (300
# min), leaving room to collect whatever was built. Without this, a step
# timeout would kill the run before collect-packages.sh, losing all progress
# from this run. -k 60 escalates to SIGKILL if ssh ignores SIGTERM.
#
# Capture the exit status instead of swallowing it: remote-build.sh exits
# non-zero on a fatal setup error (e.g. pkgsrc fetch failed), on timeout, or
# when not every requested package built. We still collect whatever exists
# (so partial progress is cached for the next run), but then propagate the
# failure so the job goes red and the deploy is skipped — an incomplete or
# empty repository must never be published.
$SCP "$SCRIPT_DIR/remote-build.sh" "$REPO_ROOT/config/pkglist" "$HOST":/tmp/
build_status=0
timeout -k 60 270m \
    ssh "$HOST" "PKGSRC_BRANCH='$PKGSRC_BRANCH' PKGLIST=/tmp/pkglist \
        sh /tmp/remote-build.sh" \
    || build_status=$?

# Collect built packages into the workspace for caching + deploy. Runs
# regardless of the build status so partial progress survives a
# timeout/failure and can be re-seeded on the next run.
sh "$SCRIPT_DIR/collect-packages.sh" \
    || echo "collect-packages.sh failed (exit $?)"

if [ "$build_status" -ne 0 ]; then
    echo "Build did not complete successfully (exit $build_status); " \
        "not deploying." >&2
    exit "$build_status"
fi
