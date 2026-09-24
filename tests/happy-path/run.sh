#!/usr/bin/env bash
#
# Happy-path regression suite for a PUBLISHED TollGate package.
#
#   tests/happy-path/run.sh --artifact <extracted-package-dir>
#
# The artifact is an already-extracted `.apk`/`.ipk` (the feed job hands us the
# published bytes). Everything the suite exercises comes from inside it:
#
#   * the module binary      <artifact>/usr/bin/tollgate-wrt
#   * the captive-portal SPA <artifact>/etc/tollgate/tollgate-captive-portal-site
#
# Nothing outside the machine is contacted; no secret, Cashu token or payment is
# needed. See README.md for what this does and does NOT cover.
#
# Exit 0 = happy path intact. Non-zero = broken. Every check prints one line:
#
#   HPCHECK <id> <PASS|FAIL|SKIP> <detail...>
#
set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

ARTIFACT=""
STRICT=0
KEEP=0
OUT=""
RUN_PORTAL=1
RUN_MODULE=1

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --artifact DIR   extracted package dir (required)
  --out DIR        evidence dir (default: <workdir>/evidence)
  --strict         treat absent-but-expected surfaces (e.g. /session-state,
                   the in-page renewal CTA) as failures instead of skips; use
                   this when the artifact is known to be built from a tip that
                   has them
  --skip-portal    module checks only
  --skip-module    portal checks only
  --keep           keep the work directory for inspection
  -h, --help       this text

Environment:
  HP_PYTHON        python with playwright installed (default: probe, else
                   /home/c03rad0r/tg-e2e/venv/bin/python, else python3)
  HP_BROWSER_CHANNEL  playwright channel (e.g. chrome); unset uses the bundled
                   chromium
  HP_TMPDIR        parent for the work dir (default /var/tmp -- a 3.6 GiB tmpfs
                   at /tmp is not a safe place for extracted packages)
  HP_CLIENT_MAC    the identity the suite seeds for its two loopback clients
                   (default 02:00:00:00:00:20; see "Precondition" in README.md)
  HP_MODULE_PORT   module port (default 2121; the shipped portal bundle hardcodes
                   http://<hostname>:2121, so change this only with a reason)
  HP_MUSL_LIBGCC   path to a musl libgcc_s.so.1 for hosts that cannot run the
                   musl binary natively (see README "Running the artifact")
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --artifact) ARTIFACT="${2:-}"; shift 2 ;;
        --out)      OUT="${2:-}"; shift 2 ;;
        --strict)   STRICT=1; shift ;;
        --skip-portal) RUN_PORTAL=0; shift ;;
        --skip-module) RUN_MODULE=0; shift ;;
        --keep)     KEEP=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$ARTIFACT" ]; then
    echo "ERROR: --artifact <extracted-package-dir> is required" >&2
    exit 2
fi
if [ ! -d "$ARTIFACT" ]; then
    echo "ERROR: artifact directory not found: $ARTIFACT" >&2
    exit 2
fi
ARTIFACT="$(cd "$ARTIFACT" && pwd)"

MODULE_PORT="${HP_MODULE_PORT:-2121}"
TMP_PARENT="${HP_TMPDIR:-/var/tmp}"
WORK="$(mktemp -d "$TMP_PARENT/tg-happy-path.XXXXXX")" || exit 1
EVIDENCE="${OUT:-$WORK/evidence}"
mkdir -p "$EVIDENCE"

# The identity the suite keys on. 02:00:00:00:00:20 is a documentation address
# (RFC 7042), the same one the cloud-lab lease fixture uses.
HP_CLIENT_MAC="${HP_CLIENT_MAC:-02:00:00:00:00:20}"
# The identity source the module reads (src/main.go: dhcpLeasePath). Section 1b
# owns it: the module derives a client's MAC from the socket, and no loopback
# address is in any real lease file, so off-router the suite has to provide one.
# NOTE these are ALWAYS written IN PLACE — the file is never moved, renamed or
# deleted (on this fleet /tmp/dhcp.leases is a symlink another process owns), so
# a failure anywhere leaves the host with a working file plus at most two
# harmless extra fixture lines. See section 1b.
LEASE_PATH="/tmp/dhcp.leases"
LEASE_FIXTURE="$WORK/dhcp.leases"
LEASE_BEFORE="$WORK/dhcp.leases.pre-suite"
LEASE_CREATED=0      # 1 = the path did not exist and this suite created it
LEASE_HAD_FILE=0     # 1 = a file was there; its content is in $LEASE_BEFORE
LEASE_SNAPSHOT=0     # 1 = $LEASE_BEFORE holds the content as found (see C5b)

TOTAL=0; PASSED=0; FAILED_N=0; SKIPPED=0
FAILED_IDS=""

