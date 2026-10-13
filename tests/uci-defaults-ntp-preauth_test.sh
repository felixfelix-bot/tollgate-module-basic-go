#!/usr/bin/env bash
# Offline tests for the pre-auth NTP server half of issue #627
# (packaging/files/etc/uci-defaults/99-tollgate-setup: setup_ntp_server).
#
# The allowlist half (udp/123 joining users_to_router) is covered by
# uci-defaults-nodogsplash-convergence_test.sh, whose CORE_ENTRIES now
# carries it through the full script run. This file covers the other half:
# busybox sysntpd must be told to LISTEN (system.ntp.enable_server='1'),
# idempotently, with the section created when the image shipped none — and
# a RUNNING router gets exactly one cheap restart of a stateless UDP
# responder, never a fresh boot (procd starts sysntpd after uci-defaults
# with this config already committed).
#
# No router, SDK or network needed: the function is extracted from the
# setup script (function-boundary extraction, the same style as the band
# tests), its absolute /etc/init.d/sysntpd path is rewritten by sed, and it
# runs against a fake uci and pidof.
#
# Usage: bash tests/uci-defaults-ntp-preauth_test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

SCRIPT="packaging/files/etc/uci-defaults/99-tollgate-setup"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- extract setup_ntp_server by function boundary, rewriting the init path
awk '/^setup_ntp_server\(\) \{/,/^\}/' "$SCRIPT" \
    | sed "s|/etc/init.d/sysntpd|$TMP/init.d/sysntpd|g" \
    > "$TMP/ntp_fragment.sh"
grep -q 'enable_server' "$TMP/ntp_fragment.sh" \
    || { bad "extraction failed — setup_ntp_server not found in $SCRIPT"; exit 1; }

mkdir -p "$TMP/bin" "$TMP/init.d"

# ---- the name the guard must probe: derived, never hardcoded
#
# `pidof` dereferences /proc/<pid>/exe and returns the basename of the
# PROCESS — the `PROG=` value at the top of the live init script — or
# nothing. So the seam this guard sits on is "the setup script's pidof
# argument == basename of the image's PROG=/usr/sbin/ntpd" == `ntpd`.
#
# The baseline is read from the live init script when this host has one
# (every OpenWrt target, and any host with a rootfs checkout); otherwise it
# falls back to the documented constant, PROG=/usr/sbin/ntpd for the busybox
# sysntpd shipped in OpenWrt 25.12 (verified in
# openwrt/rootfs:x86_64-openwrt-25.12). The repo does not vendor
# /etc/init.d/sysntpd — it is image-owned — so the constant is the baseline
# and NTP_PROG names the file a checkout may override it with.
NTP_INIT_SCRIPT="${NTP_INIT_SCRIPT:-/etc/init.d/sysntpd}"
PROG_FROM_INIT=""
if [ -r "$NTP_INIT_SCRIPT" ]; then
    PROG_FROM_INIT=$(sed -n 's|^PROG=\(.*\)$|\1|p' "$NTP_INIT_SCRIPT" | head -n1)
fi
NTP_PROG="${PROG_FROM_INIT:-/usr/sbin/ntpd}"
NTP_PROG_COMM="${NTP_PROG##*/}"

# The setup script's own pidof argument, read out of the live source (not
# echoed from the constant above, or the cross-check would only be asserting
# itself). Scoped to setup_ntp_server: the file probes other services too
# (nodogsplash, uhttpd) and those are not this guard. Comments are stripped
# first — the function's own prose explains the regression and a bare `grep
# pidof` would scan those words as if they were a probe. Both spellings the
# call may use are accepted: the bare applet name and an absolute path.
PROBED_COMMS=$(awk '/^setup_ntp_server\(\) \{/,/^\}/' "$SCRIPT" \
    | sed 's/[[:space:]]*#.*$//' \
    | grep -oE 'pidof[[:space:]]+[A-Za-z0-9_./-]+' \
    | awk '{print $2}' | sed 's|.*/||' | sort -u)

# ---- fake uci: flat-file state, the subset the function uses
cat > "$TMP/bin/uci" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
STATE="${UCI_STATE:?UCI_STATE not set}"
quiet=0
[ "${1:-}" = "-q" ] && { quiet=1; shift; }
cmd="${1:-}"; shift || true
case "$cmd" in
    get)
        v="$(grep -F -- "$1=" "$STATE" | head -n1 | cut -d= -f2- || true)"
        [ -n "$v" ] || exit 1
        printf '%s\n' "$v"
        ;;
    set)
        key="${1%%=*}"; val="${1#*=}"
        if grep -qF -- "$key=" "$STATE"; then
            sed -i "s|^$(printf '%s' "$key" | sed 's/[.[\*^$]/\\&/g')=.*|$key=$val|" "$STATE"
        else
            printf '%s=%s\n' "$key" "$val" >> "$STATE"
        fi
        ;;
esac
SHIM
chmod +x "$TMP/bin/uci"

