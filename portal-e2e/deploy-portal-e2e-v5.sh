#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# TollGate e2e-test build for the beta GL-MT3000 — v5 (BusyBox-proof).
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/felixfelix-bot/tollgate-module-basic-go/host-alpha5-apk/portal-e2e/deploy-portal-e2e-v5.sh)
#
# WHY `bash <(curl ...)` AND NOT `curl ... | bash`
#   Piping the script into bash makes the SCRIPT bash's stdin, so every ssh
#   inherits a pipe. OpenSSH reads a password from stdin whenever stdin is not
#   a terminal (RP_ALLOW_STDIN), which means the prompt is answered with script
#   text and auth fails. Process substitution keeps your terminal as stdin.
#
# WHAT v5 FIXES (v4's stage 3 aborted on the physical router AFTER a GOOD transfer)
#   v4 verified the router-side size with `stat -c %s`. This router's BusyBox
#   HAS NO `stat` APPLET, so the run printed
#       ash: stat: not found
#       45e7d176... /tmp/tg-portal-e2e-v4.apk
#       size reported by that session : <none> (expected 7863188)
#       !! TRANSFER INCOMPLETE (session reported size none) - aborting before install
#   even though the router's OWN sha256sum already matched the pin. The bytes
#   were correct; only a reporting command was missing. A hard fail on a
#   reporting applet is indistinguishable from a broken transfer — that is the
#   bug. v5 therefore:
#     (a) sizes every remote file with `wc -c < FILE` (POSIX; `wc` is always in
#         BusyBox) and keeps `stat -c %s` ONLY as a fallback, so a missing
#         applet can never fail an intact transfer — while an UNDETERMINABLE
#         size still aborts (fail-closed, unchanged);
#     (b) probes the router's applets in stage 2 and prints each one
#         (`stat : NO  <- fine: sizes come from 'wc -c < FILE'`) instead of
#         failing cryptically later;
#     (c) REUSES an already-present, hash-verified copy. The failed v4 run left
#         the pinned 7.5 MiB APK at /tmp/tg-portal-e2e-v4.apk; v5 sha256-checks
#         that copy ON THE ROUTER first and skips the transfer entirely when it
#         matches — no second 7.5 MiB pipe and no TOLLGATE_FORCE_PIPE=1
#         workaround needed;
#     (d) parses machine-readable TG_* markers instead of guessing numbers out
#         of raw command output (v4's `grep -E '^[0-9]+$'` heuristic silently
#         saw nothing the moment `stat` was absent).
#   Everything that already works is kept: NO ControlMaster/ControlPath
#   anywhere, exactly ONE self-contained ssh per stage, ssh stderr never
#   discarded, path A router-side download, path B single-session pipe with the
#   SSH_ASKPASS/`/dev/tty` helper gated on OpenSSH >= 8.4, the fail-closed
#   integrity gate, `apk add --allow-untrusted`, the installed-version/marker
#   read-back, stage 5's `mac=${encodeURIComponent(` + 4 LN003/LN004 locale-key
#   PASS/FAIL with its recovery block, the uplink pre-flight WARNING, and the
#   "NOW TEST (happy path)" footer.
#
# BUSYBOX AUDIT — every command this script runs ON THE ROUTER (not on your
# laptop). GNU-isms checked for and deliberately NOT used router-side:
#   stat -c %s ..... replaced by `wc -c < FILE`; stat kept ONLY as a fallback
#   readlink -f .... not used
#   date -d ........ not used (no dates are parsed on the router)
#   seq ............ not used
#   grep -P ........ not used (only -E/-F/-c/-o; -o falls back to `grep -c`)
#   sed -i ......... not used (no in-place edits on the router)
#   tar ............ not used (a single file moves)
#   sort -V ........ not used
#   df flags ....... `df -k` (POSIX) primary, `df -h` cosmetic only, both guarded
#   ls --color ..... not used
#   install ........ not used
#   mktemp ......... not used router-side (fixed names under the /tmp tmpfs)
#   awk ............ not used router-side (cut/grep/sed/tr only)
#   curl / nslookup  never assumed: each is behind `command -v` with a
#                   uclient-fetch / wget / ping fallback and an explicit line
#   sha256sum ...... ASSUMED PRESENT (measured: it ran on this router and
#                   matched the pin) — stage 2 still reports it
#
# TRANSFER ORDER (stage 3) — one ssh per attempt, never a second connection
#   R) REUSE (new in v5): if a copy already on the router hashes AND sizes to
#      the pinned values (both computed by the router in the stage-2 session),
#      the transfer is skipped entirely. Otherwise the copy is replaced.
#   A) ROUTER-SIDE DOWNLOAD: one ssh, no stdin conflict, no 7.5 MiB pipe. The
#      router fetches the APK itself and reports the sha256 and size IT
#      computed; both are compared against the pinned values. This also proves
#      the router's own uplink, which the payment path needs.
#   B) SINGLE-SESSION PIPE (fallback):
#      cat apk | ssh <opts> root@ROUTER 'cat > f; wc -c < f; sha256sum f'
#      The size AND the sha256 must come back from that one session — never
#      from a second connection (that is exactly what broke in v3). Because
#      stdin carries the payload, the password comes from /dev/tty via
#      SSH_ASKPASS + SSH_ASKPASS_REQUIRE=force (OpenSSH >= 8.4).
#
# PRE-FLIGHT (stage 2) reports the applet inventory, tmpfs head-room, the
#   installed package version, any already-present verified copy, and whether
#   the router has an uplink. A missing uplink is a WARNING, never an abort:
#   the install is local, so it still works — but the payment path cannot be
#   exercised without it (the router must reach the Cashu mint to swap the
#   token and the LN backend to create an invoice).
#
# WHAT IT INSTALLS (unchanged from v4)
#   tollgate-wrt_0.6.0_alpha5_aarch64_cortex-a53_portalcu102ln004.apk — both
#   portal fixes (the keyset-agnostic v4 cashuB decode #CU102, and the client
#   MAC + LN003/LN004 error strings on the Lightning invoice path #LN004).
#   WHY THE VERSION IS alpha5 (unchanged): `apk add` of a file whose version
#   EQUALS the installed one is a NO-OP on apk-tools 3.0.2, so this artifact is
#   built with an explicit `PACKAGE_VERSION=…alpha5` override and apk reports
#   0.6.0_alpha5-r0 > 0.6.0_alpha4-r0, a real upgrade.
#
# What it does NOT do: no reboot, no config wipe, no WAN change, no
# publication. Nothing on the router is touched unless the bytes hash to the
# reviewed size+sha256 below.
#
# Options:
#   TOLLGATE_DRYRUN=1            verify the download only, never touch a router
#   TOLLGATE_ROUTER_HOST=<ip>    default 192.168.8.1
#   TOLLGATE_ROUTER_PORT=<port>  default 22 (for a local/container sshd test)
#   TOLLGATE_FORCE_PIPE=1        exercise path B (implies NO_REUSE) — path A off
#   TOLLGATE_NO_REUSE=1          ignore any copy already present on the router
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
REMOTE_APK="/tmp/tg-portal-e2e-v5.apk"
# The failed v4 run left its copy here. It is hash-verified before being reused
# and deleted before a fresh transfer, so /tmp never holds two 7.5 MiB copies.
PREV_APK="/tmp/tg-portal-e2e-v4.apk"
DRY="${TOLLGATE_DRYRUN:-0}"
FORCE_PIPE="${TOLLGATE_FORCE_PIPE:-0}"
NO_REUSE="${TOLLGATE_NO_REUSE:-0}"
[ "$FORCE_PIPE" = "1" ] && NO_REUSE=1   # FORCE_PIPE exists to exercise path B
LIB_ONLY="${TOLLGATE_LIB_ONLY:-0}"
TMP="$(mktemp -d 2>/dev/null)" || TMP="${TMPDIR:-/tmp}/tg-portal-e2e.$$"
mkdir -p "$TMP" || { echo "cannot create a temp dir"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
REUSE_PATH=""

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
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# --- router-side helpers, embedded verbatim in the remote commands ----------
# Single-quoted ON PURPOSE: every $ inside must be evaluated on the ROUTER.
# size_of() is the whole point of v5: `wc -c` FIRST (POSIX, always present in
# BusyBox), `stat -c %s` only if wc produced nothing. A missing applet must
# never be reported as a broken transfer; an undeterminable size must still
# abort.
# shellcheck disable=SC2016
REMOTE_HELPERS='
size_of() {
  SZ=$(wc -c 2>/dev/null < "$1")
  if [ -z "$SZ" ]; then SZ=$(stat -c %s "$1" 2>/dev/null || true); fi
  printf "%s" "$SZ" | tr -d " \t"
}
sha_of() { sha256sum "$1" 2>/dev/null | cut -d" " -f1; }
count_marker() {
  if grep -o -F "$1" "$2" >/dev/null 2>&1 || [ $? -le 1 ]; then
    grep -o -F "$1" "$2" 2>/dev/null | wc -l | tr -d " "
  else
    grep -c -F "$1" "$2" 2>/dev/null | tr -d " "
  fi
}'

# --- TG_* markers: machine-readable, printed by the ROUTER ------------------
#   TG_APPLET_MISSING=<space-separated list>   applet probe (stage 2)
#   TG_CAND=<path>|<sha256>|<size>             existing copy found (stage 2)
#   TG_DL_TOOL=router|none                     path A verdict
#   TG_SRC=<path>|<sha256>|<size>              bytes written/checked this session
#   TG_UPLINK=0|1                              router internet reachability
extract_tg() { sed -n "s/^$2=//p" "$1" | tail -1; }
tg_path() { printf '%s' "$1" | cut -d'|' -f1; }
tg_sha()  { printf '%s' "$1" | cut -d'|' -f2; }
tg_size() { printf '%s' "$1" | cut -d'|' -f3; }

# ssh capability probe (SSH_ASKPASS_REQUIRE=force landed in OpenSSH 8.4).
SSH_VER_RAW="$(ssh -V 2>&1 || true)"
SSH_VER="$(printf '%s' "$SSH_VER_RAW" | sed -n 's/^\(OpenSSH\)_\([0-9][0-9]*\.[0-9][0-9]*\).*/\1_\2/p')"
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
# Inventory + applet probe + pre-flight + "is a verified copy already here?",
# ALL in ONE ssh. No heredoc on stdin (a heredoc would also occupy ssh's stdin
# and break a password prompt).
# Single-quoted ON PURPOSE: every $( ) and $VAR inside must be evaluated on
# the ROUTER, not here (shellcheck disable=SC2016).
# shellcheck disable=SC2016
STAGE2_REMOTE="$REMOTE_HELPERS"'
echo "  installed tollgate : $(apk list --installed 2>/dev/null | grep -i tollgate || echo "(tollgate-wrt not installed)")"
echo "  setup marker       : $(cat /etc/tollgate-setup-done 2>/dev/null || echo none)"
ENTRY=$(ls /etc/tollgate/tollgate-captive-portal-site/assets/index-*.js 2>/dev/null | head -1)
if [ -n "$ENTRY" ]; then
  echo "  installed portal entry : $(basename "$ENTRY")"
  echo "  #LN004 mac marker now  : $(count_marker "mac=\${encodeURIComponent(" "$ENTRY")   (0 = pre-#LN004 bundle)"
fi
# --- applet probe: report each one, never fail cryptically later -------------
A=""; MISS=""
for a in wc sha256sum grep sed cut head tr cat ls basename; do
  if command -v "$a" >/dev/null 2>&1; then A="$A $a=yes"; else A="$A $a=NO"; MISS="$MISS $a"; fi
done
echo "  applets  :$A"
if grep -o -F x /dev/null >/dev/null 2>&1; then GO=yes; elif [ $? -le 1 ]; then GO=yes; else GO=NO; fi
echo "  grep -o  : $GO  (NO means the marker count falls back to grep -c)"
if command -v stat >/dev/null 2>&1; then
  echo "  stat     : yes (only a fallback here - sizes come from wc -c)"
else
  echo "  stat     : NO  <- fine: this script sizes files with wc -c, never stat"
fi
echo "TG_APPLET_MISSING=$MISS"
echo "  /tmp head-room (tmpfs, need ~7.5 MiB):"
df -k /tmp 2>/dev/null | sed "s/^/    /"
df -h /tmp 2>/dev/null | sed "s/^/    /"
# --- already-present copies: cheap to check, expensive to re-transfer --------
for f in '"$PREV_APK"' '"$REMOTE_APK"'; do
  [ -f "$f" ] || continue
  echo "TG_CAND=$f|$(sha_of "$f")|$(size_of "$f")"
done
# --- uplink (a missing uplink is a WARNING, never an abort) ------------------
if command -v ping >/dev/null 2>&1; then
  if ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then echo "TG_UPLINK=1"; else echo "TG_UPLINK=0"; fi
  echo "  uplink ping 1.1.1.1 : $(ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && echo reachable || echo UNREACHABLE)"
else
  echo "TG_UPLINK=0"
  echo "  uplink ping 1.1.1.1 : unknown (no ping applet)"
fi
if command -v nslookup >/dev/null 2>&1; then
  echo "  uplink dns lookup   : $(nslookup openwrt.org >/dev/null 2>&1 && echo resolves || echo UNRESOLVED)"
elif command -v ping >/dev/null 2>&1; then
  echo "  uplink dns lookup   : $(ping -c1 -W2 openwrt.org >/dev/null 2>&1 && echo resolves || echo UNRESOLVED)"
else
  echo "  uplink dns lookup   : unknown (no nslookup/ping applet)"
fi
if command -v curl >/dev/null 2>&1; then
  echo "  uplink tcp 443 curl : $(curl -s -o /dev/null --max-time 5 -k https://raw.githubusercontent.com/ 2>/dev/null && echo ok || echo NO)"
elif command -v uclient-fetch >/dev/null 2>&1; then
  echo "  uplink tcp 443 ucli : $(uclient-fetch -q -O /dev/null --timeout=5 --no-check-certificate https://raw.githubusercontent.com/ 2>/dev/null && echo ok || echo NO)"
elif command -v wget >/dev/null 2>&1; then
  echo "  uplink tcp 443 wget : $(wget -q -O /dev/null --timeout=5 --no-check-certificate https://raw.githubusercontent.com/ 2>/dev/null && echo ok || echo NO)"
else
  echo "  uplink tcp 443      : unknown (no curl/uclient-fetch/wget on the router)"
fi'

# ---------------------------------------------------------------- stage 3 ---
# path A: the router downloads the pinned artifact itself and reports the
# sha256 + size it computed. Errors from the individual fetchers are INTENTION-
# ALLY left visible (no 2>/dev/null) — only the TG_DL_TOOL verdict line at the
# end decides whether the stage succeeded. The stale v4 copy is removed first so
# /tmp never carries two 7.5 MiB files.
STAGE3_DL_REMOTE=$(cat <<EOF
$REMOTE_HELPERS
cd /tmp || exit 1
rm -f $PREV_APK
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
  echo "TG_SRC=$REMOTE_APK|\$(sha_of $REMOTE_APK)|\$(size_of $REMOTE_APK)"
else
  echo "TG_DL_TOOL=none"
fi
EOF
)

# path B: ONE ssh that writes AND verifies in the same session. The size and
# the sha256 must come back from this single connection. `cat > f || exit 1`
# refuses to report anything for a truncated stream, and the size comes from
# `wc -c < f` — never from `stat`, which this router's BusyBox does not have.
STAGE3_PIPE_REMOTE=$(cat <<EOF
$REMOTE_HELPERS
rm -f $PREV_APK
cat > $REMOTE_APK || exit 1
echo "TG_SRC=$REMOTE_APK|\$(sha_of $REMOTE_APK)|\$(size_of $REMOTE_APK)"
EOF
)

stage3_transfer() {
  echo "== 3/6  transfer to the router (no ControlMaster; one ssh per attempt) =="
  TRANSFER_OK=0

  # path R: reuse a copy already on the router (hash+size verified in the
  # stage-2 session — the same session that computed them, never a second ssh).
  if [ "$NO_REUSE" != "1" ] && [ -n "$REUSE_PATH" ]; then
    echo "  path R (preferred): the router already holds the pinned artifact"
    echo "                      ($REUSE_PATH) - verified in one session, nothing re-piped"
    REMOTE_APK="$REUSE_PATH"
    TRANSFER_OK=1
    echo "    OK: reusing the copy already on the router (0 bytes transferred)"
  elif [ "$NO_REUSE" = "1" ]; then
    echo "  path R skipped (TOLLGATE_NO_REUSE=1 / TOLLGATE_FORCE_PIPE=1):"
    echo "         a fresh copy is transferred even if a verified one exists"
    REUSE_PATH=""
  fi

  if [ "$TRANSFER_OK" != "1" ] && [ "$FORCE_PIPE" != "1" ]; then
    echo "  path A: ROUTER-SIDE DOWNLOAD - the router fetches it itself, so"
    echo "          nothing is piped and sha256/size are computed there"
    echo "          (this also proves the router's uplink)"
    echo "  (any fetch error text below is the router's own; the TG_DL_TOOL line is the verdict)"
    rsh "$STAGE3_DL_REMOTE" > "$TMP/dl.txt" 2>&1
    sed 's/^/    /' "$TMP/dl.txt"
    DL_TOOL=$(extract_tg "$TMP/dl.txt" TG_DL_TOOL)
    REC="$(extract_tg "$TMP/dl.txt" TG_SRC)"
    SZA="$(tg_size "$REC")"
    SHA2="$(tg_sha "$REC")"
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
  elif [ "$TRANSFER_OK" != "1" ]; then
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
    RECB="$(extract_tg "$TMP/pipe.txt" TG_SRC)"
    SZB="$(tg_size "$RECB")"
    SHB="$(tg_sha "$RECB")"
    echo "    size reported by that session  : ${SZB:-<none>} (expected $EXP_SIZE)"
    echo "    sha256 reported by that session: ${SHB:-<none>}"
    echo "    sha256 expected                : $EXP_SHA"
    echo "    (size comes from 'wc -c', so <none> here means the router could not"
    echo "     READ the file at all - it is no longer a missing-applet artefact)"
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
STAGE5_REMOTE="$REMOTE_HELPERS"'
cd /etc/tollgate/tollgate-captive-portal-site || { echo "  FAIL: portal tree missing"; exit 9; }
ENTRY=$(ls assets/index-*.js 2>/dev/null | head -1)
[ -n "$ENTRY" ] || { echo "  FAIL: no portal entry asset"; exit 9; }
echo "  entry asset          : $ENTRY ($(size_of "$ENTRY") bytes)"
M=$(count_marker "mac=\${encodeURIComponent(" "$ENTRY")
echo "  LN004 mac marker     : $M   (expect >= 1; 0 means the bundle did NOT refresh)"
K=$(grep -c -E "\"LN00[34]_(label|message)\"" locales/en.json 2>/dev/null | tr -d " ")
echo "  LN003/LN004 strings  : $K   (expect 4, 0 means the old locale is still installed)"
G=$(count_marker "getTokenMetadata" "$ENTRY")
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
echo "  nodogsplash running -> $(command -v pgrep >/dev/null 2>&1 && pgrep nodogsplash 2>/dev/null | wc -l | tr -d \" \" || echo unknown) process(es)  (busybox pgrep has no -c, so count the PIDs)"
if command -v curl >/dev/null 2>&1; then
  T=$(curl -s --max-time 5 http://127.0.0.1:8090/ 2>/dev/null | sed -n "s/.*<title>\(.*\)<\/title>.*/\1/p" | head -1)
elif command -v uclient-fetch >/dev/null 2>&1; then
  T=$(uclient-fetch -q -O - --timeout=5 http://127.0.0.1:8090/ 2>/dev/null | sed -n "s/.*<title>\(.*\)<\/title>.*/\1/p" | head -1)
elif command -v wget >/dev/null 2>&1; then
  T=$(wget -q -O - --timeout=5 http://127.0.0.1:8090/ 2>/dev/null | sed -n "s/.*<title>\(.*\)<\/title>.*/\1/p" | head -1)
else
  T="(no curl/uclient-fetch/wget on the router)"
fi
echo "  admin SPA title     -> $T"'

# Built at call time so it quotes the path that was ACTUALLY used (the reused
# v4-named copy or the fresh v5 one).
recovery_text() {
  cat <<RECOVERY
  ---- recovery (nothing was damaged) ----
  Most likely cause: apk treated the install as "already installed" (same
  version) and left the old payload. Nothing was damaged; recover with:

    apk add nodogsplash jq                 # pin the deps so 'del' cannot purge them
    apk del tollgate-wrt                   # removes only the package payload
    apk add --allow-untrusted $REMOTE_APK
    # then re-run this script's stage 5 check by running the whole script again

  Do NOT run "apk del tollgate-wrt" without adding nodogsplash/jq first: the
  daemon and jq were pulled in as dependencies, and a bare del purges them
  together (measured: del --simulate removes tollgate-wrt, jq, libc,
  nodogsplash), which leaves the portal unenforced.
RECOVERY
}

# ---------------------------------------------------------------- stages ---
stage2_preflight() {
  echo
  echo "== 2/6  router inventory + applet probe + pre-flight (one ssh; your password is asked here) =="
  rsh "$STAGE2_REMOTE" > "$TMP/stage2.txt" 2>&1
  RC2=$?
  sed 's/^/    /' "$TMP/stage2.txt"
  [ "$RC2" = "0" ] || echo "    (stage 2 exited $RC2 - see the ssh message above; continuing)"

  MISSING_APPLETS="$(extract_tg "$TMP/stage2.txt" TG_APPLET_MISSING)"
  if [ -n "$MISSING_APPLETS" ]; then
    echo "    !! WARNING: the router is missing applet(s):$MISSING_APPLETS"
    echo "       The integrity gate fails closed - if 'wc' is among them the size"
    echo "       cannot be determined and the script aborts instead of installing"
    echo "       unverified bytes. Anything else is cosmetic."
  fi

  UPLINK="$(extract_tg "$TMP/stage2.txt" TG_UPLINK)"
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

  # Already-present copies (the state the failed v4 run left behind).
  CAND_RECS="$(sed -n 's/^TG_CAND=//p' "$TMP/stage2.txt")"
  if [ -z "$CAND_RECS" ]; then
    echo "    already-present copy: none - a full transfer is required"
  else
    echo "    already-present copy (checked on the router, one session):"
    while IFS= read -r rec; do
      [ -n "$rec" ] || continue
      printf '      %s : sha256 %s size %s\n' "$(tg_path "$rec")" "$(tg_sha "$rec")" "$(tg_size "$rec")"
      if [ "$(tg_sha "$rec")" = "$EXP_SHA" ] && [ "$(tg_size "$rec")" = "$EXP_SIZE" ]; then
        if [ "$NO_REUSE" = "1" ]; then
          printf '        MATCH, but reuse is disabled by TOLLGATE_NO_REUSE/FORCE_PIPE\n'
          printf '              -> it will be REPLACED by a fresh transfer\n'
        else
          printf '        MATCH -> stage 3 REUSES this copy; 0 bytes are transferred\n'
          REUSE_PATH="$(tg_path "$rec")"
        fi
      else
        printf '        stale/partial (pinned sha256 %s / size %s) -> it will be replaced\n' "$EXP_SHA" "$EXP_SIZE"
      fi
    done <<<"$CAND_RECS"
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
    recovery_text
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

for c in curl ssh sed grep awk wc tr cut head tail; do
  command -v "$c" >/dev/null 2>&1 || die "missing required LOCAL command: $c (this script runs on your laptop)"
done

if [ "$DRY" = "1" ]; then
  echo "==================================================================="
  echo " TollGate e2e v5  |  DRYRUN (no router contact at all)"
else
  echo "==================================================================="
  echo " TollGate e2e v5  |  router=$ROUTER port=$RPORT  ssh=$SSH_VER_RAW"
fi
echo " portal fixes: #CU102 keyset-agnostic decode + #LN004 MAC/i18n"
echo " busybox-proof: sizes via 'wc -c', never 'stat'; reuse of a verified copy"
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
  echo "    would pre-flight: applet probe, df -k/-h /tmp, installed version,"
  echo "                      uplink (ping + dns + tcp 443), existing copies"
  echo "    would transfer : REUSE a verified /tmp copy if present, else"
  echo "                     path A router-side download of $APK_NAME,"
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
WHAT TO TEST NOW (the happy path, both fixes)
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