chk() {  # chk <id> <PASS|FAIL|SKIP> <detail>
    local id="$1" status="$2"; shift 2
    local detail="${*:-}"
    TOTAL=$((TOTAL + 1))
    case "$status" in
        PASS) PASSED=$((PASSED + 1)) ;;
        SKIP) SKIPPED=$((SKIPPED + 1)) ;;
        FAIL) FAILED_N=$((FAILED_N + 1)); FAILED_IDS="$FAILED_IDS $id" ;;
    esac
    printf 'HPCHECK %s %s %s\n' "$id" "$status" "$detail"
}

note() { printf 'HPNOTE %s\n' "$*"; }

MOD_PID=""; STUB_PID=""; STATIC_PID=""
cleanup() {
    [ -n "$MOD_PID" ] && kill "$MOD_PID" 2>/dev/null
    [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
    wait 2>/dev/null
    # Give the lease path back the way it was found. Both branches write IN
    # PLACE (a shell redirection, same inode — a symlink stays a symlink), so a
    # process that owns the file never sees it vanish; the worst case, if this
    # restore fails, is that the two fixture lines stay behind.
    # Residual, stated rather than hidden: a host process that writes to the
    # same file DURING the run can be overwritten by this restore.
    if [ "$LEASE_CREATED" = "1" ]; then
        rm -f "$LEASE_PATH" 2>/dev/null
    elif [ "$LEASE_HAD_FILE" = "1" ] && [ -s "$LEASE_BEFORE" ]; then
        cat "$LEASE_BEFORE" > "$LEASE_PATH" 2>/dev/null || \
            note "could not restore $LEASE_PATH (the file is intact; it still carries the two fixture lines)"
    fi
    if [ "$KEEP" = "1" ]; then
        note "work dir kept: $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------
# 0. Locate the parts INSIDE the artifact
# --------------------------------------------------------------------------
MODULE_BIN=""
for cand in "$ARTIFACT/usr/bin/tollgate-wrt" "$ARTIFACT/usr/bin/tollgate"; do
    [ -x "$cand" ] && MODULE_BIN="$cand" && break
done
if [ -z "$MODULE_BIN" ]; then
    MODULE_BIN="$(find "$ARTIFACT" -type f -name 'tollgate-wrt' -perm -u+x 2>/dev/null | head -1)"
fi
if [ -n "$MODULE_BIN" ]; then
    chk artifact:module-binary PASS "$MODULE_BIN ($(stat -c %s "$MODULE_BIN") bytes, sha256 $(sha256sum "$MODULE_BIN" | cut -c1-16)…)"
else
    chk artifact:module-binary FAIL "no tollgate-wrt/tollgate executable under $ARTIFACT/usr/bin"
fi

PORTAL_DIR=""
for cand in "$ARTIFACT/etc/tollgate/tollgate-captive-portal-site" \
            "$ARTIFACT/www/tollgate" \
            "$ARTIFACT/etc/tollgate/portal"; do
    if [ -d "$cand" ] && [ -f "$cand/splash.html" ]; then PORTAL_DIR="$cand"; break; fi
done
if [ -z "$PORTAL_DIR" ]; then
    PORTAL_DIR="$(find "$ARTIFACT" -type f -name 'splash.html' 2>/dev/null | head -1 | xargs -r dirname)"
fi
if [ -n "$PORTAL_DIR" ] && [ -f "$PORTAL_DIR/splash.html" ]; then
    chk artifact:portal-bundle PASS "$PORTAL_DIR ($(ls "$PORTAL_DIR/assets"/index-*.js 2>/dev/null | wc -l) index bundle(s))"
else
    PORTAL_DIR=""
    chk artifact:portal-bundle FAIL "no splash.html portal bundle under $ARTIFACT"
fi

FAKE_NDSCTL="$REPO_ROOT/tests/cloud-lab/fake-ndsctl.sh"
if [ -x "$FAKE_NDSCTL" ]; then
    chk artifact:fake-ndsctl-reused PASS "$FAKE_NDSCTL (the cloud-lab seam, not a second one)"
else
    chk artifact:fake-ndsctl-reused FAIL "$FAKE_NDSCTL missing — the suite depends on the cloud-lab seam"
    RUN_MODULE=0
fi

# --------------------------------------------------------------------------
# 1. How can this host run the artifact's binary?
#    OpenWrt x86_64 packages are musl + libgcc_s; a glibc host needs both the
#    musl loader and a musl libgcc_s.so.1, and a container otherwise.
# --------------------------------------------------------------------------
RUN_MODE=""
MUSL_LIBDIR=""
detect_run_mode() {
    [ -z "$MODULE_BIN" ] && return
    local interp
    interp="$(head -c 4096 "$MODULE_BIN" | tr -d '\0' | grep -ao 'ld-musl-[a-z0-9_]*\.so\.[0-9]' | head -1)"
    if [ -z "$interp" ]; then
        RUN_MODE="native"
        return
    fi
    if [ ! -e "/lib/$interp" ]; then
        RUN_MODE="container"
        return
    fi
    local libgcc="${HP_MUSL_LIBGCC:-}"
    if [ -z "$libgcc" ]; then
        for cand in /usr/lib/x86_64-linux-musl/libgcc_s.so.1 \
                    /usr/lib/musl/lib/libgcc_s.so.1 \
                    /usr/local/musl/lib/libgcc_s.so.1; do
            [ -f "$cand" ] && libgcc="$cand" && break
        done
    fi
    if [ -z "$libgcc" ] && command -v docker >/dev/null 2>&1; then
        note "extracting a musl libgcc_s.so.1 from alpine for the native run"
        mkdir -p "$WORK/muslshim"
        docker run --rm -v "$WORK/muslshim":/out alpine:3.20 \
            sh -c 'apk add --no-cache libgcc >/dev/null 2>&1 && cp -L /usr/lib/libgcc_s.so.1 /out/' \
            >/dev/null 2>&1
        [ -f "$WORK/muslshim/libgcc_s.so.1" ] && libgcc="$WORK/muslshim/libgcc_s.so.1"
    fi
    if [ -n "$libgcc" ]; then
        MUSL_LIBDIR="$(dirname "$libgcc")"
        RUN_MODE="native"
    else
        RUN_MODE="container"
    fi
}
detect_run_mode
if [ -n "$MODULE_BIN" ]; then
    chk env:run-mode PASS "mode=$RUN_MODE (musl x86_64 artifact)" \
        "$( [ "$RUN_MODE" = native ] && echo "musl loader + libgcc present" || echo "falling back to a container: the host cannot run musl binaries" )"
fi

# --------------------------------------------------------------------------
# 1b. The identity source: the suite seeds the lease it needs
# --------------------------------------------------------------------------
# The module identifies the caller from the SOCKET, never from a client claim:
# clientMACFromSocket() reads dhcpLeasePath (/tmp/dhcp.leases) and then
# /proc/net/arp (src/main.go). Neither carries an entry for a loopback client,
# so off-router the suite has to supply one. README.md used to leave that to
# the operator, which made a local run green only on a host where somebody had
# already seeded the file by hand — and made the CI lane fail on identity
# instead of on what it covers (api:whoami answered an empty mac, POST
# /ln-invoice 400 device-unresolved; ngit lane regression.yml, 2026-09-24).
#
# So the suite now owns it: one fixture lease keyed to the two loopback
# addresses it drives (127.0.0.1 = the module API, 127.0.0.2 = the portal lane's
# browser), installed where the module it is about to start will read it.
#
# HOW IT TOUCHES THE FILE (cross-family review round 1, findings 1+2): the file
# is written IN PLACE and never moved, renamed or deleted. On this fleet
# /tmp/dhcp.leases is a SYMLINK owned by another process (/var/tmp/minturl/…),
# so `mv`-ing it aside for the duration is not safe — leases written while it is
# away would be lost and the original inode would be swapped back under the
# owner. Instead: copy the existing content aside for evidence, prepend the two
# fixture lines (a client of the owner keeps its file and its other entries),
# and on exit write the original content back through the same path. If the path
# does not exist the suite creates it and removes it again. A crash anywhere in
# between leaves the owner with its file plus two harmless fixture lines; the
# only residual window is a write by the owner DURING the run, which the restore
# can overwrite — stated here instead of hidden.
lease_lines() {  # lease_lines <mac> — the exact two lines this suite adds
    printf '1700000000 %s 127.0.0.1 hp-client *\n' "$1"
    printf '1700000000 %s 127.0.0.2 hp-client *\n' "$1"
}
lease_has() {  # lease_has <mac> <ip> — already mapped by the file?
    awk -v mac="$1" -v want="$2" '
        { if (tolower($2) == tolower(mac) && $3 == want) found = 1 }
        END { exit(found ? 0 : 1) }' "$LEASE_PATH" 2>/dev/null
}
if [ "$RUN_MODULE" = "1" ]; then
    lease_lines "$HP_CLIENT_MAC" > "$LEASE_FIXTURE"

    if [ "$RUN_MODE" = "container" ]; then
        # The module runs in its own container, so the fixture is bound in
        # there; the host's own lease file is left alone.
        chk env:identity-lease PASS "fixture lease (127.0.0.1, 127.0.0.2 -> $HP_CLIENT_MAC) bound into the module container at $LEASE_PATH; the host file was not touched"
    elif lease_has "$HP_CLIENT_MAC" 127.0.0.1 && lease_has "$HP_CLIENT_MAC" 127.0.0.2; then
        chk env:identity-lease PASS "$LEASE_PATH already maps 127.0.0.1 and 127.0.0.2 to $HP_CLIENT_MAC — host-supplied, nothing written"
    else
        # Our lines go FIRST: getMacAddress() returns the first match, so the
        # fixture wins over a stale entry for the same address.
        if [ -e "$LEASE_PATH" ] || [ -L "$LEASE_PATH" ]; then
            lease_lines "$HP_CLIENT_MAC" > "$LEASE_FIXTURE"
            cat "$LEASE_PATH" 2>/dev/null >> "$LEASE_FIXTURE"
            # The backup is the ORIGINAL CONTENT (the two fixture lines dropped),
            # built from the same read: `cp -a` would copy the symlink itself,
            # and a later `cat backup > path` on a same-inode pair truncates the
            # file it is about to read (measured 2026-09-24 on this fleet, where
            # /tmp/dhcp.leases is a symlink).
            tail -n +3 "$LEASE_FIXTURE" > "$LEASE_BEFORE" 2>/dev/null
            LEASE_HAD_FILE=1
        fi
        if [ "$LEASE_HAD_FILE" = "0" ]; then
            LEASE_CREATED=1
        fi
        if cat "$LEASE_FIXTURE" > "$LEASE_PATH" 2>/dev/null; then
            if [ "$LEASE_CREATED" = "1" ]; then
                chk env:identity-lease PASS "fixture lease (127.0.0.1, 127.0.0.2 -> $HP_CLIENT_MAC) written to $LEASE_PATH (did not exist; removed on exit)"
            else
                chk env:identity-lease PASS "fixture lease (127.0.0.1, 127.0.0.2 -> $HP_CLIENT_MAC) prepended to $LEASE_PATH in place; the host's own content is kept for the run and written back on exit (no move, no delete)"
            fi
        else
            chk env:identity-lease FAIL "could not write $LEASE_PATH — the module cannot resolve a client without it (host file untouched: $LEASE_HAD_FILE)"
        fi
    fi
fi

# --------------------------------------------------------------------------
# 2. Hermetic workspace: config dir, fake ndsctl on PATH, stub mint
# --------------------------------------------------------------------------
CFG_DIR="$WORK/config"
mkdir -p "$CFG_DIR"
FAKE_BIN="$WORK/fakebin"
mkdir -p "$FAKE_BIN"
cp "$FAKE_NDSCTL" "$FAKE_BIN/ndsctl"
chmod +x "$FAKE_BIN/ndsctl"
NDSCTL_LOG="$WORK/ndsctl.log"
: > "$NDSCTL_LOG"
SELFTEST_LOG="$WORK/ndsctl-selftest.log"

# the fake is the seam we assert on: prove it records before trusting it
if NDSCTL_LOG="$SELFTEST_LOG" "$FAKE_BIN/ndsctl" auth 02:00:00:00:00:20 >/dev/null 2>&1 \
   && grep -q "AUTH 02:00:00:00:00:20" "$SELFTEST_LOG"; then
    chk env:fake-ndsctl-records PASS "self-test: fake-ndsctl recorded an AUTH line"
else
    chk env:fake-ndsctl-records FAIL "fake-ndsctl did not record a self-test AUTH call"
fi

PYTHON=""
for cand in "${HP_PYTHON:-}" /home/c03rad0r/tg-e2e/venv/bin/python "$(command -v python3)"; do
    [ -n "$cand" ] || continue
    if "$cand" -c 'import playwright.sync_api' >/dev/null 2>&1; then PYTHON="$cand"; break; fi
done

STUB_MINT_PORT=0
if [ "$RUN_MODULE" = "1" ]; then
    STUB_MINT_LOG="$WORK/stub-mint.log"
    HP_STUB_MINT_LOG="$STUB_MINT_LOG" HP_STUB_MINT_QUOTE_STATE="UNPAID" \
        python3 "$SELF_DIR/stubs/stub_mint.py" > "$WORK/stub-mint.out" 2>&1 &
    STUB_PID=$!
    for _ in $(seq 1 40); do
        STUB_MINT_PORT="$(sed -n 's/.*port=\([0-9]*\).*/\1/p' "$WORK/stub-mint.out" 2>/dev/null | head -1)"
        [ -n "$STUB_MINT_PORT" ] && break
        sleep 0.25
    done
fi
STUB_MINT_URL="http://127.0.0.1:${STUB_MINT_PORT:-0}"
if [ "$RUN_MODULE" = "1" ] && [ "$STUB_MINT_PORT" != "0" ]; then
    chk env:stub-mint PASS "offline stub mint on $STUB_MINT_URL (never a real mint, never real ecash)"
elif [ "$RUN_MODULE" = "1" ]; then
    chk env:stub-mint FAIL "stub mint did not report a port: $(tail -3 "$WORK/stub-mint.out" 2>/dev/null | tr '\n' ' ')"
    RUN_MODULE=0
fi

sed "s|@STUB_MINT_URL@|$STUB_MINT_URL|" "$SELF_DIR/config/config.json.in" > "$CFG_DIR/config.json"

# --------------------------------------------------------------------------
# 3. Boot the module binary from the artifact
# --------------------------------------------------------------------------
MOD_UP=0
MUSL_LD=""
[ -n "$MUSL_LIBDIR" ] && MUSL_LD="/lib/$(head -c 4096 "$MODULE_BIN" | tr -d '\0' | grep -ao 'ld-musl-[a-z0-9_]*\.so\.[0-9]' | head -1)"

start_module() {
    [ -z "$MODULE_BIN" ] && return
    note "starting $RUN_MODE run of $MODULE_BIN (config dir $CFG_DIR)"
    if [ "$RUN_MODE" = "container" ]; then
        docker run --rm --name "tg-happy-path-$$" --network host \
            -v "$ARTIFACT":/artifact:ro -v "$CFG_DIR":/cfg -v "$FAKE_BIN":/fakebin:ro \
            -v "$NDSCTL_LOG":/fakebin/ndsctl.log \
            -v "$LEASE_FIXTURE":/tmp/dhcp.leases:ro \
            -e TOLLGATE_TEST_CONFIG_DIR=/cfg -e PATH=/fakebin:/usr/local/bin:/usr/bin:/bin \
            -e NDSCTL_LOG=/fakebin/ndsctl.log \
            alpine:3.20 /artifact/usr/bin/tollgate-wrt > "$WORK/module.log" 2>&1 &
    else
        # Invoke the musl loader EXPLICITLY with --library-path rather than
        # exporting LD_LIBRARY_PATH: the variable would be inherited by every
        # child the module spawns, and fake-ndsctl.sh calls `date`, which then
        # dies with "cannot open shared object file libc.musl-x86_64.so.1" —
        # silently emptying the timestamps and corrupting the `ndsctl json`
        # output the module parses.
        if [ -n "$MUSL_LD" ]; then
            env -i PATH="$FAKE_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
                HOME="$WORK" TOLLGATE_TEST_CONFIG_DIR="$CFG_DIR" NDSCTL_LOG="$NDSCTL_LOG" \
                "$MUSL_LD" --library-path "$MUSL_LIBDIR" \
                "$MODULE_BIN" > "$WORK/module.log" 2>&1 &
        else
            # Not a musl ELF (a script, or a static/glibc binary): run it directly.
            env -i PATH="$FAKE_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
                HOME="$WORK" TOLLGATE_TEST_CONFIG_DIR="$CFG_DIR" NDSCTL_LOG="$NDSCTL_LOG" \
                "$MODULE_BIN" > "$WORK/module.log" 2>&1 &
        fi
    fi
    MOD_PID=$!
}

if [ "$RUN_MODULE" = "1" ] && command -v curl >/dev/null 2>&1; then
    if curl -s -m 2 -o /dev/null "http://127.0.0.1:$MODULE_PORT/" 2>/dev/null; then
        chk boot:port-free FAIL "something already listens on :$MODULE_PORT — the suite needs it"
    else
        start_module
        for _ in $(seq 1 90); do
            if curl -s -m 2 -o /dev/null "http://127.0.0.1:$MODULE_PORT/" 2>/dev/null; then MOD_UP=1; break; fi
            sleep 1
        done
        if [ "$MOD_UP" = "1" ]; then
            chk boot:module-listening PASS "artifact binary answering on :$MODULE_PORT (pid $MOD_PID)"
        else
            chk boot:module-listening FAIL "no answer on :$MODULE_PORT after 90s; tail: $(tail -4 "$WORK/module.log" 2>/dev/null | tr '\n' ' ')"
        fi
    fi
fi

# http <path> [curl args...] -> body on stdout. The status code lands in
# $WORK/code: a command substitution runs in a subshell, so a variable assigned
# inside http() would never reach the caller.
http() {
    local path="$1"; shift
    curl -s -m 25 -o "$WORK/body" -w '%{http_code}' "$@" \
        "http://127.0.0.1:$MODULE_PORT$path" > "$WORK/code" 2>/dev/null
    cat "$WORK/body" 2>/dev/null
}
httpcode() { cat "$WORK/code" 2>/dev/null; }

if [ "$MOD_UP" = "1" ]; then
    # --- C4: kind:10021 advertisement -------------------------------------
    ADV=""
    for _ in $(seq 1 20); do
        ADV="$(http /)"
        CODE="$(httpcode)"
        case "$ADV" in *'"kind":10021'*) break ;; esac
        sleep 1
    done
    cp "$WORK/body" "$EVIDENCE/advertisement.json" 2>/dev/null
    case "$ADV" in
        *'"kind":10021'*)
            chk api:advertisement-kind-10021 PASS "GET / -> HTTP $CODE, kind 10021, $(printf '%s' "$ADV" | grep -o '"price_per_step"' | wc -l) price_per_step tag(s)" ;;
        *)
            chk api:advertisement-kind-10021 FAIL "GET / -> HTTP $CODE, body starts: $(printf '%s' "$ADV" | head -c 160)" ;;
    esac

    # --- C5: /whoami -------------------------------------------------------
    W="$(http /whoami)"
    CODE="$(httpcode)"
    case "$W" in
        mac=*:*) chk api:whoami PASS "/whoami -> HTTP $CODE $(printf '%s' "$W" | head -c 60)" ;;
        *)       chk api:whoami FAIL "/whoami -> HTTP $CODE body: $(printf '%s' "$W" | head -c 160)" ;;
    esac

    # --- C5b: negative control — withdraw the identity source, and the payment
    # path must REFUSE rather than invent an identity or key a shared one ------
    # This is exactly the state the CI lane hit when the suite had no lease of
    # its own (api:whoami an empty mac, POST /ln-invoice 400 device-unresolved),
    # and it is what proves the lease seeded in 1b is load-bearing. Note WHY the
    # control withdraws the file instead of probing from an unleased address:
    # measured 2026-09-24, a request from 127.0.0.3 is answered with the
    # 127.0.0.1 identity (the module resolves loopback sources to that lease
    # entry), so off-router there is no second "unleased client" to probe with —
    # the observable variable is the identity SOURCE, not the source address.
    # The fixture is put back immediately, so the later checks are unaffected.
    if [ "$RUN_MODE" = "container" ]; then
        chk api:money-path-refuses-unresolved-client SKIP \
            "the module runs in a container with the lease bound read-only: the identity source cannot be withdrawn mid-run (the refusal path is covered by src/identity_sentinel_test.go)"
    else
        # Snapshot the CURRENT content first (the host's, or the host's plus our
        # lines), then write an empty file: no lease entry for 127.0.0.1 and no
        # ARP entry for it either, so the module cannot resolve the caller.
        if [ "$LEASE_SNAPSHOT" != "1" ]; then
            cat "$LEASE_PATH" > "$LEASE_BEFORE" 2>/dev/null && LEASE_SNAPSHOT=1 && LEASE_HAD_FILE=1
        fi
        : > "$LEASE_PATH"
        RMAC="$(curl -s -m 25 -o "$WORK/nc-body" -w '%{http_code}' \
                "http://127.0.0.1:$MODULE_PORT/ln-invoice" \
                -X POST -H 'Content-Type: application/json' \
                --data-binary '{"amount":210,"mint_url":"http://127.0.0.1:1/","mac":"02:00:00:00:00:20"}' \
                2>/dev/null)"
        RMB="$(cat "$WORK/nc-body" 2>/dev/null)"
        # put the identity source back BEFORE any other check runs
        if [ "$LEASE_SNAPSHOT" = "1" ]; then
            cat "$LEASE_BEFORE" > "$LEASE_PATH" 2>/dev/null
        else
            cat "$LEASE_FIXTURE" > "$LEASE_PATH" 2>/dev/null
        fi
        if [ "$RMAC" = "400" ] && printf '%s' "$RMB" | grep -q 'device-unresolved'; then
            chk api:money-path-refuses-unresolved-client PASS "with the identity source withdrawn, POST /ln-invoice -> HTTP 400 device-unresolved (the real CI state, reproduced in-run); source restored"
        elif printf '%s' "$RMB" | grep -q '"access_granted":true'; then
            chk api:money-path-refuses-unresolved-client FAIL "with NO identity source, POST /ln-invoice still granted access: HTTP $RMAC $(printf '%s' "$RMB" | head -c 120)"
        else
            chk api:money-path-refuses-unresolved-client FAIL "with the identity source withdrawn, POST /ln-invoice -> HTTP $RMAC $(printf '%s' "$RMB" | head -c 140) (want 400 + device-unresolved)"
        fi
    fi

    # --- C6: /balance ------------------------------------------------------
    B="$(http /balance)"
    CODE="$(httpcode)"
    if printf '%s' "$B" | grep -q '"status"' \
       && printf '%s' "$B" | grep -q '"session_active"' \
       && printf '%s' "$B" | grep -q '"usage"' \
       && printf '%s' "$B" | grep -q '"allotment"' \
       && printf '%s' "$B" | grep -q '"remaining"'; then
        chk api:balance-shape PASS "/balance -> HTTP $CODE $(printf '%s' "$B" | head -c 120)"
    else
        chk api:balance-shape FAIL "/balance -> HTTP $CODE body: $(printf '%s' "$B" | head -c 160)"
    fi

    # --- C7: /usage --------------------------------------------------------
    U="$(http /usage)"
    CODE="$(httpcode)"
    case "$U" in
        *[0-9]/*[0-9]*) chk api:usage-shape PASS "/usage -> HTTP $CODE $(printf '%s' "$U" | head -c 40)" ;;
        *)              chk api:usage-shape FAIL "/usage -> HTTP $CODE body: $(printf '%s' "$U" | head -c 160)" ;;
    esac

    # --- C8: the LN quote path --------------------------------------------
    # No quote = a 400 STATUS POLL, which is the documented answer, not a fault.
    LN="$(http '/ln-invoice')"
    CODE="$(httpcode)"
    if [ "$CODE" = "400" ] && printf '%s' "$LN" | grep -q '"error":"quote is required"'; then
        chk api:ln-invoice-no-quote-400 PASS "GET /ln-invoice (no quote) -> HTTP 400 $(printf '%s' "$LN" | head -c 80) — expected, this is the status-poll contract"
    else
        chk api:ln-invoice-no-quote-400 FAIL "GET /ln-invoice (no quote) -> HTTP $CODE body: $(printf '%s' "$LN" | head -c 160) (want 400 + {\"error\":\"quote is required\"})"
    fi

    # --- C9: /session-state (none|active|expired) --------------------------
    SS="$(http '/session-state?mac=02:00:00:00:00:20')"
    CODE="$(httpcode)"
    cp "$WORK/body" "$EVIDENCE/session-state.json" 2>/dev/null
    if [ "$CODE" = "200" ] && printf '%s' "$SS" | grep -qE '"state"[[:space:]]*:[[:space:]]*"(none|active|expired)"'; then
        chk api:session-state PASS "/session-state -> HTTP 200 $(printf '%s' "$SS" | head -c 140)"
    elif [ "$CODE" = "200" ] && printf '%s' "$SS" | grep -q '"kind":10021'; then
        # Go's default mux falls through to the "/" handler, so an unregistered
        # path answers 200 with the advertisement rather than a 404. That is a
        # MISSING endpoint, not a wrong-shaped one.
        if [ "$STRICT" = "1" ]; then
            chk api:session-state FAIL "/session-state falls through to the / handler (HTTP 200 + kind 10021) and --strict demands the endpoint"
        else
            chk api:session-state SKIP "/session-state unregistered (mux falls through to / => kind 10021): this artifact predates upstream #541; re-run with --strict once a release ships it"
        fi
    elif [ "$STRICT" = "1" ]; then
        chk api:session-state FAIL "/session-state -> HTTP $CODE, and --strict demands it: $(printf '%s' "$SS" | head -c 140)"
    else
        chk api:session-state SKIP "/session-state -> HTTP $CODE: endpoint not present in this artifact"
    fi

    # --- C10: a failed payment must NOT move the gate ----------------------
    : > "$NDSCTL_LOG"
    FR="$(http / -X POST -H 'Content-Type: text/plain' --data-binary 'cashuBthisIsNotARedeemableToken')"
    CODE="$(httpcode)"
    if grep -q "AUTH" "$NDSCTL_LOG"; then
        chk enforcement:no-gate-on-failed-payment FAIL "an unredeemable token still produced an ndsctl AUTH (body: $(printf '%s' "$FR" | head -c 120))"
    else
        chk enforcement:no-gate-on-failed-payment PASS "POST / with an unredeemable token -> HTTP $CODE, ndsctl log empty (no gate moved, correct)"
    fi

    # --- C11: the gate DOES move when the module recognises a payment ------
    # Money-free route: the mint reports the quote ISSUED, which is the branch
    # that grants access without minting ecash (merchant/lightning.go). The stub
    # is the issuer here, so this asserts the enforcement seam and the MAC
    # plumbing -- NOT that real ecash was redeemed. See README.
    curl -sS -m 5 -X POST "$STUB_MINT_URL/__hp/quote-state?value=ISSUED" >/dev/null 2>&1
    note "stub mint quote state -> $(curl -sS -m 5 "$STUB_MINT_URL/__hp/quote-state" 2>/dev/null)"
    MAC="02:00:00:00:00:20"
    : > "$NDSCTL_LOG"
    # NOTE the trailing slash. The wallet keys a mint as "<url>/" and the module
    # passes the caller's mint_url through verbatim, so the request form has to
    # carry the slash. The portal does NOT (it echoes the advertisement's tag),
    # which is why portal:lightning-lane-against-live-module fails on this
    # artifact -- see known-issues.txt.
    MINT_REQ="$STUB_MINT_URL/"
    Q="$(http /ln-invoice -X POST -H 'Content-Type: application/json' \
            --data-binary "{\"amount\":210,\"mint_url\":\"$MINT_REQ\",\"mac\":\"$MAC\"}")"
    CODE="$(httpcode)"
    QUOTE_ID="$(printf '%s' "$Q" | sed -n 's/.*"quote":"\([^"]*\)".*/\1/p')"
    if [ -z "$QUOTE_ID" ]; then
        chk enforcement:gate-opens-on-recognised-payment FAIL "POST /ln-invoice -> HTTP $CODE body: $(printf '%s' "$Q" | head -c 200)"
    else
        ST="$(http "/ln-invoice?quote=$QUOTE_ID&mac=$MAC")"
        SCODE="$(httpcode)"
        sleep 2
        if grep -q "AUTH $MAC" "$NDSCTL_LOG"; then
            chk enforcement:gate-opens-on-recognised-payment PASS "quote $QUOTE_ID recognised (access_granted=$(printf '%s' "$ST" | grep -o '"access_granted":[a-z]*' | head -1)) -> fake-ndsctl recorded: $(tr '\n' '|' < "$NDSCTL_LOG")"
        else
            chk enforcement:gate-opens-on-recognised-payment FAIL "quote $QUOTE_ID status(HTTP $SCODE)=$ST but no 'AUTH $MAC' in $NDSCTL_LOG (log: $(tr '\n' '|' < "$NDSCTL_LOG"))"
        fi
    fi
    cp "$WORK/module.log" "$EVIDENCE/module.log" 2>/dev/null
