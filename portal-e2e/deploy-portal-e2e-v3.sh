#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# TollGate e2e-test build for the beta GL-MT3000 — v3 (BOTH portal fixes).
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/felixfelix-bot/tollgate-module-basic-go/host-alpha5-apk/portal-e2e/deploy-portal-e2e-v3.sh)
#
# Why process substitution and not `curl ... | bash`: piping the script into
# bash makes the SCRIPT bash's stdin, so ssh cannot prompt for the router
# password. `bash <(curl ...)` keeps your terminal's stdin free.
#
# WHAT IT INSTALLS
#   tollgate-wrt_0.6.0_alpha5_aarch64_cortex-a53_portalcu102ln004.apk
#   built from pr/portal-pin-ln004 (portal pin e67d646, PR #56) with the
#   captive-portal bundle regenerated from that pin, so the shipped portal
#   carries BOTH fixes:
#     * the keyset-agnostic v4 cashuB decode (#CU102, portal #55), and
#     * the client MAC on the Lightning /ln-invoice create + status poll and
#       the LN003/LN004 error strings (#LN004, portal #56).
#
# WHY THE VERSION IS alpha5
#   Measured on apk-tools 3.0.2 (the pinned SDK image and this router):
#   `apk add` of a file whose version EQUALS the installed one is a NO-OP —
#   the payload is not rewritten. This artifact is therefore built with an
#   explicit `PACKAGE_VERSION=v0.6.0-alpha5` override (the repository's VERSION
#   file is unchanged, so the module PR is unaffected) and apk reports
#   0.6.0_alpha5-r0 > 0.6.0_alpha4-r0, i.e. a real upgrade.
#   The verification in step 5 is fail-closed anyway: if the installed bundle
#   is still the old one, the script says so instead of reporting success.
#
# What it does NOT do: no reboot, no config wipe, no WAN change, no
# publication. Nothing on the router is touched unless the downloaded bytes
# match the reviewed size+sha256 below.
#
# Options:
#   TOLLGATE_DRYRUN=1            verify the download only, never touch a router
#   TOLLGATE_ROUTER_HOST=<ip>    default 192.168.8.1
# ---------------------------------------------------------------------------
set -u
set -o pipefail

ROUTER="${TOLLGATE_ROUTER_HOST:-192.168.8.1}"
BASE="https://raw.githubusercontent.com/felixfelix-bot/tollgate-module-basic-go/host-alpha5-apk/portal-e2e"
APK_NAME="tollgate-wrt_0.6.0_alpha5_aarch64_cortex-a53_portalcu102ln004.apk"
APK_URL="$BASE/$APK_NAME"
ASSETS_URL="$BASE/expected-assets-alpha5.txt"
EXP_SIZE="7863188"
EXP_SHA="45e7d1760767789a0d0d16be2c61c9a0af542625469f4d401bd98a4e91dd9969"  # pragma: allowlist secret (artifact digest, not a credential)
REMOTE_APK="/tmp/tg-portal-e2e-v3.apk"
DRY="${TOLLGATE_DRYRUN:-0}"
TMP="$(mktemp -d)" || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
SSHOPT=(-o ControlMaster=auto -o ControlPath="$TMP/cm-%r@%h:%p" -o ControlPersist=120 -o ConnectTimeout=10)

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC2086
rsh() { ssh "${SSHOPT[@]}" "root@$ROUTER" "$@"; }
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

for c in curl ssh; do command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"; done

echo "==================================================================="
echo " TollGate e2e v3  |  router=$ROUTER"
echo " portal fixes: #CU102 keyset-agnostic decode + #LN004 MAC/i18n"
echo "==================================================================="

if [ "$DRY" != "1" ]; then
  echo
  echo "== 0/6  router identity (no password needed yet) =="
  ssh "${SSHOPT[@]}" -o PreferredAuthentications=none -o StrictHostKeyChecking=accept-new \
      "root@$ROUTER" true 2>&1 | sed 's/^/    /' | head -4
  echo "    host key:"
  ssh-keyscan -T 5 "$ROUTER" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | sed 's/^/    /' | head -3
  echo "    (if the banner is not a dropbear/OpenSSH SSH server, STOP - wrong host)"
