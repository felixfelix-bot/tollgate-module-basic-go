#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# TollGate alpha4 — fix-level hand-deploy for the beta GL-MT3000 (OpenWrt 25.12)
#
#   bash <(curl -fsSL <this-script-url>)
#
# Why the process-substitution form and not `curl ... | bash`: piping into bash
# makes the SCRIPT the stdin, so ssh cannot prompt for the router password.
# `bash <(curl ...)` hands bash a file descriptor and leaves your terminal's
# stdin free, so the password prompt works.
#
# What it does: downloads the apk, verifies size + sha256 FAIL-CLOSED, pushes it
# to the router, installs it with `apk add --allow-untrusted` (the exact form the
# official installer uses - SDK-built packages are not signed by the feed key),
# then runs a read-only verification and prints a verdict.
#
# It never reboots, never wipes config, never touches the WAN, never publishes.
# Set TOLLGATE_DRYRUN=1 to stop after the integrity check (no router contact).
# Override the target with TOLLGATE_ROUTER_HOST=192.168.8.1.
# ---------------------------------------------------------------------------
set -u

ROUTER="${TOLLGATE_ROUTER_HOST:-192.168.8.1}"
BASE="https://raw.githubusercontent.com/felixfelix-bot/tollgate-module-basic-go/host-alpha4-apk/pre15b"
APK_URL="$BASE/tollgate-wrt_0.6.0_alpha4_aarch64_cortex-a53.apk"
PROBE_URL="$BASE/tollgate-caps-probe.sh"
APK_SHA256="6971c28ced7893f70a84601c562b8e0bf0acc9650a48efae443e902e83b5a0d5"
APK_SIZE=7855666
REMOTE_APK="/tmp/tollgate-wrt-alpha4.apk"
DRY="${TOLLGATE_DRYRUN:-0}"

die() { printf '\n!! %s\n' "$*" >&2; exit 1; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

for c in curl ssh; do command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"; done

TMP="$(mktemp -d)" || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
APK="$TMP/tollgate-wrt_0.6.0_alpha4_aarch64_cortex-a53.apk"

# One ssh connection, multiplexed, so the password is asked once.
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath=$TMP/cm-%r@%h:%p -o ControlPersist=120"
# shellcheck disable=SC2086
rsh() { ssh $SSH_OPTS "root@$ROUTER" "$@"; }

echo "==================================================================="
echo " TollGate alpha4 hand-deploy  |  router=$ROUTER  |  arch=aarch64_cortex-a53"
echo "==================================================================="

echo
echo "== 1/4  download + integrity (fail-closed) =="
curl -fsSL --max-time 180 -o "$APK" "$APK_URL" || die "download failed: $APK_URL"
GOT_SIZE=$(wc -c < "$APK" | tr -d ' ')
GOT_SHA=$(sha256_of "$APK")
echo "   url      : $APK_URL"
echo "   size     : $GOT_SIZE bytes (expected $APK_SIZE)"
echo "   sha256   : $GOT_SHA"
echo "   expected : $APK_SHA256"
[ "$GOT_SIZE" = "$APK_SIZE" ] || die "SIZE MISMATCH - refusing to install"
[ "$GOT_SHA" = "$APK_SHA256" ] || die "SHA256 MISMATCH - refusing to install"
echo "   OK: bytes are exactly the reviewed artifact"

if [ "$DRY" = "1" ]; then
  echo
  echo "== DRYRUN: stopping before any router contact =="
  echo "   would transfer to : root@$ROUTER:$REMOTE_APK"
  echo "   would install with: apk add --allow-untrusted $REMOTE_APK"
  echo "   would then fetch : $PROBE_URL and run it read-only"
  exit 0
fi

echo
echo "== 2/4  transfer to the router (scp is broken on it; cat|ssh works) =="
echo "   an ssh password prompt is expected - you will be asked once"
# shellcheck disable=SC2086
cat "$APK" | ssh $SSH_OPTS "root@$ROUTER" "cat > $REMOTE_APK && echo transferred && wc -c < $REMOTE_APK" \
  || die "transfer failed (wrong password, or host unreachable?)"

echo
echo "== 3/4  install (same form the official installer uses) =="
rsh "apk add --allow-untrusted $REMOTE_APK; echo \"---- installed version ----\"; apk list --installed 'tollgate-wrt*' 2>/dev/null || apk info tollgate-wrt 2>/dev/null; echo \"---- setup marker ----\"; cat /etc/tollgate-setup-done 2>/dev/null" \
  || die "install failed - see output above"

echo
echo "== 4/4  read-only verification (the fix must show :443 allowed pre-auth) =="
PROBE="$TMP/tollgate-caps-probe.sh"
curl -fsSL --max-time 60 -o "$PROBE" "$PROBE_URL" || die "could not fetch the probe: $PROBE_URL"
if [ "$(sha256_of "$PROBE")" = "" ]; then die "probe download empty"; fi
# shellcheck disable=SC2086
cat "$PROBE" | ssh $SSH_OPTS "root@$ROUTER" "cat > /tmp/tollgate-caps-probe.sh && sh /tmp/tollgate-caps-probe.sh" \
  || die "probe failed"

cat <<'NEXT'

------------------------------------------------------------------
What to look for above
  setup marker   : v0.6.0-alpha4          (was v0.6.0-alpha3)
  solver depends : jq libc nodogsplash    (the whole point of this fix)
  replaces       : 0 entries
  443            : ALLOWED pre-auth       (anchored - 8443 can never satisfy it)

Read-only: nothing was rebooted, no config was wiped. The allow list on this
router already carried :443 from the earlier clean install, so a green run here
proves the upgrade path does not regress - it cannot re-show you the original
dead-end. To exercise the same-version path that this fix also covers, run the
install a second time and see whether it still re-asserts :443.
------------------------------------------------------------------
NEXT
