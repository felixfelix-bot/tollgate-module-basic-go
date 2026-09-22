#!/bin/bash
# TollGate alpha4 — e2e-test build WITH THE FIXED CAPTIVE-PORTAL BUNDLE.
#
# Built from branch fix/portal-bundle-repin-refresh @ c7be4ae7 (module PR #517)
# on top of main d622688b (#513). The captive-portal bundle is regenerated from
# the pinned portal commit d699367 (portal main, PR #55 merged), whose decode is
# keyset-agnostic (getTokenMetadata) — so a real coinos/minibits v4 `cashuB` note
# with a SHORT keyset id is NO LONGER rejected with #CU102.
#
# Covers the three surfaces: captive portal (:2051/splash.html via nodogsplash),
# balance page (:2050), config UI / admin SPA (:8090).
#
# Hand-deploy for the beta GL-MT3000 (OpenWrt 25.12, apk, aarch64_cortex-a53).
set -u

ROUTER="${1:-192.168.8.1}"
BASE="https://raw.githubusercontent.com/felixfelix-bot/tollgate-module-basic-go/host-alpha4-apk/portal-e2e"
APK="tollgate-wrt_0.6.0_alpha4_aarch64_cortex-a53_portaldecode.apk"
EXP_SIZE="7861856"
EXP_SHA="058b3e967cb86fe7a17dad1be5747b981fdab43976263edc90b41af23e538298"
TMP="${TMPDIR:-/tmp}/tg-portal-e2e.apk"
SSH="ssh -o ControlMaster=auto -o ControlPath=/tmp/tgssh-%r@%h:%p root@$ROUTER"

echo "==================================================================="
echo " TollGate alpha4 + FIXED portal bundle | router=$ROUTER"
echo " (captive portal + balance page + config UI e2e build)"
echo "==================================================================="
echo
echo "== 1/5 download + integrity (fail-closed) =="
echo "  url   : $BASE/$APK"
curl -fsSL "$BASE/$APK" -o "$TMP" || { echo "  DOWNLOAD FAILED"; exit 1; }
SZ=$(stat -c %s "$TMP")
SH=$(sha256sum "$TMP" | awk '{print $1}')
echo "  size  : $SZ (expected $EXP_SIZE)"
echo "  sha256: $SH"
echo "  expect: $EXP_SHA"
if [ "$SZ" != "$EXP_SIZE" ] || [ "$SH" != "$EXP_SHA" ]; then
  echo "  MISMATCH - refusing to touch the router. Aborting."; exit 1
fi
echo "  OK: bytes match the reviewed artifact (nothing else will be installed)"
echo
echo "== 2/5 transfer to the router (cat|ssh; scp is broken on it) =="
echo "  an ssh password prompt is expected - you will be asked once"
cat "$TMP" | ssh -o ControlMaster=auto -o ControlPath=/tmp/tgssh-%r@%h:%p root@"$ROUTER" 'cat > /tmp/tg-portal-e2e.apk' || { echo "  TRANSFER FAILED"; exit 1; }
SZ2=$($SSH 'stat -c %s /tmp/tg-portal-e2e.apk' 2>/dev/null)
echo "  transferred: $SZ2 (expected $EXP_SIZE)"
[ "$SZ2" = "$EXP_SIZE" ] || { echo "  SIZE MISMATCH ON ROUTER - aborting before install"; exit 1; }
echo
echo "== 3/5 install (same form the official installer uses) =="
$SSH 'apk add --allow-untrusted /tmp/tg-portal-e2e.apk' || { echo "  INSTALL FAILED"; exit 1; }
echo "---- installed version ----"
$SSH 'apk list --installed 2>/dev/null | grep -i tollgate ; cat /etc/tollgate-setup-done 2>/dev/null'
echo
echo "== 4/5 the fix must be VISIBLE in the installed bundle =="
$SSH 'grep -l getTokenMetadata /etc/tollgate/tollgate-captive-portal-site/assets/*.js 2>/dev/null | head -2; echo "  (expect index-<hash>.js above = keyset-agnostic decode)"'
echo "  files present:"
$SSH 'ls /etc/tollgate/tollgate-captive-portal-site/ 2>/dev/null | tr "\n" " "; echo; ls /www/tollgate/index.html 2>/dev/null'
echo
echo "== 5/5 read-only surface check (no reboot, no config wipe) =="
$SSH 'echo "  portal  :2051 -> $(uci -q get nodogsplash.@nodogsplash[0].gatewayport 2>/dev/null) gateway; uhttpd.portal"; \
echo "  balance :2050 allow -> $(uci -q get nodogsplash.@nodogsplash[0].users_to_router 2>/dev/null | grep -c "tcp port 2050")"; \
echo "  config  :8090 allow -> $(uci -q get nodogsplash.@nodogsplash[0].users_to_router 2>/dev/null | grep -c "tcp port 8090")"; \
echo "  :443 pre-auth allow -> $(uci -q get nodogsplash.@nodogsplash[0].users_to_router 2>/dev/null | grep -c "tcp port 443")"'
$SSH 'exit' 2>/dev/null
ssh -O exit -o ControlPath=/tmp/tgssh-%r@%h:%p root@"$ROUTER" 2>/dev/null
echo
echo "Read-only: nothing was rebooted, no config was wiped."
echo
echo "NOW TEST (happy path):"
echo "  1. captive portal : connect a client to the TollGate WiFi, open any http:// page"
echo "  2. balance page   : http://$ROUTER:2050/"
echo "  3. config UI      : http://$ROUTER:8090/"
echo "  4. THE FIX        : paste/scan a real coinos or minibits cashuB note in the portal"
echo "                      -> must NOT say 'Invalid Cashu token / #CU102'"
