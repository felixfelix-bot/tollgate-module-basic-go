#!/bin/bash
# ============================================================================
# TollGate surface probe v3  (read-only: no auth, no install, no writes)
#
# v3 fixes the three defects found when v2 was run against a real router, and
# adds a deployed-BUILD FINGERPRINT, so the probe can answer
#   "is the alpha4 portal bundle (keyset-agnostic decode + LN004 MAC fix)
#    actually on this router?"
# instead of merely "the port answers".
#
#   defect 1 - FALSE "http=000000".  v2's helper was
#                curl ... -w '%{http_code}' ... || echo 000
#              On a connect failure curl ALREADY prints 000 and exits non-zero,
#              so the `|| echo 000` appended a SECOND one.  v3 has no fallback
#              echo: curl's own 000 is the single 3-digit answer.  Local scratch
#              is mktemp -d + trap (v2 wrote /tmp/_p.html - never do that in a
#              script somebody pipes into bash).
#   defect 2 - HTTPS rows were not evidence.  curl without -k fails the router's
#              self-signed cert, so :443 / :8443 printed 000 even when a TLS
#              listener WAS answering.  v3 probes https with -k and, when the
#              listener answers, prints the peer certificate (subject/issuer/
#              SHA-256 fingerprint/dates) read via openssl s_client.
#   defect 3 - no build fingerprint.  Portal asset filenames are CONTENT-HASHED
#              (index-FEkM58ty.js etc.), so the names the live pages reference -
#              and their bytes - decide WHICH build is deployed.  v3 carries the
#              alpha4 asset table (extracted from
#              tollgate-wrt-0.6.0_alpha4-r0.apk) and reports per asset
#              MATCHES alpha4 / DIFFERS / ABSENT-FROM-ALPHA4, then one verdict.
#
# Read-only by construction: HTTP(S) GETs with --max-time 6, one harmless ssh
# banner probe, openssl s_client for the cert.  Nothing is written to the
# router.
#
# Usage:
#   curl -fsSL <raw-url> | bash
#   bash probe-surfaces-v3.sh 192.168.8.1            # positional (v1/v2 style)
#   TOLLGATE_ROUTER=192.168.8.1 bash probe-surfaces-v3.sh
#   PORTAL_PORT=2051 BALANCE_PORT=2050 ADMIN_PORT=8090 API_PORT=2121 \
#   LUCI_PORT=8080 LUCI_HTTPS_PORT=443 ADMIN_HTTPS_PORT=8443 ...
# ============================================================================
set -u

R="${TOLLGATE_ROUTER:-${1:-192.168.8.1}}"
PORTAL_PORT="${PORTAL_PORT:-2051}"
BALANCE_PORT="${BALANCE_PORT:-2050}"
ADMIN_PORT="${ADMIN_PORT:-8090}"
API_PORT="${API_PORT:-2121}"
LUCI_PORT="${LUCI_PORT:-8080}"
LUCI_HTTPS_PORT="${LUCI_HTTPS_PORT:-443}"
ADMIN_HTTPS_PORT="${ADMIN_HTTPS_PORT:-8443}"
TMO=6

W=$(mktemp -d) || { echo "FATAL: mktemp failed" >&2; exit 1; }
cleanup() { rm -rf "$W"; }
trap cleanup EXIT INT TERM HUP

PAGE="$W/page.html"
BODIES="$W/bodies.tsv"
ASSET="$W/asset.bin"
BODY_N=0
: > "$BODIES"

# code URL -> HTTP status only.  -k so a self-signed cert is not reported as
# 000 (defect 2); NO `|| echo 000` so a connect failure yields exactly "000"
# (defect 1).  Body of the last call is in $PAGE.  $PAGE is truncated first:
# on a connect failure curl leaves the target file untouched, so a stale body
# from the previous probe would otherwise show up as this row's title (false
# evidence - the whole point of the fingerprint is to not do that).
code() {
  : > "$PAGE"
  curl -sk -o "$PAGE" -w '%{http_code}' --max-time "$TMO" "$1" 2>/dev/null
}

# keep_body LABEL FILE -> stash a labelled copy for the version-evidence grep
keep_body() {
  local lbl="$1" src="$2" dst
  BODY_N=$((BODY_N+1))
  dst="$W/body-$BODY_N"
  cp -f "$src" "$dst" 2>/dev/null || return 0
  printf '%s\t%s\n' "$lbl" "$dst" >> "$BODIES"
}

