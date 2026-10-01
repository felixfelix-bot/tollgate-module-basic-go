#!/usr/bin/env bash
# Offline proof that tests/packaging/assert-artifact-contents.sh catches a STALE
# guest portal bundle inside a built package — and that it decides from the
# package bytes, not from the portal pin.
#
# The checker's nftables half already has suites that hand it a real .ipk built
# from the recipe's own install lines (tests/packaging/admin-board-not-guest-
# reachable_test.sh, tests/packaging/luci-not-guest-reachable_test.sh). This
# covers the portal-marker half the same way. The two artifacts here are built
# from synthetic assets under tmpdirs, so the test needs neither node nor the
# portal clone: what is under test is the checker's SENSITIVITY to a stale
# bundle, not the portal build itself (that is packaging/portal-build.sh's job,
# and assert-portal-bundle-contract.sh guards the pin).
#
# The failure class, measured on real builds of both portal revisions:
#
#   staged guest bundle          session_expired_buy_more   session_expired_reconnect
#   pinned (post-#60) portal      1                          0
#   pre-#60 portal (dead end)     0                          1
#
# Nothing that reads packaging/build-inputs.json can see a stale bundle: the
# pin was honest in the regression that reached a router and every source-level
# guard was green (fork PR felixfelix-bot/tollgate-module-basic-go#10). Hence
# assertion 4 below: the checker must not consult the pin at all.
#
# Usage: bash tests/packaging/stale-portal-bundle_test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