fi

echo
echo "== 1/6  download + integrity (fail-closed) =="
echo "    url   : $APK_URL"
curl -fsSL --max-time 300 -o "$TMP/apk" "$APK_URL" || die "download failed: $APK_URL"
SZ=$(wc -c < "$TMP/apk" | tr -d ' ')
SH=$(sha256_of "$TMP/apk")
echo "    size  : $SZ (expected $EXP_SIZE)"
echo "    sha256: $SH"
echo "    expect: $EXP_SHA"
[ "$SZ" = "$EXP_SIZE" ] || die "SIZE MISMATCH - refusing to install"
[ "$SH" = "$EXP_SHA" ] || die "SHA256 MISMATCH - refusing to install"
echo "    OK: bytes are exactly the reviewed artifact"

# The expected-assets manifest is advisory but its absence means the publish is
# incomplete; report it rather than fail (the apk hash is the real gate).
if curl -fsSL --max-time 60 -o "$TMP/assets.txt" "$ASSETS_URL" 2>/dev/null; then
  echo "    expected-assets manifest: $(grep -c -v '^#' "$TMP/assets.txt") assets listed"
else
  echo "    WARNING: could not fetch $ASSETS_URL (advisory only)"
fi

if [ "$DRY" = "1" ]; then
  echo
  echo "== DRYRUN: stopping before any router contact =="
  echo "    would install : apk add --allow-untrusted $REMOTE_APK"
  echo "    would verify  : the installed portal bundle carries the #LN004 marker"
  exit 0
fi