hr() { echo "==================================================================="; }

hr
echo " TollGate surface probe v3 (read-only) | router=$R"
echo " fixes: single-000 (no false 000000) | -k for https | alpha4 build fingerprint"
hr

echo
echo "== device identity (no auth) =="
printf ' %-18s: ' "ssh banner"
banner=$(timeout "$TMO" ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
           -o ConnectTimeout=5 -o PreferredAuthentications=none \
           root@"$R" true 2>&1 | head -1)
printf '%s\n' "${banner:-(no answer on ssh)}"
printf ' %-18s: ' "mDNS name"
mdns=$(timeout 5 getent hosts TollGate.lan 2>/dev/null | head -1)
printf '%s\n' "${mdns:-(no mDNS resolution)}"

echo
echo "== surfaces =="
probe() { # label url
  local label="$1" url="$2" c t m
  c=$(code "$url")
  t=$(grep -oiE '<title>[^<]*' "$PAGE" 2>/dev/null | head -1 | sed -E 's/<title>//i' | tr -d '\r\n')
  m=""
  grep -qiE 'tollgate|cashu|mint' "$PAGE" 2>/dev/null && m=" [mentions TollGate]"
  printf ' %-22s %-44s http=%s  title:%s%s\n' "$label" "$url" "$c" "${t:-none}" "$m"
}
probe "captive portal"        "http://$R:$PORTAL_PORT/splash.html"
probe "balance page (root)"   "http://$R:$BALANCE_PORT/"
probe "config UI (admin SPA)" "http://$R:$ADMIN_PORT/"
probe "merchant API"          "http://$R:$API_PORT/"
probe "LuCI (expect 307)"     "http://$R:$LUCI_PORT/"

echo
echo "== reading these =="
cat <<EOF_LEGEND
 $PORTAL_PORT = captive portal (uhttpd.portal, docroot /etc/tollgate/tollgate-captive-portal-site)
 $BALANCE_PORT = balance page  <-- ROOT path, NOT /balance.html (nodogsplash gatewayport)
 $ADMIN_PORT = config UI (admin SPA, uhttpd.admin, docroot /www/tollgate - brand dir)
 $API_PORT = merchant JSON API (tollgate binary)
 $LUCI_PORT = LuCI (uhttpd.main)  -> 307 redirect to the TLS listener
 $LUCI_HTTPS_PORT  = LuCI over HTTPS (self-signed; probed with curl -k)
 $ADMIN_HTTPS_PORT = OPT-IN admin HTTPS listener (plain http on :$ADMIN_PORT also exists)
 http=000 means nothing answered on that port (one single 000 = connect failure).
 HTTPS rows now use -k, so a self-signed cert no longer masquerades as 000;
 a 000 on an https row now really means no TLS listener answered.
EOF_LEGEND

echo
echo "== HTTPS transport / certificate (-k) =="
tls_row() { # label url host port
  local label="$1" url="$2" host="$3" port="$4" c info
  c=$(code "$url")
  printf ' %-22s %-44s http=%s\n' "$label" "$url" "$c"
  if [ "$c" = "000" ]; then
    echo "     cert  (no TLS listener answering / connection failed)"
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    info=$(timeout "$TMO" openssl s_client -connect "$host:$port" -servername "$host" \
             </dev/null 2>/dev/null \
           | openssl x509 -noout -subject -issuer -fingerprint -sha256 -dates 2>/dev/null)
  else
    info=""
  fi
  if [ -n "$info" ]; then
    printf '%s\n' "$info" | sed 's/^/     cert  /'
  else
    echo "     cert  (listener answered, but no certificate could be read)"
  fi
}
tls_row "LuCI over HTTPS"      "https://$R:$LUCI_HTTPS_PORT/"  "$R" "$LUCI_HTTPS_PORT"
tls_row "admin HTTPS (opt-in)" "https://$R:$ADMIN_HTTPS_PORT/" "$R" "$ADMIN_HTTPS_PORT"

# ---------------------------------------------------------------------------
# Deployed-build fingerprint
# ---------------------------------------------------------------------------
echo
echo "== deployed-build fingerprint =="
echo " reference: alpha4 APK tollgate-wrt-0.6.0_alpha4-r0.apk"
echo "   (module main d622688b + portal pin d699367: keyset-agnostic decode + LN004 MAC fix)"

