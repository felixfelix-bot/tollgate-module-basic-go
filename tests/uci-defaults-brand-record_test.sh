#!/usr/bin/env bash
# Offline test for the BRAND RECORD WRITER in
# packaging/files/etc/uci-defaults/99-tollgate-setup.
#
# WHY THIS TEST EXISTS
#
# The net4sats shell is a thin wrapper that deploys this module. Today the brand
# NEVER reaches the router: the installer mints `!TollGate-<code>` from a literal in
# its own source, nothing anywhere writes the brand record, and load_brand() falls
# back to the default. So a net4sats-branded deploy produces a TollGate-branded
# router, and every gate passes because the brand is read-or-default and never
# asserted. This test is the assertion.
#
# It covers BOTH halves of the contract:
#
#   (A) DE-BRAND IS UNCHANGED. With no brand file and no UCI record, the outcome must
#       be byte-identical to today: token 'tollgate', display spelling 'TollGate'.
#       This is the loop's STEP 4 rule. A branded feature that silently changes what
#       an unbranded router does breaks upstream users to serve ours.
#
#   (B) THE RECORD IS WRITTEN THROUGH. Given a build-input brand file, load_brand()
#       must (1) use it, and (2) persist it as the CANONICAL `uci tollgate.brand`
#       record exactly once, and subsequent reads must PREFER the canonical record
#       over the file — precedence: UCI > file > default 'tollgate'.
#
# Everything runs against a fake `uci` and a fake filesystem — no router.
#
# Usage: bash tests/uci-defaults-brand-record_test.sh
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
mkdir -p "$TMP/bin" "$TMP/etc/tollgate"

# ---------------------------------------------------------------- fake uci
# Flat "key=value" state, the subset the setup script uses. Records every WRITE so
# the test can prove the canonical record was written (and written once).
cat > "$TMP/bin/uci" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
STATE="${UCI_STATE:?UCI_STATE not set}"
WRITES="${UCI_WRITES:-/dev/null}"
quiet=0
[ "${1:-}" = "-q" ] && { quiet=1; shift; }
cmd="${1:-}"; shift || true
state_get() {
    # Exact key first, then any key ending in the requested dotted suffix (so
    # "brand.token" finds the stored "tollgate.brand.token").
    v="$(grep -F -- "$1=" "$STATE" 2>/dev/null | head -n1 | cut -d= -f2-)"
    [ -n "$v" ] || v="$(grep -E -- "\.?$1=" "$STATE" 2>/dev/null | head -n1 | cut -d= -f2-)"
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
}
case "$cmd" in
    get)
        v="$(state_get "$1")"
        [ -n "$v" ] || exit 1
        printf '%s\n' "$v"
        ;;
    set)
        # uci set <conf>.<sec>.<opt>=<val>
        kv="$1"
        printf '%s\n' "$kv" >> "$WRITES"
        key="${kv%%=*}"; val="${kv#*=}"
        # Store under the FULL dotted key and resolve reads by suffix, so a write
        # REPLACES the previous value like a real `uci set` does. Keying on the last
        # component made a seeded value survive a later write, which silently broke
        # the precedence case (the file looked like it had won).
        if grep -qF -- "${key}=" "$STATE" 2>/dev/null; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$STATE"
        else
            printf '%s=%s\n' "$key" "$val" >> "$STATE"
        fi
        ;;
    commit|delete|add_list|del_list)
        [ "$cmd" = "delete" ] && printf 'DELETE %s\n' "${1:-}" >> "$WRITES"
        ;;
    show) sed -n 'p' "$STATE" ;;
esac
exit 0
SHIM
chmod +x "$TMP/bin/uci"

# ------------------------------------------------------- extract the two functions
# Pull the real function bodies and point the LITERAL /etc/tollgate/brand at a
# sandbox path. Only the extracted COPY is rewritten; the tracked script is never
# modified, so these assertions test the shipped source.
extract_fn() { # extract_fn <name>
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { inside=1 }
    inside { print
             n=gsub(/\{/,"{"); m=gsub(/\}/,"}")
             depth += n - m
             if (depth == 0) exit }
  ' "$SCRIPT"
}