echo
echo "== 2/6  what is on the router now =="
rsh 'apk list --installed 2>/dev/null | grep -i tollgate || echo "    (tollgate-wrt not installed)"
     echo "    setup marker: $(cat /etc/tollgate-setup-done 2>/dev/null || echo none)"
     ENTRY=$(ls /etc/tollgate/tollgate-captive-portal-site/assets/index-*.js 2>/dev/null | head -1)
     if [ -n "$ENTRY" ]; then
       echo "    installed portal entry : $(basename "$ENTRY")"
       echo "    LN004 marker in it now : $(grep -o -F "mac=\${encodeURIComponent(" "$ENTRY" 2>/dev/null | wc -l)  (0 = pre-#LN004 bundle)"
     fi' || echo "    (could not read the router state - continuing)"

echo
echo "== 3/6  transfer to the router (cat|ssh; scp is broken on it) =="
echo "    an ssh password prompt is expected - you will be asked up to 3 times"
cat "$TMP/apk" | ssh "${SSHOPT[@]}" "root@$ROUTER" "cat > $REMOTE_APK" \
  || die "TRANSFER FAILED (wrong root password, or host unreachable) - nothing was installed"
SZ2=$(rsh "stat -c %s $REMOTE_APK" 2>/dev/null || echo "")
echo "    transferred: ${SZ2:-<none>} (expected $EXP_SIZE)"
[ "$SZ2" = "$EXP_SIZE" ] || die "TRANSFER INCOMPLETE - aborting before install; router untouched"

echo
echo "== 4/6  install (the form the official installer uses) =="
rsh "apk add --allow-untrusted $REMOTE_APK" || die "INSTALL FAILED - see output above"
echo "    ---- installed version ----"
rsh 'apk list --installed 2>/dev/null | grep -i tollgate; echo "    setup marker: $(cat /etc/tollgate-setup-done 2>/dev/null || echo none)"'

echo
echo "== 5/6  the payload must actually be the new bundle (fail-closed) =="
rsh 'sh -s' <<'REMOTE'
cd /etc/tollgate/tollgate-captive-portal-site || { echo "  FAIL: portal tree missing"; exit 9; }
ENTRY=$(ls assets/index-*.js 2>/dev/null | head -1)
[ -n "$ENTRY" ] || { echo "  FAIL: no portal entry asset"; exit 9; }
echo "  entry asset          : $ENTRY ($(wc -c < "$ENTRY") bytes)"
M=$(grep -o -F 'mac=${encodeURIComponent(' "$ENTRY" 2>/dev/null | wc -l | tr -d ' ')
echo "  LN004 mac marker     : $M   (expect >= 1; 0 means the bundle did NOT refresh)"
K=$(grep -c -E '"LN00[34]_(label|message)"' locales/en.json 2>/dev/null | tr -d ' ')
echo "  LN003/LN004 strings  : $K   (expect 4, 0 means the old locale is still installed)"
G=$(grep -c -F 'getTokenMetadata' "$ENTRY" 2>/dev/null | tr -d ' ')
echo "  CU102 decode marker  : $G   (expect >= 1)"
if [ "$M" -ge 1 ] && [ "$K" -ge 4 ] && [ "$G" -ge 1 ]; then
  echo "  VERDICT: PASS - both portal fixes are in the installed bytes"
  exit 0
fi
cat <<'RECOVERY'
  VERDICT: FAIL - the installed portal bundle is not the one in this package.
  Most likely cause: apk treated the install as "already installed" (same
  version) and left the old payload. Nothing was damaged; recover with:

    apk add nodogsplash jq                 # pin the deps so 'del' cannot purge them
    apk del tollgate-wrt                   # removes only the package payload
    apk add --allow-untrusted /tmp/tg-portal-e2e-v3.apk
    # then re-run this script's step 5 check by running the whole script again

  Do NOT run 'apk del tollgate-wrt' without adding nodogsplash/jq first: the
  daemon and jq were pulled in as dependencies, and a bare del purges them
  together (measured: del --simulate removes tollgate-wrt, jq, libc,
  nodogsplash), which leaves the portal unenforced.
RECOVERY
exit 9
REMOTE
VERDICT=$?
[ "$VERDICT" = "0" ] || die "payload verification failed (see the recovery block above)"

echo
echo "== 6/6  read-only surface check (no reboot, no config wipe) =="
rsh 'echo "  :2050 balance allow -> $(uci -q get nodogsplash.@nodogsplash[0].users_to_router 2>/dev/null | grep -c "tcp port 2050")"
     echo "  :8090 config allow  -> $(uci -q get nodogsplash.@nodogsplash[0].users_to_router 2>/dev/null | grep -c "tcp port 8090")"
     echo "  :443 pre-auth allow -> $(uci -q get nodogsplash.@nodogsplash[0].users_to_router 2>/dev/null | grep -c "tcp port 443")"
     echo "  nodogsplash running -> $(pgrep -c nodogsplash 2>/dev/null || echo 0)"
     echo "  admin SPA title     -> $(curl -s --max-time 5 http://127.0.0.1:8090/ 2>/dev/null | sed -n "s/.*<title>\(.*\)<\/title>.*/\1/p" | head -1)"'
ssh -O exit -o ControlPath="$TMP/cm-%r@%h:%p" "root@$ROUTER" 2>/dev/null

cat <<'NEXT'

------------------------------------------------------------------
WHAT TO TEST (the happy path, both fixes)
  1. captive portal : join the TollGate WiFi, open any http:// page
  2. Cashu (#CU102) : paste/scan a real coinos or minibits cashuB note
                      -> must NOT say "Invalid Cashu token / #CU102"
  3. Lightning      : switch to the Lightning tab, request an invoice
                      -> the invoice QR/string must appear (this needs the
                         #LN004 fix: the portal now sends the client MAC on
                         the create call and on the status poll)
                      -> any Lightning error must render as a READABLE MESSAGE,
                         not as the literal keys "LN003_label"/"LN004_label"
  4. balance page   : http://<router>:2050/
  5. config UI      : http://<router>:8090/

If step 3 shows the literal i18n key instead of a message, the old bundle is
still installed - re-read the step 5 verdict above, it is fail-closed.

Read-only: nothing was rebooted, no config was wiped.
------------------------------------------------------------------
NEXT
