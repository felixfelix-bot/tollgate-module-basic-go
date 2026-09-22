#!/bin/bash
# TollGate alpha4 (MERGED TIP a44802db, the canonical PR-#513 build) hand-deploy
# for the beta GL-MT3000 on OpenWrt 25.12 (apk, aarch64_cortex-a53).
set -u
ROUTER="${1:-192.168.8.1}"
BASE="https://raw.githubusercontent.com/felixfelix-bot/tollgate-module-basic-go/host-alpha4-apk/pre15c"
APK="tollgate-wrt_0.6.0_alpha4_aarch64_cortex-a53.apk"
EXP_SIZE="7785218"
EXP_SHA="cb310984ea777ff883b2181e9ebb4eb079ea20c25b7c3470da539d7500d3a104"
TMP="${TMPDIR:-/tmp}/tg-a4m.apk"

echo "==================================================================="
echo " TollGate alpha4 (MERGED PR #513 tip) hand-deploy | router=$ROUTER"
echo "==================================================================="
echo
echo "== 1/4 download + integrity (fail-closed) =="
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
echo "  OK: bytes are exactly the reviewed merged-tip artifact"
echo
echo "== 2/4 transfer to the router (cat|ssh; scp is broken on it) =="
echo "  an ssh password prompt is expected - you will be asked once"
cat "$TMP" | ssh -o ControlMaster=auto -o ControlPath=/tmp/tgssh-%r@%h:%p root@"$ROUTER" 'cat > /tmp/tg-a4m.apk' || { echo "  TRANSFER FAILED"; exit 1; }
SZ2=$(ssh -o ControlMaster=auto -o ControlPath=/tmp/tgssh-%r@%h:%p root@"$ROUTER" 'stat -c %s /tmp/tg-a4m.apk' 2>/dev/null)
echo "  transferred: $SZ2"
echo
echo "== 3/4 install (same form the official installer uses) =="
ssh -o ControlMaster=auto -o ControlPath=/tmp/tgssh-%r@%h:%p root@"$ROUTER" 'apk add --allow-untrusted /tmp/tg-a4m.apk' || { echo "  INSTALL FAILED"; exit 1; }
echo "---- installed version ----"
ssh -o ControlMaster=auto -o ControlPath=/tmp/tgssh-%r@%h:%p root@"$ROUTER" 'apk list --installed | grep tollgate ; cat /etc/tollgate-setup-done 2>/dev/null'
echo
echo "== 4/4 read-only verification (the fix must show :443 allowed pre-auth) =="
ssh -o ControlMaster=auto -o ControlPath=/tmp/tgssh-%r@%h:%p root@"$ROUTER" 'sh /proc/self/fd/0' < "$PROBE" || { echo "  PROBE FAILED"; exit 1; }
ssh -o ControlMaster=auto -o ControlPath=/tmp/tgssh-%r@%h:%p root@"$ROUTER" 'exit' 2>/dev/null
ssh -O exit -o ControlPath=/tmp/tgssh-%r@%h:%p root@"$ROUTER" 2>/dev/null
echo
echo "Read-only: nothing was rebooted, no config was wiped."
