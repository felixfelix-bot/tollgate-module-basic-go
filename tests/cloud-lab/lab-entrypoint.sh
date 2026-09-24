#!/bin/sh
# lab-entrypoint.sh — install this service's lab config, then exec the module.
#
# WHY THIS EXISTS
#
# The lab's inputs (config.json, install.json, dhcp.leases) used to arrive as
# bind mounts of files in the checkout, e.g.
#   volumes:
#     - ./configs/upstream-config.json:/etc/tollgate/config.json
# A bind source is resolved by the DOCKER DAEMON, not by the client, so that
# only works when the daemon can see the checkout. In an `act` job that reaches
# the host daemon it cannot: the checkout lives inside the act container, docker
# created an empty DIRECTORY at /etc/tollgate/config.json, and the module died
# with
#   level=fatal msg="Failed to create config manager"
#     error="failed to ensure default config: read /etc/tollgate/config.json:
#            is a directory"
# (ngit CI job cloud-lab, regression.yml, 2026-09-24).
#
# A build context, by contrast, travels WITH the build request, so the configs
# are baked into the image (Dockerfile.tollgate) and selected here per service.
# Same files, same contents, no assumption about where the daemon runs — and the
# container is built from the commit under test.
set -eu

CONFIGS=/opt/lab-configs
LAB_CONFIG="${LAB_CONFIG:-upstream-config.json}"
LAB_LEASES="${LAB_LEASES:-dhcp.leases}"

if [ ! -f "$CONFIGS/$LAB_CONFIG" ]; then
    echo "lab-entrypoint: no such config: $CONFIGS/$LAB_CONFIG (baked configs: $(ls "$CONFIGS" 2>/dev/null | tr '\n' ' '))" >&2
    exit 1
fi

mkdir -p /etc/tollgate
cp "$CONFIGS/$LAB_CONFIG" /etc/tollgate/config.json
cp "$CONFIGS/install.json" /etc/tollgate/install.json
if [ -f "$CONFIGS/$LAB_LEASES" ]; then
    cp "$CONFIGS/$LAB_LEASES" /tmp/dhcp.leases
fi

echo "lab-entrypoint: config=$LAB_CONFIG leases=$LAB_LEASES -> /etc/tollgate/config.json"
exec "$@"