# ---- fake pidof: answers to the REAL process comm (see PROG below)
#
# The service process is busybox `ntpd` — `/etc/init.d/sysntpd` sets
# PROG=/usr/sbin/ntpd and busybox `pidof` matches the process comm, NOT the
# init-script name. Case 4 used to accept the literal string `sysntpd`, which
# is why it stayed green while the production guard (`pidof sysntpd`) was
# dead on hardware: it proved the shim, not the seam. The name answered here
# is derived from the live init script by the cross-check below and must be
# the same name the setup script probes; a shim that accepts only `sysntpd`
# reproduces the dead guard instead of masking it.
cat > "$TMP/bin/pidof" <<SHIM
#!/usr/bin/env bash
[ "\$1" = "$NTP_PROG_COMM" ] || exit 1
[ -n "\${PIDOF_NTPD:-}" ] || exit 1
printf '%s\n' "\$PIDOF_NTPD"
SHIM
chmod +x "$TMP/bin/pidof"

# ---- fake init script: records restarts
cat > "$TMP/init.d/sysntpd" <<'SHIM'
#!/usr/bin/env bash
printf 'restart\n' >> "${RESTART_LOG:?}" 2>/dev/null || true
SHIM
chmod +x "$TMP/init.d/sysntpd"

run_ntp_setup() {
    # The fragment path travels by environment, not by sh -c positionals:
    # "$2" inside a -c string is unset (the earlier form silently sourced
    # nothing and every state assertion failed for the wrong reason).
    PATH="$TMP/bin:$PATH" UCI_STATE="$1" NTP_FRAGMENT="$TMP/ntp_fragment.sh" \
        sh -c '. "$NTP_FRAGMENT" >/dev/null 2>&1; setup_ntp_server'
}

# ---- case 1: fresh image, no system.ntp section, sysntpd not running
S1="$TMP/state1"; : > "$S1"
run_ntp_setup "$S1"
if grep -q '^system.ntp=timeserver$' "$S1"; then
    ok "the timeserver section is created when the image shipped none"
else
    bad "system.ntp=timeserver missing after setup: $(cat "$S1")"
fi
if grep -q '^system.ntp.enable_server=1$' "$S1"; then
    ok "enable_server=1 is set on a fresh image"
else
    bad "enable_server not set: $(cat "$S1")"
fi

# ---- case 2: idempotency — a second run changes nothing
cp "$S1" "$S1.before"
run_ntp_setup "$S1"
if diff -q "$S1.before" "$S1" >/dev/null; then
    ok "a second run is a no-op (idempotent)"
else
    bad "second run mutated state: $(diff "$S1.before" "$S1")"
fi

# ---- case 3: a router whose operator disabled the server is RE-ENABLED
S3="$TMP/state3"
printf 'system.ntp=timeserver\nsystem.ntp.enable_server=0\n' > "$S3"
run_ntp_setup "$S3"
if grep -q '^system.ntp.enable_server=1$' "$S3"; then
    ok "an explicitly disabled server is re-enabled (policy, not preference)"
else
    bad "enable_server=0 survived: $(cat "$S3")"
fi

# ---- case 4: a RUNNING ntpd is restarted exactly once
#
# The probe must be the real process name. `pidof sysntpd` returns nothing on
# hardware (the comm is `ntpd`), so this case fails against the shipped guard
# — which is the point: it now measures the production seam.
S4="$TMP/state4"; : > "$S4"
RESTART_LOG="$TMP/restarts" PIDOF_NTPD=1234 run_ntp_setup "$S4"
if [ "$(wc -l < "$TMP/restarts" 2>/dev/null || echo 0)" = "1" ]; then
    ok "a running $NTP_PROG_COMM is restarted exactly once"
else
    bad "restart count = $(wc -l < "$TMP/restarts" 2>/dev/null || echo 0), want 1 — the guard probed a process name that is not the service's comm (probed: ${PROBED_COMMS:-<none>}, runnable: $NTP_PROG_COMM)"
fi

# ---- case 6: the guard probes the name the SERVICE actually runs as
#
# The regression this pins (found in review of PR #648): the probe named the
# init script (`sysntpd`) instead of the process (`ntpd`), so on real OpenWrt
# 25.12 the restart never fired. Asserted against the PROG read off the live
# init script above, not against a literal, so a future rename of the binary
# is caught here rather than on a customer's router.
if [ -z "$PROBED_COMMS" ]; then
    bad "the setup script has no pidof probe to compare (guard removed?)"
elif [ "$PROBED_COMMS" = "$NTP_PROG_COMM" ]; then
    ok "every pidof probe in the setup script names the service comm ('$NTP_PROG_COMM', per $NTP_INIT_SCRIPT PROG=$NTP_PROG)"
else
    bad "the setup script probes '$(printf '%s' "$PROBED_COMMS" | tr '\n' ' ')' but the service comm is '$NTP_PROG_COMM' (PROG=$NTP_PROG in $NTP_INIT_SCRIPT) — the restart guard is dead on hardware"
fi

# ---- case 5: a fresh boot (sysntpd not yet started) never touches the init
S5="$TMP/state5"; : > "$S5"
rm -f "$TMP/restarts"
run_ntp_setup "$S5"
if [ ! -e "$TMP/restarts" ]; then
    ok "a fresh boot leaves the init script untouched (procd starts it later)"
else
    bad "fresh boot restarted sysntpd: $(cat "$TMP/restarts")"
fi

printf 'ntp-preauth: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