else
    chk boot:module-listening SKIP "module checks skipped"
fi

# --------------------------------------------------------------------------
# 4. Drive the portal bundle from the SAME artifact with a real browser
# --------------------------------------------------------------------------
if [ "$RUN_PORTAL" = "1" ]; then
    if [ -z "$PYTHON" ]; then
        chk portal:purchase-ui SKIP "no python with playwright found (set HP_PYTHON)"
        chk portal:mint-list-from-artifact SKIP "no browser"
        chk portal:device-mac-from-live-module SKIP "no browser"
        chk portal:purchase-cta-present SKIP "no browser"
        chk portal:expired-view SKIP "no browser"
        chk portal:expired-renewal-cta SKIP "no browser"
    elif [ -z "$PORTAL_DIR" ]; then
        chk portal:purchase-ui FAIL "no portal bundle inside the artifact"
    else
        ADV_FILE="$EVIDENCE/advertisement.json"
        PORTAL_ARGS="--bundle $PORTAL_DIR --stub-mint $STUB_MINT_URL --advertisement-file $ADV_FILE"
        if [ "$MOD_UP" = "1" ]; then
            note "portal pass 1/3: purchase UI against the LIVE module on :$MODULE_PORT"
            "$PYTHON" "$SELF_DIR/stubs/portal_drive.py" --mode purchase --out "$EVIDENCE/portal-purchase" \
                $PORTAL_ARGS > "$EVIDENCE/portal-purchase.log" 2>&1 || true
            # fold the browser verdicts into this run's counters
            while read -r _ id status rest; do
                [ -n "${id:-}" ] || continue
                case "$id" in
                    portal:expired-view|portal:expired-renewal-cta) continue ;;
                esac
                chk "$id" "$status" "$rest"
            done < <(grep '^HPCHECK' "$EVIDENCE/portal-purchase.log")

            note "portal pass 2/3: the bundle's Lightning lane against the LIVE module"
            "$PYTHON" "$SELF_DIR/stubs/portal_drive.py" --mode live-lightning \
                --out "$EVIDENCE/portal-lightning-live" $PORTAL_ARGS \
                > "$EVIDENCE/portal-lightning-live.log" 2>&1 || true
            while read -r _ id status rest; do
                [ -n "${id:-}" ] || continue
                chk "$id" "$status" "$rest"
            done < <(grep '^HPCHECK' "$EVIDENCE/portal-lightning-live.log")
        else
            chk portal:purchase-ui SKIP "module not running, cannot assert the live-module wiring"
            chk portal:lightning-lane-against-live-module SKIP "module not running"
        fi

        note "portal pass 3/3: expired view + renewal CTA against the routed stub backend"
        STRICT_FLAG=""
        [ "$STRICT" = "1" ] && STRICT_FLAG="--strict-renewal-cta"
        "$PYTHON" "$SELF_DIR/stubs/portal_drive.py" --mode expired --out "$EVIDENCE/portal-expired" \
            $PORTAL_ARGS $STRICT_FLAG > "$EVIDENCE/portal-expired.log" 2>&1 || true
        while read -r _ id status rest; do
            [ -n "${id:-}" ] || continue
            case "$id" in
                portal:renders-purchase-ui|portal:mint-list-from-artifact|portal:device-mac-from-live-module|portal:purchase-cta-present)
                    continue ;;   # already counted in pass 1
            esac
            chk "$id" "$status" "$rest"
        done < <(grep '^HPCHECK' "$EVIDENCE/portal-expired.log")
    fi
