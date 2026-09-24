#!/usr/bin/env bash
#
# MUTANT FIXTURE - fork-only CI vehicle branch. NEVER a PR to upstream.
#
# Replaces the built captive-portal bundle with one built from the PRE-#60 portal
# revision (6f599bb: the expired view was a dead end - its only action was
# window.location.reload(), labelled "Refresh Portal"), while leaving the
# provenance record honest:
#
#   packaging/build-inputs.json        .portal.commit   = the pinned (fixed) SHA
#   packaging/portal-build-inputs.json .portal_commit   = the pinned (fixed) SHA
#   packaging/portal-resolved.sha                        = the pinned (fixed) SHA
#
# That is the shape of the release regression this run exists to reproduce: the
# pin was correct, the committed tree was correct, every source-level guard was
# green - and the ARTIFACT still carried the older bundle. Measured on the pre15c
# APK: "a portal-SOURCE PR alone does NOT fix a shipped APK ... `build-inputs.json
# .portal.commit` is cosmetic, the committed bundle is what actually ships". A
# guard that reads the pin cannot see a stale bundle; only something that boots
# the shipped bytes can.
#
# Ordering is deliberate: this step runs AFTER
# `tests/packaging/assert-portal-bundle-contract.sh` in both workflows, so that
# guard inspects the honest pinned tree and the divergence is introduced
# downstream of the check - exactly where a real stale-vendoring slip happens
# (the guard passed, the packaging lane shipped something else). Every other
# job in the run therefore sees a tree it cannot fault.
#
# Usage: bash .github/scripts/mutant-prev60-swap.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PRE60="${PRE60_PORTAL_COMMIT:-6f599bb1983e57ae1ea2700c0acd903d1c68f09e}"
PIN="$(jq -r '.portal.commit' packaging/build-inputs.json)"
if [ "$PRE60" = "$PIN" ]; then
    echo "MUTANT ERROR: the mutant ref equals the pin ($PIN) - nothing to swap" >&2
    exit 1
fi

# portal-build.sh rewrites two provenance files at the repository root. Keep
# them describing the PIN: an honest provenance record is the whole point.
KEEP="$(mktemp -d)"
cp packaging/portal-build-inputs.json "$KEEP/" 2>/dev/null || true
cp packaging/portal-resolved.sha "$KEEP/" 2>/dev/null || true

OLD_OUT="$(mktemp -d)"
# Reuse the repo's own portal build (same npm ci + build + staging semantics),
# just pointed at the older revision. PORTAL_ALLOW_FLOATING=1 is the escape
# hatch the script documents for a non-manifest ref.
PORTAL_ALLOW_FLOATING=1 \
PORTAL_REF="$PRE60" \
PORTAL_DIR=/var/tmp/tg-portal-prev60 \
OUTPUT_DIR="$OLD_OUT/guest" \
ADMIN_OUTPUT_DIR="$OLD_OUT/admin" \
    bash packaging/portal-build.sh

cp "$KEEP/portal-build-inputs.json" packaging/portal-build-inputs.json 2>/dev/null || true
cp "$KEEP/portal-resolved.sha"      packaging/portal-resolved.sha      2>/dev/null || true

# Swap the guest SPA and the admin board over the pinned staging tree.
rm -rf packaging/files/tollgate-captive-portal-site packaging/files/tollgate-admin
mkdir -p packaging/files/tollgate-captive-portal-site packaging/files/tollgate-admin
cp -r "$OLD_OUT/guest/." packaging/files/tollgate-captive-portal-site/
cp -r "$OLD_OUT/admin/." packaging/files/tollgate-admin/

echo "MUTANT: the artifact bundle is now built from $PRE60 while the pin says $PIN"
echo "  pin (build-inputs.json)          : $(jq -r '.portal.commit' packaging/build-inputs.json)"
echo "  resolved (portal-build-inputs)   : $(jq -r '.portal_commit' packaging/portal-build-inputs.json)"
echo "  resolved (portal-resolved.sha)   : $(cat packaging/portal-resolved.sha)"
echo "  guest entry                      : $(ls packaging/files/tollgate-captive-portal-site/assets/index-*.js 2>/dev/null | head -1)"
echo "  #60 CTA key in the shipped JS    : session_expired_buy_more=$(grep -o -F -- 'session_expired_buy_more' packaging/files/tollgate-captive-portal-site/assets/*.js 2>/dev/null | wc -l)"
echo "  pre-#60 dead-end key still there : session_expired_reconnect=$(grep -o -F -- 'session_expired_reconnect' packaging/files/tollgate-captive-portal-site/assets/*.js 2>/dev/null | wc -l)"