CHECKER="tests/packaging/assert-artifact-contents.sh"
NFT_SRC="packaging/files/etc/nftables.d"
GUEST_REL="etc/tollgate/tollgate-captive-portal-site"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Build a real .ipk whose payload carries the nftables ruleset the checker
# insists on plus a synthetic guest entry asset with the requested marker
# counts. Both markers are emitted as string literals, which is what survives
# minification; the counts are the only thing the checker reads.
build_pkg() {  # $1 = output .ipk   $2 = buy_more copies   $3 = reconnect copies
    _out=$1
    _buy=$2
    _reconnect=$3
    _payload="$(mktemp -d "$WORK/payload.XXXXXX")"
    mkdir -p "$_payload/etc/nftables.d" "$_payload/$GUEST_REL/assets"
    cp "$NFT_SRC"/*.nft "$_payload/etc/nftables.d/"
    {
        printf 'var a=1;'
        _i=0
        while [ "$_i" -lt "$_buy" ]; do
            printf 't("session_expired_buy_more");'
            _i=$((_i + 1))
        done
        _i=0
        while [ "$_i" -lt "$_reconnect" ]; do
            printf 't("session_expired_reconnect");'
            _i=$((_i + 1))
        done
        printf '\n'
    } > "$_payload/$GUEST_REL/assets/index-test.js"
    env PKG_NAME="tollgate-wrt" PKG_VERSION="0.0.0-test" ARCH="aarch64_cortex-a53" \
        MAINTAINER="TollGate <tollgate@tollgate.me>" LICENSE="GPL-3.0-only" \
        sh packaging/build-ipk.sh "$_payload" "$_out" >/dev/null 2>&1
    [ -f "$_out" ]
}

echo "== the checker reads the packaged guest bundle"
FIXED="$WORK/fixed.ipk"
STALE="$WORK/stale.ipk"
if ! build_pkg "$FIXED" 1 0; then
    bad "could not build the pinned-shaped fixture .ipk (needs packaging/build-ipk.sh, tar, gzip)"
elif ! build_pkg "$STALE" 0 1; then
    bad "could not build the stale-shaped fixture .ipk (needs packaging/build-ipk.sh, tar, gzip)"
else
    ok "built both fixture packages (fixed: buy_more=1/reconnect=0, stale: buy_more=0/reconnect=1)"

    # ---------------------------------------------------------- 1. GREEN
    fixed_out="$(bash "$CHECKER" "$FIXED" 2>&1)"
    fixed_rc=$?
    if [ "$fixed_rc" = 0 ]; then
        ok "checker accepts a package carrying the #60 renewal CTA"
    else
        bad "checker rejected the #60-shaped package (rc=$fixed_rc)"
        printf '%s\n' "$fixed_out" | sed 's/^/       /'
    fi
    if printf '%s' "$fixed_out" | grep -q "session_expired_buy_more  (want >= 1) : 1"; then
        ok "checker reports the renewal CTA it counted (buy_more=1)"
    else
        bad "checker did not report buy_more=1 on the #60-shaped package"
    fi

    # ------------------------------------------------------------ 2. RED
    stale_out="$(bash "$CHECKER" "$STALE" 2>&1)"
    stale_rc=$?
    if [ "$stale_rc" != 0 ]; then
        ok "checker REJECTS a package carrying the pre-#60 dead-end bundle (rc=$stale_rc)"
    else
        bad "checker ACCEPTED a stale guest bundle — the #60 markers are not asserted"
    fi
    if printf '%s' "$stale_out" | grep -q "the packaged guest portal is not the #60 revision"; then
        ok "checker says which invariant failed (stale portal bundle)"
    else
        bad "checker failed the stale package without naming the portal bundle"
    fi
    if printf '%s' "$stale_out" | grep -q "session_expired_reconnect (want == 0) : 1"; then
        ok "checker reports the dead-end label it counted (reconnect=1)"
    else
        bad "checker did not report reconnect=1 on the stale package"
    fi

    # The failure must be attributable to the portal half, not a side effect of
    # the fixture missing something the nftables half needs.
    if printf '%s' "$stale_out" | grep -q "ok   etc/nftables.d/30-backend-firewall.nft"; then
        ok "the nftables half of the checker still passed on the rejected package"
    else
        bad "the stale package failed before the nftables half was satisfied (checker output not attributable)"
    fi
fi

# ------------------------------------------------ 3. what "not evaluated" means
# A packaging row that ships no guest bundle at all is reported, not failed:
# such a row cannot ship a stale bundle, and this checker's runtime-set report
# already names that divergence as its own defect.
NOGUEST="$WORK/noguest.ipk"
_payload="$(mktemp -d "$WORK/payload.XXXXXX")"
mkdir -p "$_payload/etc/nftables.d" "$_payload/etc/tollgate/ecash"
cp "$NFT_SRC"/*.nft "$_payload/etc/nftables.d/"
if env PKG_NAME="tollgate-wrt" PKG_VERSION="0.0.0-test" ARCH="aarch64_cortex-a53" \
       MAINTAINER="TollGate <tollgate@tollgate.me>" LICENSE="GPL-3.0-only" \
       sh packaging/build-ipk.sh "$_payload" "$NOGUEST" >/dev/null 2>&1 && [ -f "$NOGUEST" ]; then
    noguest_out="$(bash "$CHECKER" "$NOGUEST" 2>&1)"
    noguest_rc=$?
    if [ "$noguest_rc" = 0 ]; then
        ok "checker does not fail a packaging path that ships no guest bundle"
    else
        bad "checker failed a package with no guest bundle (rc=$noguest_rc)"
    fi
    if printf '%s' "$noguest_out" | grep -q "not evaluated: this packaging path ships no $GUEST_REL/assets"; then
        ok "checker says out loud that the portal half was not evaluated there"
    else
        bad "checker was silent about skipping the portal half on a bundle-less package"
    fi
else
    bad "could not build the bundle-less fixture .ipk"
fi

# ------------------------------------------------- 4. it cannot read the pin
# The whole point of the assertion is that a pin-reading guard cannot see stale
# bytes. If this checker ever starts consulting the manifest (or a staged
# provenance file) the guard is defeated, so the absence of the pin is pinned.
# Only executable lines are scanned: the checker's own header explains in prose
# which pin it deliberately does NOT read, and a comment cannot read anything.
echo "== the checker decides from the artifact, not the pin"
CHECKER_CODE="$WORK/checker-code.txt"
grep -v '^[[:space:]]*#' "$CHECKER" > "$CHECKER_CODE"
for token in "build-inputs" "portal.commit" "portal-resolved" "portal-build-inputs" "PORTAL_COMMIT"; do
    n="$(grep -c -F -- "$token" "$CHECKER_CODE" || true)"
    if [ "$n" = 0 ]; then
        ok "checker does not consult the portal pin ('$token': $n references in code)"
    else
        bad "checker references the portal pin ('$token': $n references in code) — a guard that reads the pin cannot see stale bytes"
        grep -F -- "$token" "$CHECKER_CODE" | sed 's/^/       /'
    fi
done

# ------------------------------------------------- 5. the real tree agrees
# When a portal build has been staged (CI's happy-path job, a local build), the
# counts the checker will read from a package built here are reported, so a
# stale staged tree is visible in this test's own output too.
if [ -d "packaging/files/tollgate-captive-portal-site/assets" ]; then
    echo "== the staged guest bundle in this tree"
    buy=$(grep -o -F -- 'session_expired_buy_more' packaging/files/tollgate-captive-portal-site/assets/*.js 2>/dev/null | wc -l | tr -d ' ')
    rec=$(grep -o -F -- 'session_expired_reconnect' packaging/files/tollgate-captive-portal-site/assets/*.js 2>/dev/null | wc -l | tr -d ' ')
    echo "  session_expired_buy_more  : $buy"
    echo "  session_expired_reconnect : $rec"
    if [ "$buy" -ge 1 ] && [ "$rec" -eq 0 ]; then
        ok "the staged guest bundle in this tree is the #60 revision"
    else
        bad "the staged guest bundle in this tree is NOT the #60 revision (buy_more=$buy reconnect=$rec) — run 'bash packaging/portal-build.sh'"
    fi
else
    echo "== no staged portal build in this tree (run 'bash packaging/portal-build.sh' to enable the last check)"
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