LIB="$TMP/lib.sh"
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'LOGFILE="%s/log"\nlog() { echo "$1" >> "$LOGFILE"; }\n' "$TMP"
  printf 'BRAND_FILE="%s/etc/tollgate/brand"\n' "$TMP"
  printf 'BRAND=""\nBRAND_HOSTNAME=""\n'
  extract_fn load_brand | sed "s|/etc/tollgate/brand|${TMP}/etc/tollgate/brand|g"
  extract_fn brand_token | sed "s|/etc/tollgate/brand|${TMP}/etc/tollgate/brand|g"
  printf 'load_brand\n'
  printf 'echo "BRAND=[$BRAND] HOST=[$BRAND_HOSTNAME] TOKEN=[$(brand_token)]"\n'
} > "$LIB"

run() { # run <brandfile-content-or-empty> <uci-brand-record-or-empty> <label>
  local file_content="$1" uci_brand="$2" label="$3"
  : > "$TMP/etc/tollgate/brand"
  [ -n "$file_content" ] && printf '%s\n' "$file_content" > "$TMP/etc/tollgate/brand"
  : > "$TMP/state"; : > "$TMP/writes"
  [ -n "$uci_brand" ] && printf 'tollgate.brand.token=%s\n' "$uci_brand" >> "$TMP/state"
  UCI_STATE="$TMP/state" UCI_WRITES="$TMP/writes" PATH="$TMP/bin:$PATH" bash "$LIB" 2>/dev/null
}

echo "=== (A) DE-BRAND MUST BE BYTE-IDENTICAL TO TODAY ==="
OUT="$(run "" "" "no-brand")"
case "$OUT" in
  *"BRAND=[tollgate]"*"HOST=[TollGate]"*) ok "absent file + absent UCI -> tollgate / TollGate" ;;
  *) bad "de-brand default changed: got '$OUT'" ;;
esac

# An empty file is NOT a brand and must also fall back.
OUT="$(run "" "" "empty-file")"
case "$OUT" in
  *"BRAND=[tollgate]"*) ok "empty brand file -> tollgate (not empty)" ;;
  *) bad "empty file did not fall back: got '$OUT'" ;;
esac

# A malformed token must be coerced, never used.
OUT="$(run 'bad token!' "" "malformed")"
case "$OUT" in
  *"BRAND=[tollgate]"*) ok "malformed token coerced to tollgate" ;;
  *) bad "malformed token was accepted: got '$OUT'" ;;
esac

# Without a brand record the canonical UCI key must NOT be invented.
run "" "" "no-write-check" >/dev/null
if grep -q "brand=" "$TMP/writes" 2>/dev/null; then
  bad "wrote a canonical brand record when there was no brand to record"
else
  ok "no canonical record written when the brand is the default"
fi

echo
echo "=== (B) THE RECORD IS USED AND WRITTEN THROUGH ==="
OUT="$(run "net4sats" "" "brand-from-file")"
case "$OUT" in
  *"BRAND=[net4sats]"*"HOST=[Net4sats]"*) ok "brand file -> net4sats / Net4sats (first-letter capitalisation)" ;;
  *) bad "brand file not honoured: got '$OUT'" ;;
esac

OUT="$(run "net4sats" "" "write-through")"
# The record is written the way the module already writes UCI elsewhere — create the
# section if absent, then set the option (see the tollgate.device precedent).
if grep -q "^tollgate\.brand\.token=net4sats$" "$TMP/writes" 2>/dev/null; then
  ok "canonical record written: tollgate.brand.token=net4sats"
else
  bad "canonical record was NOT written (writes: $(tr '\n' ' ' < "$TMP/writes"))"
fi

# PRECEDENCE: canonical UCI beats the file.
OUT="$(run "otherbrand" "net4sats" "precedence")"
case "$OUT" in
  *"BRAND=[net4sats]"*"HOST=[Net4sats]"*)
    ok "canonical UCI wins over the build-input file (precedence honoured)" ;;
  *) bad "precedence violated — file overrode UCI: got '$OUT'" ;;
esac

# ...and when the canonical record exists and agrees, we do not rewrite it every run.
run "net4sats" "net4sats" "idempotent" >/dev/null
n=$(grep -c "tollgate\.brand\.token=" "$TMP/writes" 2>/dev/null | head -1); n=${n:-0}
if [ "$n" -le 1 ]; then
  ok "write-through is idempotent (wrote the record $n time(s))"
else
  bad "write-through rewrote the canonical record $n times"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 2
