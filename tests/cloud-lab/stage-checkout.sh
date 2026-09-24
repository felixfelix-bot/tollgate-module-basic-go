#!/usr/bin/env bash
# stage-checkout.sh — make this checkout visible to the docker daemon, when it
# is not.
#
# WHY
#
# The lab's client service bind-mounts `.` (this directory) at /tests, and the
# module services used to bind-mount ./configs/*.json at /etc/tollgate. A bind
# source is resolved by the DOCKER DAEMON, not by the CLI: on a laptop they share
# a filesystem and the mount is the live tree, but in an ngit CI `act` job the
# CLI runs inside the act container while the daemon is the host's — so a FILE
# bind arrived as an empty directory (the module died with "read
# /etc/tollgate/config.json: is a directory") and a DIRECTORY bind arrives as an
# empty /tests (no tests at all). The config files are now baked into the image
# (lab-entrypoint.sh); this script covers the directory case.
#
# WHAT IT DOES
#
# 1. probes whether the daemon can read the mount source;
# 2. if it cannot, streams this directory into the daemon's own view of that
#    path with `tar` over stdin and `docker run -i` — the bytes travel with the
#    request, so no shared filesystem is involved;
# 3. re-probes and reports. Exit 0 means the client container will see the tests.
#
# The probe compares a CONTENT DIGEST, not mere existence (cross-family review
# round 1, finding 3): a stale or unrelated tree at the same path must not be
# mistaken for this checkout, and it must not be silently overwritten either. So:
# digest equal ⇒ nothing to do; digest absent ⇒ stage; digest present but
# different ⇒ REFUSE (exit 6), because that path belongs to something else.
#
# The destination is the same path the client service binds, by construction:
# the daemon's view of <target>. Locally the probe succeeds and this is a no-op.
#
# Usage:
#   bash stage-checkout.sh                    # stage this dir if the daemon cannot see it
#   bash stage-checkout.sh --force            # stage even when it can (used by tests)
#   bash stage-checkout.sh --target DIR       # stage into DIR instead (tests; default: this dir)
#
# Exit codes: 0 staged/visible (or nothing to do) | 3 no docker daemon
#             | 4 the stream failed | 5 staged but the daemon still cannot read it
#             | 6 the daemon has a DIFFERENT checkout at the target (refusing to clobber)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE"
FORCE=0
STAGE_IMAGE="${STAGE_IMAGE:-alpine:3.20}"

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="${2:?--target needs a directory}"; shift 2 ;;
        --force)  FORCE=1; shift ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "STAGE no-docker: no usable docker daemon; cannot stage" >&2
    exit 3
fi

# The marker file is the identity of the tree at $TARGET: its digest is what
# distinguishes "this checkout" from "some other directory that happens to be
# at the same path". A path the daemon does not have appears as an empty
# directory (docker creates it), so the digest comes back empty.
MARKER=docker-compose.yml
LOCAL_DIGEST="$(sha256sum "$HERE/$MARKER" | awk '{print $1}')"

daemon_digest() {  # digest the DAEMON computes for $TARGET/$MARKER, or empty
    docker run --rm -v "${1}:/probe:ro" "$STAGE_IMAGE" \
        sh -c "sha256sum /probe/$MARKER 2>/dev/null | cut -d' ' -f1" 2>/dev/null | tr -d '\r\n'
}

if [ "$FORCE" != "1" ]; then
    SEEN="$(daemon_digest "$TARGET")"
    if [ "$SEEN" = "$LOCAL_DIGEST" ]; then
        echo "STAGE visible: the docker daemon already reads THIS checkout at $TARGET (digest matches, nothing to do)"
        exit 0
    fi
    if [ -n "$SEEN" ]; then
        echo "STAGE refusing: $TARGET on the daemon holds a DIFFERENT $MARKER (digest $SEEN, this checkout is $LOCAL_DIGEST)." >&2
        echo "                Staging would overwrite another checkout's tree. Use a different path (COMPOSE project/checkout) or clean it up." >&2
        exit 6
    fi
fi

if ! tar -C "$HERE" -cf - . 2>/dev/null | \
     docker run --rm -i -v "${TARGET}:/stage" "$STAGE_IMAGE" tar -C /stage -xf - >/dev/null 2>&1; then
    echo "STAGE failed: could not stream $HERE into the daemon's $TARGET" >&2
    exit 4
fi

AFTER="$(daemon_digest "$TARGET")"
if [ "$AFTER" = "$LOCAL_DIGEST" ]; then
    echo "STAGE staged: $HERE -> the daemon's ${TARGET} ($(find "$HERE" -maxdepth 1 -name '*.py' | wc -l) python test file(s), digest verified)"
    exit 0
fi

echo "STAGE unreadable: staged into ${TARGET} but the daemon reports digest '${AFTER}' (wanted $LOCAL_DIGEST)" >&2
exit 5
