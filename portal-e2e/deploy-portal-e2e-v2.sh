#!/bin/bash
# TollGate alpha4 — e2e-test build WITH THE FIXED CAPTIVE-PORTAL BUNDLE.
#
# Built from module fix/portal-bundle-repin-refresh @ c7be4ae7 (module PR #517,
# now MERGED as bf4ca69) on top of main d622688b (#513). The captive-portal
# bundle is regenerated from the pinned portal commit d699367 (portal main,
# PR #55 merged), whose decode is keyset-agnostic (getTokenMetadata) — so a real
# coinos/minibits v4 `cashuB` note with a SHORT keyset id is no longer rejected
# with #CU102.
#
# Covers the three surfaces: captive portal (:2051/splash.html via nodogsplash),
# balance page (:2050), config UI / admin SPA (:8090).
#
# Hand-deploy for the beta GL-MT3000 (OpenWrt 25.12, apk, aarch64_cortex-a53).
#
# v2 (2026-09-22): this script no longer masks an ssh auth failure behind the
# `cat | ssh` pipeline (pipefail), prints the router's ssh banner + host key so
# the device can be confirmed BEFORE the password prompt, and aborts with a
# precise reason per stage. The router is never modified unless every stage up
# to and including the install succeeds.
set -u
set -o pipefail

ROUTER="${1:-192.168.8.1}"
BASE="https://raw.githubusercontent.com/felixfelix-bot/tollgate-module-basic-go/host-alpha4-apk/portal-e2e"
APK="tollgate-wrt_0.6.0_alpha4_aarch64_cortex-a53_portaldecode.apk"
EXP_SIZE="7861856"
EXP_SHA="058b3e967cb86fe7a17dad1be5747b981fdab43976263edc90b41af23e538298"
TMP="${TMPDIR:-/tmp}/tg-portal-e2e.apk"
SSHOPT=(-o ControlMaster=auto -o ControlPath=/tmp/tgssh-%r@%h:%p -o ConnectTimeout=10)

echo "==================================================================="
echo " TollGate alpha4 + FIXED portal bundle | router=$ROUTER"
echo " (captive portal + balance page + config UI e2e build)"
echo "==================================================================="
echo
echo "== 0/5 router identity (no password needed yet) =="
echo "  ssh banner:"
ssh "${SSHOPT[@]}" -o PreferredAuthentications=none -o StrictHostKeyChecking=accept-new \
    "root@$ROUTER" true 2>&1 | sed 's/^/    /' | head -4
echo "  host key:"
ssh-keyscan -T 5 "$ROUTER" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | sed 's/^/    /' | head -3
echo "  (if the banner is not a dropbear/OpenSSH SSH server, STOP — wrong host)"
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
echo "  an ssh password prompt is expected - you will be asked up to 3 times"
if ! cat "$TMP" | ssh "${SSHOPT[@]}" "root@$ROUTER" 'cat > /tmp/tg-portal-e2e.apk'; then
  echo
  echo "  TRANSFER FAILED: the ssh login did not succeed."
  echo "  - wrong root password, or root login disabled on this router."
  echo "  - nothing was installed; the router is untouched."
  exit 1
fi
SZ2=$(ssh "${SSHOPT[@]}" "root@$ROUTER" 'stat -c %s /tmp/tg-portal-e2e.apk' 2>/dev/null || echo "")
echo "  transferred: ${SZ2:-<none>} (expected $EXP_SIZE)"
if [ "$SZ2" != "$EXP_SIZE" ]; then
  echo "  TRANSFER INCOMPLETE - aborting before install; router untouched."; exit 1
fi
echo
echo "== 3/5 install (same form the official installer uses) =="
ssh "${SSHOPT[@]}" "root@$ROUTER" 'apk add --allow-untrusted /tmp/tg-portal-e2e.apk' || { echo "  INSTALL FAILED"; exit 1; }
echo "---- installed version ----"
ssh "${SSHOPT[@]}" "root@$ROUTER" 'apk list --installed 2>/dev/null | grep -i tollgate ; cat /etc/tollgate-setup-done 2>/dev/null'
echo
echo "== 4/5 the fix must be VISIBLE in the installed bundle =="
ssh "${SSHOPT[@]}" "root@$ROUTER" 'ls /etc/tollgate/tollgate-captive-portal-site/assets/ 2>/dev/null | grep -E "^index-.*\.js$" ; echo "  files: $(ls /etc/tollgate/tollgate-captive-portal-site/ 2>/dev/null | tr "\n" " ")"'
echo
echo "== 5/5 read-only surface check (no reboot, no config wipe) =="
ssh "${SSHOPT[@]}" "root@$ROUTER" 'echo "  :2050 balance allow -> $(uci -q get nodogsplash.@nodogsplash[0].users_to_router 2>/dev/null | grep -c "tcp port 2050")" ; echo "  :8090 config allow  -> $(uci -q get nodogsplash.@nodogsplash[0].users_to_router 2>/dev/null | grep -c "tcp port 8090")" ; echo "  :443 pre-auth allow -> $(uci -q get nodogsplash.@nodogsplash[0].users_to_router 2>/dev/null | grep -c "tcp port 443")"'
ssh -O exit -o ControlPath=/tmp/tgssh-%r@%h:%p "root@$ROUTER" 2>/dev/null
echo
echo "Read-only: nothing was rebooted, no config was wiped."
echo
echo "NOW TEST (happy path):"
echo "  1. captive portal : join the TollGate WiFi, open any http:// page"
echo "  2. balance page   : http://$ROUTER:2050/"
echo "  3. config UI      : http://$ROUTER:8090/"
echo "  4. THE FIX        : paste/scan a real coinos or minibits cashuB note"
echo "                      -> must NOT say 'Invalid Cashu token / #CU102'"
