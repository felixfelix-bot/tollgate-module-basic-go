#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# TollGate e2e-test build for the beta GL-MT3000 — v4 (BOTH portal fixes).
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/felixfelix-bot/tollgate-module-basic-go/host-alpha5-apk/portal-e2e/deploy-portal-e2e-v4.sh)
#
# WHY `bash <(curl ...)` AND NOT `curl ... | bash`
#   Piping the script into bash makes the SCRIPT bash's stdin, so every ssh
#   inherits a pipe. OpenSSH reads a password from stdin whenever stdin is not
#   a terminal (RP_ALLOW_STDIN), which means the prompt is answered with script
#   text and auth fails. Process substitution keeps your terminal as stdin.
#
# WHAT v4 FIXES (v3's transfer stage failed on the physical router)
#   v3 piped the APK into `ssh` and then checked the size with a SECOND ssh,
#   relying on ControlMaster/ControlPath to reuse the first connection's auth.
#   Measured: stages 0/1/2 authenticated and printed the router inventory, then
#   stage 3 reported `transferred: <none> (expected 7863188)` and aborted.
#   Two defects, both removed here:
#     (a) the ssh that writes the payload has the payload on ITS OWN stdin, so
#         a password prompt cannot be answered from that stream. Measured on
#         OpenSSH 10.2 against a password-only sshd: `printf 'testpw\n' |
#         ssh <opts> host 'echo OK'` does not use the piped bytes as the
#         password (3x "Permission denied"), and with a controlling terminal
#         present it simply BLOCKS at the prompt until killed. So the pipe path
#         can never take its password from stdin.
#         v3 leaned on ControlMaster to carry that auth into a SECOND ssh for
#         the size check; when the multiplexed connection was gone the second
#         ssh could not authenticate at all -- and its error was SWALLOWED by
#         `2>/dev/null || echo ""`, so the script blamed the transfer instead
#         of showing the auth failure.
#     (b) hence v4: there is NO ControlMaster/ControlPath anywhere
#         (`-o ControlMaster=no -o ControlPath=none`), exactly ONE
#         self-contained ssh per stage, and ssh stderr is NEVER sent to
#         /dev/null. If a stage fails you read the router's own message and the
#         script aborts with the router untouched. The one stage whose stdin
#         must carry the payload uses SSH_ASKPASS (see below) to answer its
#         prompt from /dev/tty instead.
#
# TRANSFER ORDER (stage 3) — one ssh per attempt, never a second connection
#   path A (preferred) ROUTER-SIDE DOWNLOAD: one ssh, no stdin conflict, no
#     7.5 MiB pipe. The router fetches the APK itself and reports the sha256
#     and size IT computed; both are compared against the pinned values. This
#     also proves the router's own uplink, which the payment path needs.
#   path B (fallback) SINGLE-SESSION PIPE:
#     cat apk | ssh <opts> root@ROUTER 'cat > f; stat -c %s f; sha256sum f'
#     The size AND the sha256 must come back from that one session — never
#     from a second connection (that is exactly what broke in v3). Because
#     stdin carries the payload, the password is collected from /dev/tty via
#     SSH_ASKPASS + SSH_ASKPASS_REQUIRE=force (OpenSSH >= 8.4), so nothing is
#     read from the payload and no secret is cached on disk.
#
# PRE-FLIGHT (stage 2) reports tmpfs head-room for the 7.5 MiB push, the
#   installed package version and whether the router has an uplink. A missing
#   uplink is a WARNING, never an abort: the install is local, so it still
#   works — but the payment path cannot be exercised without it (the router
#   must reach the Cashu mint to swap the token and reach the LN backend to
#   create an invoice). The output says so explicitly.
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
#   The verification in stage 5 is fail-closed anyway: if the installed bundle
#   is still the old one, the script says so instead of reporting success.
#
# What it does NOT do: no reboot, no config wipe, no WAN change, no
# publication. Nothing on the router is touched unless the bytes hash to the
# reviewed size+sha256 below.
#
# Options:
#   TOLLGATE_DRYRUN=1            verify the download only, never touch a router
#   TOLLGATE_ROUTER_HOST=<ip>    default 192.168.8.1
#   TOLLGATE_ROUTER_PORT=<port>  default 22 (for a local/container sshd test)
#   TOLLGATE_FORCE_PIPE=1        skip path A and use the pipe fallback only
#   TOLLGATE_LIB_ONLY=1          define the stages and stop (test-harness hook)
# ---------------------------------------------------------------------------
set -u
set -o pipefail