cat > "$W/expected.tsv" <<'EOF_ASSETS'
/etc/tollgate/tollgate-captive-portal-site/404.html	3268	9730d0d42a99fd8a54f9b9ed04302d70431ea8807e2ea2cd9e651f05d400161f
/etc/tollgate/tollgate-captive-portal-site/asset-manifest.json	684	cca3f8887fdc8a9963117ae60dac87d8716e44826809a0ed487c3032d9699d83
/etc/tollgate/tollgate-captive-portal-site/assets/TollGate_Logo-C-white-D93CsdZc.png	10145	c77dad055d309c075788cb9e6a21560cf347f8e747053a320f7faf0ef0b8bd78
/etc/tollgate/tollgate-captive-portal-site/assets/balance-5KSP87Gz.css	954	1c2b4628dedc20e4dbd8b48f984209c77eaa418285f496fc01a9879e0ef01874
/etc/tollgate/tollgate-captive-portal-site/assets/balance-DFUNG9Lz.js	3973	79b0b3be10cd6f97b347d99f2ada35d2af2ff8954568abf3f741a078f236fa22
/etc/tollgate/tollgate-captive-portal-site/assets/browser-ponyfill-DCxmUUhP.js	11027	fe97d0d5ea86b574c65d6e14f88f754ac75e16e68354c8c12d40c80b7c34f39b
/etc/tollgate/tollgate-captive-portal-site/assets/index-CSbRLgwZ.css	19116	4a4c83cd3577ca45d667c5e30fe8b509b8f6a3d8af927fde2a3952362aa055eb
/etc/tollgate/tollgate-captive-portal-site/assets/index-fEkM58ty.js	359330	0034ace8c536fb1e4f6561bcb2bdde3eeab5dfe6d554633aa6fa5d41c7486b27
/etc/tollgate/tollgate-captive-portal-site/assets/portal-Dfee5ia1.js	196	8937b8b86fc52a89efb9fc687148fd2f0b403cdc71d6f4c77c907923a8bee1ad
/etc/tollgate/tollgate-captive-portal-site/assets/qr-scanner-worker.min-D85Z9gVD.js	43954	f9d5a00a24ef3c0f52453748a018feec9441c0031c7068e41606c744a26491f5
/etc/tollgate/tollgate-captive-portal-site/assets/qr-scanner.min-D5i-AcPu.js	15766	152302e12e46bae3327062ee2da0ad2cd9e2b163d8f3567ad90895268f604f01
/etc/tollgate/tollgate-captive-portal-site/balance.html	935	cade979781627a623d186e694ea3ee198ce4057f42950ad89b9dc8acf17462b6
/etc/tollgate/tollgate-captive-portal-site/favicon.ico	185470	f1d05d28fc2556fc84882cfb3c3a7fa0ee8c4b66846f9408af55bb34909b7e36
/etc/tollgate/tollgate-captive-portal-site/locales/en.json	7597	4eeb299737b54b1f6ee8e35630b998c5a09f099b268cbf63272fdef77b3aba79
/etc/tollgate/tollgate-captive-portal-site/logo192.png	18937	db9458336dc704b1be7c81de1a796c24c745c5ee0290c30ddaaee749eb3cb9c6
/etc/tollgate/tollgate-captive-portal-site/logo512.png	56701	0868b967a042c31cf78df829dd21b58c80e7c5284b1d6b3d95d21dbd478d2c76
/etc/tollgate/tollgate-captive-portal-site/manifest.json	528	958320fa037d9a44d0bab782543dbce199eac32e072ccb115b922b9e50b67146
/etc/tollgate/tollgate-captive-portal-site/splash.html	2959	0185a988005d93b044858d019ae5d689286d3d9661f45537c905c1922d5dcd39
/www/tollgate/assets/brand/tollgate/icon-colour.png	52205	3befa0d105ceb77c35abdd3a2a701cb86a3a1ec9d1f9b88ae9029a9c20415a3e
/www/tollgate/assets/brand/tollgate/icon-white.png	49656	8158a4129b307802e8bc7ae3b34cfee92c09142d9a639690673e94cdf38cff35
/www/tollgate/assets/brand/tollgate/logo-colour.png	14283	d3c63fd1f9e5cf811f09024738be160beba07b3f4ecda4d258d3e5a43a11ed8b
/www/tollgate/assets/brand/tollgate/logo-white.png	10145	c77dad055d309c075788cb9e6a21560cf347f8e747053a320f7faf0ef0b8bd78
/www/tollgate/assets/index-DJpT8hFU.js	61962	d1c185d4592c231bc9f371f216542836089360ac3531445f83648c8168768dff
/www/tollgate/assets/index-jyv9UPXx.css	8499	26563d028a6a0ecbf1710d0b63605032ba673c3f619c8ca03b01ee1c2c91dc1f
/www/tollgate/index.html	766	150cfdb362d37d9408558b5fbdbc7a9e3a3c70271b9fb6a5a76d59a6478557e1
/www/tollgate/manifest.json	468	84fcb5e3a72fd6d0f4ae2f64a27dc31ae37082f416a7d20e9da951f4b74b43e7
EOF_ASSETS
EXP_N=$(grep -c . "$W/expected.tsv")
echo " embedded alpha4 asset table: $EXP_N content-hashed files (path<TAB>size<TAB>sha256)"
echo