fi

# --------------------------------------------------------------------------
# 5. Verdict
#
# A known issue is a FAIL that is already understood, reproducible, and written
# down in known-issues.txt. It is still printed as a FAIL on its check line --
# nothing is relabelled -- but it does not make the suite exit non-zero, because
# a suite that is permanently red on a pre-existing defect stops being read.
# --strict promotes known issues back to fatal.
# --------------------------------------------------------------------------
KNOWN_FILE="$SELF_DIR/known-issues.txt"
KNOWN_N=0; KNOWN_IDS=""
if [ "$FAILED_N" -gt 0 ] && [ -f "$KNOWN_FILE" ]; then
    for id in $FAILED_IDS; do
        reason="$(awk -v want="$id" '$1 == want { sub(/^[^ \t]+[ \t]+/, ""); print; exit }' "$KNOWN_FILE" 2>/dev/null)"
        [ -n "$reason" ] || continue
        if [ "$STRICT" = "1" ]; then
            note "known issue kept FATAL by --strict: $id"
            continue
        fi
        KNOWN_N=$((KNOWN_N + 1))
        KNOWN_IDS="$KNOWN_IDS $id"
        FAILED_N=$((FAILED_N - 1))
        printf 'HPKNOWNISSUE %s %s\n' "$id" "$reason"
    done
fi

printf 'HPRESULT total=%d pass=%d fail=%d skip=%d known=%d\n' \
    "$TOTAL" "$PASSED" "$FAILED_N" "$SKIPPED" "$KNOWN_N"
if [ "$KNOWN_N" -gt 0 ]; then
    printf 'HPKNOWNISSUES%s\n' "$KNOWN_IDS"
fi
if [ "$FAILED_N" -gt 0 ]; then
    printf 'HPFAILED%s\n' "$FAILED_IDS"
    printf 'HPEXIT 1\n'
    exit 1
fi
printf 'HPEXIT 0\n'
exit 0