ROUTER="${TOLLGATE_ROUTER_HOST:-192.168.8.1}"
RPORT="${TOLLGATE_ROUTER_PORT:-22}"
BASE="https://raw.githubusercontent.com/felixfelix-bot/tollgate-module-basic-go/host-alpha5-apk/portal-e2e"
APK_NAME="tollgate-wrt_0.6.0_alpha5_aarch64_cortex-a53_portalcu102ln004.apk"
APK_URL="$BASE/$APK_NAME"
ASSETS_URL="$BASE/expected-assets-alpha5.txt"
EXP_SIZE="7863188"
EXP_SHA="45e7d1760767789a0d0d16be2c61c9a0af542625469f4d401bd98a4e91dd9969"  # pragma: allowlist secret (artifact digest, not a credential)
REMOTE_APK="/tmp/tg-portal-e2e-v4.apk"
DRY="${TOLLGATE_DRYRUN:-0}"
FORCE_PIPE="${TOLLGATE_FORCE_PIPE:-0}"
LIB_ONLY="${TOLLGATE_LIB_ONLY:-0}"
TMP="$(mktemp -d)" || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# --- ssh policy -------------------------------------------------------------
# One self-contained connection per stage, multiplexing explicitly OFF.
# ControlMaster against this router's sshd (dropbear-ish, RSA+ED25519 host
# keys) did not survive the transfer, and a dead master is precisely what made
# v3's second ssh fail to authenticate without saying so. No ssh stderr is
# redirected to /dev/null anywhere in this script: a swallowed auth error is
# worse than a loud one.
SSHOPT=(-o ControlMaster=no -o ControlPath=none -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
SSHPORT=()
[ "$RPORT" = "22" ] || SSHPORT=(-p "$RPORT")

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
# One ssh, stdout and stderr visible, stdin left as YOUR terminal so ssh can
# prompt for the password normally (nothing is piped into it).
# The caller always passes a fully-formed remote command, so a client-side
# expansion here is intended (those are local $VARS by design).
# shellcheck disable=SC2029
rsh() { ssh "${SSHOPT[@]}" ${SSHPORT[@]+"${SSHPORT[@]}"} "root@$ROUTER" "$@"; }
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
# Pull the sha256 / size out of a captured ssh session (used by both paths).
parse_sha() { awk 'length($1) == 64 && $1 ~ /^[0-9a-f]+$/ { print $1 }' "$1" | tail -1; }
parse_size() { grep -E '^[0-9]+$' "$1" | tail -1; }

# ssh capability probe (SSH_ASKPASS_REQUIRE=force landed in OpenSSH 8.4).
SSH_VER_RAW="$(ssh -V 2>&1 || true)"
SSH_VER="$(printf '%s' "$SSH_VER_RAW" | sed -n 's/^\(OpenSSH\)_\?\([0-9][0-9]*\.[0-9][0-9]*\).*/\1_\2/p')"
SSH_MAJOR=0
SSH_MINOR=0
if [ -n "$SSH_VER" ]; then
  SSH_MAJOR="${SSH_VER#OpenSSH_}"
  SSH_MINOR="${SSH_MAJOR#*.}"
  SSH_MAJOR="${SSH_MAJOR%%.*}"
fi
ASKPASS_OK=0
if [ "$SSH_MAJOR" -gt 8 ] || { [ "$SSH_MAJOR" -eq 8 ] && [ "$SSH_MINOR" -ge 4 ]; }; then
  ASKPASS_OK=1
fi

# Askpass helper for the pipe fallback: ssh's stdin carries the APK there, so
# the password must come from the terminal instead. Nothing is cached: the
# secret is read from /dev/tty, handed to ssh, and dropped.
setup_askpass() {
  cat > "$TMP/askpass" <<'ASKPASS_EOF'
#!/bin/sh
prompt="$1"
if [ -r /dev/tty ]; then
  printf '%s' "$prompt" > /dev/tty
  stty -echo < /dev/tty 2>/dev/null
  IFS= read -r _pw < /dev/tty
  stty echo < /dev/tty 2>/dev/null
  printf '\n' > /dev/tty
  printf '%s\n' "$_pw"
else
  printf 'askpass: /dev/tty is not readable - cannot prompt for the router password\n' >&2
  exit 1
fi
ASKPASS_EOF
  chmod 700 "$TMP/askpass"
}

# ---------------------------------------------------------------- stage 1 ---
stage1_download() {
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

  # The expected-assets manifest is advisory but its absence means the publish
  # is incomplete; report it rather than fail (the apk hash is the real gate).
  if curl -fsSL --max-time 60 -o "$TMP/assets.txt" "$ASSETS_URL" 2>/dev/null; then
    echo "    expected-assets manifest: $(grep -c -v '^#' "$TMP/assets.txt") assets listed"
  else
    echo "    WARNING: could not fetch $ASSETS_URL (advisory only)"
  fi
}

# ---------------------------------------------------------------- stage 2 ---
# Inventory + pre-flight, ONE ssh, no heredoc on stdin (a heredoc would also
# occupy ssh's stdin and break a password prompt).
# Single-quoted ON PURPOSE: every $( ) and $VAR inside must be evaluated on
# the ROUTER, not here (shellcheck disable=SC2016).
# shellcheck disable=SC2016
STAGE2_REMOTE='echo "  installed tollgate : $(apk list --installed 2>/dev/null | grep -i tollgate || echo "(tollgate-wrt not installed)")"
echo "  setup marker       : $(cat /etc/tollgate-setup-done 2>/dev/null || echo none)"
ENTRY=$(ls /etc/tollgate/tollgate-captive-portal-site/assets/index-*.js 2>/dev/null | head -1)
if [ -n "$ENTRY" ]; then
  echo "  installed portal entry : $(basename "$ENTRY")"
  echo "  #LN004 mac marker now  : $(grep -o -F "mac=\${encodeURIComponent(" "$ENTRY" 2>/dev/null | wc -l)   (0 = pre-#LN004 bundle)"
fi
echo "  /tmp head-room (tmpfs, need ~7.5 MiB):"
df -h /tmp 2>/dev/null | sed "s/^/    /"
if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then echo "TG_UPLINK=1"; else echo "TG_UPLINK=0"; fi
echo "  uplink ping 1.1.1.1 : $(ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && echo reachable || echo UNREACHABLE)"
echo "  uplink dns lookup   : $(nslookup openwrt.org >/dev/null 2>&1 && echo resolves || (ping -c1 -W2 openwrt.org >/dev/null 2>&1 && echo resolves || echo UNRESOLVED))"
echo "  uplink tcp 443      : $(curl -s -o /dev/null --max-time 5 -k https://raw.githubusercontent.com/ 2>/dev/null && echo ok || (wget -q -O /dev/null --timeout=5 https://raw.githubusercontent.com/ 2>/dev/null && echo ok || echo NO))"'

# ---------------------------------------------------------------- stage 3 ---
# path A: the router downloads the pinned artifact itself and reports the
# sha256 + size it computed. Errors from the individual fetchers are INTENTION-
# ALLY left visible (no 2>/dev/null) — only the TG_DL_TOOL verdict line at the
# end decides whether the stage succeeded.
STAGE3_DL_REMOTE=$(cat <<EOF
cd /tmp || exit 1
rm -f $REMOTE_APK
if command -v wget >/dev/null 2>&1; then
  wget -O $REMOTE_APK '$APK_URL' || wget --no-check-certificate -O $REMOTE_APK '$APK_URL' || true
fi
if [ ! -s $REMOTE_APK ] && command -v uclient-fetch >/dev/null 2>&1; then
  uclient-fetch -O $REMOTE_APK '$APK_URL' || uclient-fetch --no-check-certificate -O $REMOTE_APK '$APK_URL' || true
fi
if [ ! -s $REMOTE_APK ] && command -v curl >/dev/null 2>&1; then
  curl -fsSL -o $REMOTE_APK '$APK_URL' || true
fi
if [ -s $REMOTE_APK ]; then
  echo "TG_DL_TOOL=router"
  sha256sum $REMOTE_APK
  stat -c %s $REMOTE_APK
else
  echo "TG_DL_TOOL=none"
fi
EOF
)

# path B: ONE ssh that writes AND verifies in the same session. The size and
# the sha256 must come back from this single connection.
STAGE3_PIPE_REMOTE="cat > $REMOTE_APK || exit 1; stat -c %s $REMOTE_APK; sha256sum $REMOTE_APK"

stage3_transfer() {
  echo "== 3/6  transfer to the router (no ControlMaster; one ssh per attempt) =="
  TRANSFER_OK=0

  if [ "$FORCE_PIPE" != "1" ]; then
    echo "  path A (preferred): ROUTER-SIDE DOWNLOAD - the router fetches it itself,"
    echo "                      so nothing is piped and sha256/size are computed there"
    echo "                      (this also proves the router's uplink)"
    echo "  (any fetch error text below is the router's own; the TG_DL_TOOL line is the verdict)"
    rsh "$STAGE3_DL_REMOTE" > "$TMP/dl.txt" 2>&1
    sed 's/^/    /' "$TMP/dl.txt"
    DL_TOOL=$(sed -n 's/^TG_DL_TOOL=//p' "$TMP/dl.txt" | tail -1)
    SZA=$(parse_size "$TMP/dl.txt")
    SHA2=$(parse_sha "$TMP/dl.txt")
    if [ "$DL_TOOL" = "router" ] && [ "$SZA" = "$EXP_SIZE" ] && [ "$SHA2" = "$EXP_SHA" ]; then
      echo "    router-computed sha256: $SHA2"
      echo "    router-computed size  : $SZA (expected $EXP_SIZE)"
      echo "    OK: path A - the router itself fetched exactly the pinned artifact"
      TRANSFER_OK=1
    else
      echo "    path A did not deliver the pinned bytes (tool=${DL_TOOL:-none} size=${SZA:-none} sha256=${SHA2:-none})"
      echo "    -> falling back to path B (local pipe). Reasons: no uplink, no"
      echo "       downloader on the router, DNS/TLS problem, or a truncated body."
    fi
  else
    echo "  path A skipped (TOLLGATE_FORCE_PIPE=1) - testing the pipe fallback only"
  fi

  if [ "$TRANSFER_OK" != "1" ]; then
    echo
    echo "  path B: SINGLE-SESSION PIPE - write and verify inside ONE ssh session"
    echo "          (a second ssh would need its own auth, which is what v3 got wrong)"
    if [ "$ASKPASS_OK" != "1" ]; then
      echo "    !! your ssh ($SSH_VER_RAW) does not support SSH_ASKPASS_REQUIRE=force (needs >= 8.4)."
      echo "       With the apk on ssh's stdin the password would have to come from that"
      echo "       stream, which corrupts the transfer. Fix one of these, then re-run:"
      echo "         * upgrade OpenSSH, or"
      echo "         * give the router a temporary uplink so path A works, or"
      echo "         * install a key: ssh-copy-id root@$ROUTER"
      die "cannot transfer to a password-only router without SSH_ASKPASS support - router untouched"
    fi
    setup_askpass
    echo "    stdin is the payload, so the password is read from /dev/tty via askpass"
    echo "    (nothing is written to disk; the prompt appears once, below)"
    PIPE_ENV=(SSH_ASKPASS="$TMP/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0)
    cat "$TMP/apk" | env ${PIPE_ENV[@]+"${PIPE_ENV[@]}"} \
        ssh "${SSHOPT[@]}" ${SSHPORT[@]+"${SSHPORT[@]}"} "root@$ROUTER" "$STAGE3_PIPE_REMOTE" \
        > "$TMP/pipe.txt" 2>&1 || true
    sed 's/^/    /' "$TMP/pipe.txt"
    SZB=$(parse_size "$TMP/pipe.txt")
    SHB=$(parse_sha "$TMP/pipe.txt")
    echo "    size reported by that session  : ${SZB:-<none>} (expected $EXP_SIZE)"
    echo "    sha256 reported by that session: ${SHB:-<none>}"
    echo "    sha256 expected                : $EXP_SHA"
    [ "$SZB" = "$EXP_SIZE" ] || die "TRANSFER INCOMPLETE (session reported size ${SZB:-none}) - aborting before install; router untouched"
    [ "$SHB" = "$EXP_SHA" ] || die "TRANSFER CORRUPTED (session reported sha256 ${SHB:-none}) - aborting before install; router untouched"
    TRANSFER_OK=1
    echo "    OK: path B - the bytes on the router hash to the pinned artifact"
  fi
}

# ---------------------------------------------------------------- stage 5 ---
# Payload proof. Passed as ONE argument (no `sh -s` heredoc) so ssh keeps the
# terminal as stdin and can prompt; only double quotes are used inside, since
# the whole thing travels inside a single-quoted bash string.
# shellcheck disable=SC2016
STAGE5_REMOTE='cd /etc/tollgate/tollgate-captive-portal-site || { echo "  FAIL: portal tree missing"; exit 9; }
ENTRY=$(ls assets/index-*.js 2>/dev/null | head -1)
[ -n "$ENTRY" ] || { echo "  FAIL: no portal entry asset"; exit 9; }
echo "  entry asset          : $ENTRY ($(wc -c < "$ENTRY") bytes)"
M=$(grep -o -F "mac=\${encodeURIComponent(" "$ENTRY" 2>/dev/null | wc -l | tr -d " ")
echo "  LN004 mac marker     : $M   (expect >= 1; 0 means the bundle did NOT refresh)"
K=$(grep -c -E "\"LN00[34]_(label|message)\"" locales/en.json 2>/dev/null | tr -d " ")
echo "  LN003/LN004 strings  : $K   (expect 4, 0 means the old locale is still installed)"
G=$(grep -c -F "getTokenMetadata" "$ENTRY" 2>/dev/null | tr -d " ")
echo "  CU102 decode marker  : $G   (expect >= 1)"
if [ "$M" -ge 1 ] && [ "$K" -ge 4 ] && [ "$G" -ge 1 ]; then
  echo "  VERDICT: PASS - both portal fixes are in the installed bytes"
  exit 0
fi
echo "  VERDICT: FAIL - the installed portal bundle is not the one in this package."
exit 9'

# shellcheck disable=SC2016
STAGE6_REMOTE='echo "  :2050 balance allow -> $(uci -q get nodogsplash.@nodogsplash[0].users_to_router 2>/dev/null | grep -c "tcp port 2050")"
echo "  :8090 config allow  -> $(uci -q get nodogsplash.@nodogsplash[0].users_to_router 2>/dev/null | grep -c "tcp port 8090")"
echo "  :443 pre-auth allow -> $(uci -q get nodogsplash.@nodogsplash[0].users_to_router 2>/dev/null | grep -c "tcp port 443")"
echo "  nodogsplash running -> $(pgrep -c nodogsplash 2>/dev/null || echo 0)"
echo "  admin SPA title     -> $(curl -s --max-time 5 http://127.0.0.1:8090/ 2>/dev/null | sed -n "s/.*<title>\(.*\)<\/title>.*/\1/p" | head -1)"'

RECOVERY_TEXT=$(cat <<'RECOVERY'
  ---- recovery (nothing was damaged) ----
  Most likely cause: apk treated the install as "already installed" (same
  version) and left the old payload. Nothing was damaged; recover with:

    apk add nodogsplash jq                 # pin the deps so 'del' cannot purge them
    apk del tollgate-wrt                   # removes only the package payload
    apk add --allow-untrusted /tmp/tg-portal-e2e-v4.apk
    # then re-run this script's stage 5 check by running the whole script again

  Do NOT run "apk del tollgate-wrt" without adding nodogsplash/jq first: the
  daemon and jq were pulled in as dependencies, and a bare del purges them
  together (measured: del --simulate removes tollgate-wrt, jq, libc,
  nodogsplash), which leaves the portal unenforced.
RECOVERY
)

# ---------------------------------------------------------------- stages ---
stage2_preflight() {
  echo
  echo "== 2/6  router inventory + pre-flight (one ssh; your password is asked here) =="
  rsh "$STAGE2_REMOTE" > "$TMP/stage2.txt" 2>&1
  RC2=$?
  sed 's/^/    /' "$TMP/stage2.txt"
  [ "$RC2" = "0" ] || echo "    (stage 2 exited $RC2 - see the ssh message above; continuing)"
  UPLINK=$(sed -n 's/^TG_UPLINK=//p' "$TMP/stage2.txt" | tail -1)
  if [ "$UPLINK" = "1" ]; then
    echo "    uplink: PRESENT (the payment path can be exercised)"
  else
    cat <<'NOUPLINK'

      !! WARNING: the router did not reach the internet (no ping / no DNS / no
         tcp 443). This is NOT fatal for the install - the apk is local - but
         WHAT IT MEANS FOR THE PAYMENT PATH: the router cannot reach the Cashu
         mint to swap a token and cannot reach the LN backend to create an
         invoice, so any e2e payment test right now will fail with network
         errors ("context deadline exceeded" / token rejected) no matter how
         good the portal bundle is. Restore the uplink before judging the fix.
NOUPLINK
  fi
}

stage4_install() {
  echo
  echo "== 4/6  install (the form the official installer uses) =="
  rsh "apk add --allow-untrusted $REMOTE_APK
  echo '    ---- installed version ----'
  apk list --installed 2>/dev/null | grep -i tollgate
  echo \"    setup marker: \$(cat /etc/tollgate-setup-done 2>/dev/null || echo none)\"" \
    || die "INSTALL FAILED - see the router output above; nothing else was changed"
}

stage5_verify() {
  echo
  echo "== 5/6  the payload must actually be the new bundle (fail-closed) =="
  rsh "$STAGE5_REMOTE" > "$TMP/v5.txt" 2>&1
  V5=$?
  sed 's/^/    /' "$TMP/v5.txt"
  if [ "$V5" != "0" ]; then
    echo
    printf '%s\n' "$RECOVERY_TEXT"
    die "payload verification failed (exit $V5) - router otherwise untouched (no reboot, no config wipe)"
  fi
}

stage6_surface() {
  echo
  echo "== 6/6  read-only surface check (no reboot, no config wipe) =="
  rsh "$STAGE6_REMOTE" | sed 's/^/    /'
}

# Test-harness hook: define everything above, run nothing below.
# Sourced (BASH_SOURCE[0] != $0) -> return to the caller; executed -> exit 0.
if [ "$LIB_ONLY" = "1" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
  fi
  exit 0
fi

for c in curl ssh; do command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"; done

if [ "$DRY" = "1" ]; then
  echo "==================================================================="
  echo " TollGate e2e v4  |  DRYRUN (no router contact at all)"
else
  echo "==================================================================="
  echo " TollGate e2e v4  |  router=$ROUTER port=$RPORT  ssh=$SSH_VER_RAW"
fi
echo " portal fixes: #CU102 keyset-agnostic decode + #LN004 MAC/i18n"
echo "==================================================================="

if [ "$DRY" != "1" ]; then
  echo
  echo "== 0/6  router identity (no password needed yet) =="
  ssh "${SSHOPT[@]}" ${SSHPORT[@]+"${SSHPORT[@]}"} -o PreferredAuthentications=none \
      "root@$ROUTER" true 2>&1 | sed 's/^/    /' | head -4
  echo "    host key:"
  ssh-keyscan -T 5 ${SSHPORT[@]+"${SSHPORT[@]}"} "$ROUTER" 2>/dev/null | ssh-keygen -lf - 2>/dev/null | sed 's/^/    /' | head -3
  echo "    (if the banner is not a dropbear/OpenSSH SSH server, STOP - wrong host)"
fi

echo
stage1_download

if [ "$DRY" = "1" ]; then
  echo
  echo "== DRYRUN: stopping before any router contact =="
  echo "    would pre-flight: df -h /tmp, installed version, uplink (ping + dns + tcp 443)"
  echo "    would transfer : path A router-side download of $APK_NAME,"
  echo "                     else path B single-session pipe + in-session sha256/size"
  echo "    would install  : apk add --allow-untrusted $REMOTE_APK"
  echo "    would verify   : the installed portal bundle carries the #LN004 marker"
  exit 0
fi

echo
stage2_preflight

echo
stage3_transfer

echo
stage4_install

echo
stage5_verify

echo
stage6_surface

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
still installed - re-read the stage 5 verdict above, it is fail-closed.

Read-only: nothing was rebooted, no config was wiped.
------------------------------------------------------------------
NEXT