# verdict_for PREFIX REF SIZE SHA -> one verdict token per asset.
#   exact on-device path match wins; otherwise a name that is unique in the
#   alpha4 table is used; anything else is not from this APK.
verdict_for() {
  awk -F'\t' -v want="$1$2" -v b="${2##*/}" -v s="$3" -v h="$4" '
    {
      n=split($1,a,"/"); base=a[n]
      if ($1==want) { exact=1; if ($2==s && $3==h) { print "MATCHES alpha4"; exit }
                      print "DIFFERS"; exit }
      if (base==b) { seen++; if ($2==s && $3==h) hit=1 }
    }
    END {
      if (exact) exit
      if (seen==1) { if (hit) print "MATCHES alpha4"; else print "DIFFERS" }
      else if (seen>1) print "DIFFERS"
      else print "ABSENT-FROM-ALPHA4"
    }' "$W/expected.tsv"
}

MATCH=0; DIFF=0; ABSENT=0; UNREAD=0; TOTAL=0

fingerprint_page() { # label url on-device-docroot
  local label="$1" url="$2" pref="$3"
  local c psz psha refs ref aref asz asha acode v slug port="${4:-}"

  echo " -- $label  $url"
  c=$(code "$url")
  if [ "$c" = "000" ]; then
    echo "      http=000 (nothing answered)"
    echo
    return
  fi
  slug=$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_')
  cp -f "$PAGE" "$W/page-$slug.html" 2>/dev/null
  psz=$(wc -c < "$W/page-$slug.html" 2>/dev/null)
  psha=$(sha256sum < "$W/page-$slug.html" 2>/dev/null | cut -c1-12)
  printf '      http=%s  page %s B sha256=%s...\n' "$c" "${psz:-0}" "${psha:-?}"
  keep_body "page $label ($url)" "$W/page-$slug.html"

  refs=$(grep -oE '<(script|link)[^>]*>' "$PAGE" 2>/dev/null \
         | grep -oE '(src|href)="[^"]+"' \
         | sed -E 's/^(src|href)="//; s/"$//' \
         | awk '!x[$0]++')
  if [ -z "$refs" ]; then
    echo "      no <script src>/<link href> assets referenced by this page"
    echo
    return
  fi

  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in
      data:*|blob:*|javascript:*|mailto:*|"#"*) continue ;;
      http://"$R"/*|https://"$R"/*)   aref="/${ref#*://*/}" ;;
      http://"$R":*/*|https://"$R":*/*) aref="/${ref#*://*/}" ;;
      http://*|https://*|//*) echo "      - (cross-origin, not probed) $ref"; continue ;;
      /*) aref="$ref" ;;
      # every page we fingerprint is served at its docroot root, so a
      # relative ref (assets/x.js, manifest.json) resolves from "/"
      *) aref="/$ref" ;;
    esac
    aref=$(printf '%s' "$aref" | sed -E 's/[?#].*$//')
    [ -n "$aref" ] || continue
    [ "$aref" = "/" ] && continue

    : > "$ASSET"
    acode=$(curl -sk -o "$ASSET" -w '%{http_code}' --max-time "$TMO" "http://$R:$port$aref" 2>/dev/null)
    if [ "$acode" != "200" ] || [ ! -s "$ASSET" ]; then
      printf '      %-46s %8s   %-14s %s\n' "$aref" "-" "-" "UNREADABLE (http=$acode)"
      UNREAD=$((UNREAD+1)); TOTAL=$((TOTAL+1))
      continue
    fi
    asz=$(wc -c < "$ASSET")
    asha=$(sha256sum < "$ASSET" | cut -c1-12)
    keep_body "asset $aref" "$ASSET"
    v=$(verdict_for "$pref" "$aref" "$asz" "$(sha256sum < "$ASSET" | cut -d' ' -f1)")
    case "$v" in
      "MATCHES alpha4")    MATCH=$((MATCH+1)) ;;
      "DIFFERS")           DIFF=$((DIFF+1)) ;;
      "ABSENT-FROM-ALPHA4") ABSENT=$((ABSENT+1)) ;;
    esac
    TOTAL=$((TOTAL+1))
    printf '      %-46s %8s B  %-12s %s\n' "$aref" "$asz" "$asha" "$v"
  done <<EOF_REFS
$refs
EOF_REFS
  echo
}

fingerprint_page "portal  :$PORTAL_PORT" "http://$R:$PORTAL_PORT/splash.html" \
                 "/etc/tollgate/tollgate-captive-portal-site" "$PORTAL_PORT"
fingerprint_page "balance :$BALANCE_PORT" "http://$R:$BALANCE_PORT/" \
                 "/etc/tollgate/tollgate-captive-portal-site" "$BALANCE_PORT"
fingerprint_page "admin   :$ADMIN_PORT" "http://$R:$ADMIN_PORT/" \
                 "/www/tollgate" "$ADMIN_PORT"

echo " assets checked: $TOTAL  (matches=$MATCH differs=$DIFF absent=$ABSENT unreadable=$UNREAD)"
if [ "$TOTAL" -eq 0 ]; then
  echo " verdict: unknown (no assets readable)"
elif [ "$DIFF" -eq 0 ] && [ "$ABSENT" -eq 0 ] && [ "$MATCH" -gt 0 ]; then
  if [ "$UNREAD" -gt 0 ]; then
    echo " verdict: alpha4-portaldecode DEPLOYED (partial - $UNREAD referenced asset(s) unreadable)"
  else
    echo " verdict: alpha4-portaldecode DEPLOYED"
  fi
else
  echo " verdict: NOT the alpha4 build (live portal bundles not in the alpha4 APK) - the keyset/ LN004 fix is NOT deployed"
fi

# ---------------------------------------------------------------------------
# Version evidence
# ---------------------------------------------------------------------------
echo
echo "== version evidence (read-only) =="
vcode=$(curl -sk -o "$W/api.txt" -w '%{http_code}' --max-time "$TMO" "http://$R:$API_PORT/" 2>/dev/null)
printf ' merchant API :%s  http=%s\n' "$API_PORT" "$vcode"
if [ "$vcode" = "000" ]; then
  echo "   (nothing answered - no API dump available)"
else
  echo "   first 400 bytes:"
  head -c 400 "$W/api.txt" 2>/dev/null | sed 's/^/     /'
  echo
  keep_body "merchant API :$API_PORT (first 400 B)" "$W/api.txt"
fi

echo " version-like strings found in fetched pages/assets:"
VERPAT='[0-9]+\.[0-9]+\.[0-9]+(-alpha[0-9]+)?'
VHITS=0
VSEEN=""
while IFS="$(printf '\t')" read -r vlabel vpath; do
  [ -n "${vpath:-}" ] || continue
  [ -f "$vpath" ] || continue
  hits=$(grep -ohE "$VERPAT" "$vpath" 2>/dev/null | sort -u | head -8 \
         | awk '/^0\.6\./{t=t" "$0; next} NF{r=r" "$0} END{print t r}' \
         | sed -E 's/^ +//; s/ +$//' | cut -c1-92)
  [ -n "$hits" ] || continue
  case "$VSEEN" in *"|$vlabel|$hits|"*) continue ;; esac
  VSEEN="$VSEEN|$vlabel|$hits|"
  VHITS=$((VHITS+1))
  printf '   %-46s %s\n' "$vlabel" "$hits"
done < "$BODIES"
if [ "$VHITS" -eq 0 ]; then
  echo "   (no version string exposed read-only)"
else
  echo "   ^ raw grep hits, shown with their provenance. Version constants inside"
  echo "     JS bundles are the SPA's own build string, not the firmware version."
fi

echo
echo "(probe v3 complete - read-only, nothing written to $R)"
