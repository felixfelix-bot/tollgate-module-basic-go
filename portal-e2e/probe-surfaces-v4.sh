#!/bin/bash
# ============================================================================
# TollGate surface probe v4  (read-only: no auth, no install, no writes)
#
# v4 = v3 + BOTH build fingerprints embedded, so ONE script prints the correct
# verdict BEFORE and AFTER the alpha5 install.
#
#   WHY v4: v3 embeds only the alpha4 asset table.  The alpha5 portal bundle was
#   REGENERATED from portal commit e67d646, so its content-hashed filenames and
#   hashes differ.  Run v3 after installing alpha5 and it prints the MISLEADING
#     "NOT the alpha4 build ... the keyset/LN004 fix is NOT deployed"
#   even though the fix IS deployed.  v4 carries the alpha5 table as the PRIMARY
#   reference and keeps the alpha4 table as the SECONDARY, and decides per asset.
#
#   the three v3 defects, all kept fixed here:
#   defect 1 - FALSE "http=000000".  v2's helper was
#                curl ... -w '%{http_code}' ... || echo 000
#              On a connect failure curl ALREADY prints 000 and exits non-zero,
#              so the `|| echo 000` appended a SECOND one.  v4 has no fallback
#              echo: curl's own 000 is the single 3-digit answer.  Local scratch
#              is mktemp -d + trap (v2 wrote /tmp/_p.html - never do that in a
#              script somebody pipes into bash).
#   defect 2 - HTTPS rows were not evidence.  curl without -k fails the router's
#              self-signed cert, so :443 / :8443 printed 000 even when a TLS
#              listener WAS answering.  v4 probes https with -k and, when the
#              listener answers, prints the peer certificate (subject/issuer/
#              SHA-256 fingerprint/dates) read via openssl s_client.
#   defect 3 - a stale body read back as this row's evidence.  `curl -o FILE`
#              leaves FILE untouched on a connect failure, so the PREVIOUS
#              surface's <title> was echoed as the next row's title.  v4
#              truncates the body file before EVERY fetch.
#
#   per-asset verdict token (alpha5 is consulted FIRST, then alpha4):
#     MATCHES alpha5     live bytes equal the alpha5 row for this path
#     MATCHES alpha4     alpha5 has no matching row and the alpha4 row matches
#                        (also used when the path exists in the alpha5 table but
#                        the live bytes are exactly the alpha4 row - so the
#                        alpha4 build is never mislabelled "DIFFERS")
#     DIFFERS            the path IS in one of the tables but the bytes match
#                        neither the alpha5 nor the alpha4 row
#     ABSENT-FROM-BOTH   the path is in neither table
#
#   one-line verdict
#     alpha5-portalcu102ln004 DEPLOYED
#                        every referenced asset matched alpha5, none absent/differs
#     alpha4-portaldecode DEPLOYED (Bug A only - no LN004 mac fix)
#                        matched alpha4 instead
#     NOT a known e2e build
#                        matched neither table
#     unknown / partial  nothing readable / some referenced asset unreadable
#   (the "matched alpha5" test also requires at least one asset that is
#    alpha5-DISTINCTIVE: a row whose bytes differ from the alpha4 row for the
#    same path.  Without that guard the admin SPA - whose bundle is byte-identical
#    in both builds - would alone "prove" alpha5.)
#
#   provenance of the two embedded tables (scripts/extract-openwrt-apk-v3.sh --table):
#     alpha5 = portal-e2e/tollgate-wrt_0.6.0_alpha5_aarch64_cortex-a53_portalcu102ln004.apk
#              7863188 B  sha256 45e7d1760767789a0d0d16be2c61c9a0af542625469f4d401bd98a4e91dd9969
#              (portal bundle regenerated from portal commit e67d646: keyset-agnostic
#               decode + LN004 MAC fix)
#     alpha4 = portal-e2e/tollgate-wrt_0.6.0_alpha4_aarch64_cortex-a53_portaldecode.apk
#              7861856 B  sha256 058b3e967cb86fe7a17dad1be5747b981fdab43976263edc90b41af23e538298
#              (portal pin d699367: Bug A / keyset fix only, no LN004 mac fix)
#
# Read-only by construction: HTTP(S) GETs with --max-time 6, one harmless ssh
# banner probe, openssl s_client for the cert.  Nothing is written to the
# router.
#
# Usage:
#   curl -fsSL <raw-url> | bash
#   bash probe-surfaces-v4.sh 192.168.8.1            # positional (v1/v2 style)
#   TOLLGATE_ROUTER=192.168.8.1 bash probe-surfaces-v4.sh
#   PORTAL_PORT=27051 BALANCE_PORT=27050 ADMIN_PORT=28090 API_PORT=2121 \
#   LUCI_PORT=8080 LUCI_HTTPS_PORT=443 ADMIN_HTTPS_PORT=8443 bash probe-surfaces-v4.sh
#   (the env port overrides let it be dry-run offline against python3 -m http.server)
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
# evidence - defect 3).
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
echo " TollGate surface probe v4 (read-only) | router=$R"
echo " fixes: single-000 (no false 000000) | -k for https | truncate before fetch"
echo " fingerprint: alpha5 (primary) + alpha4 (secondary), one verdict"
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
# Deployed-build fingerprint  (alpha5 table PRIMARY, alpha4 table SECONDARY)
# ---------------------------------------------------------------------------
echo
echo "== deployed-build fingerprint =="
echo " primary   : alpha5 APK tollgate-wrt-0.6.0_alpha5-r0.apk (portalcu102ln004)"
echo "   (portal bundle regenerated from portal commit e67d646: keyset-agnostic decode + LN004 MAC fix)"
echo " secondary : alpha4 APK tollgate-wrt-0.6.0_alpha4-r0.apk (portaldecode)"
echo "   (portal pin d699367: Bug A / keyset fix only - no LN004 mac fix)"

cat > "$W/expected-alpha5.tsv" <<'EOF_ASSETS_ALPHA5'
/etc/tollgate/tollgate-captive-portal-site/404.html	3268	9730d0d42a99fd8a54f9b9ed04302d70431ea8807e2ea2cd9e651f05d400161f
/etc/tollgate/tollgate-captive-portal-site/asset-manifest.json	684	4269496093ae5778cf0e53431b5f9e950a737ba3974b728786d34519cd9a8668
/etc/tollgate/tollgate-captive-portal-site/assets/TollGate_Logo-C-white-D93CsdZc.png	10145	c77dad055d309c075788cb9e6a21560cf347f8e747053a320f7faf0ef0b8bd78
/etc/tollgate/tollgate-captive-portal-site/assets/balance-5KSP87Gz.css	954	1c2b4628dedc20e4dbd8b48f984209c77eaa418285f496fc01a9879e0ef01874
/etc/tollgate/tollgate-captive-portal-site/assets/balance-CrQ4R-xL.js	3973	30a2bb28e1ceab8cb175facd1c7fc9256551481ea7299fd81628f0cc7db4352a
/etc/tollgate/tollgate-captive-portal-site/assets/browser-ponyfill-DYD9eokg.js	11027	660d919cb2c9f3842f6856bc57c4f8ba63973087ffc62ab1796f1029638169e3
/etc/tollgate/tollgate-captive-portal-site/assets/index-CSbRLgwZ.css	19116	4a4c83cd3577ca45d667c5e30fe8b509b8f6a3d8af927fde2a3952362aa055eb
/etc/tollgate/tollgate-captive-portal-site/assets/index-ldb-r6jB.js	359545	8540e1835b0fd4d894504f1482a8dab435f7b1130c822309d36117f22a1c6efc
/etc/tollgate/tollgate-captive-portal-site/assets/portal-mcSvEuD0.js	196	22c6aaaaa0559eaef177dae5c06e026b932ca3eb87ff307c27c9ec851dbd6c71
/etc/tollgate/tollgate-captive-portal-site/assets/qr-scanner-worker.min-D85Z9gVD.js	43954	f9d5a00a24ef3c0f52453748a018feec9441c0031c7068e41606c744a26491f5
/etc/tollgate/tollgate-captive-portal-site/assets/qr-scanner.min-CYY5W0a4.js	15766	36cdd5e629d72faeffaf7e06a4f0222ad8bb98a6c3f7e43972da746c901482c3
/etc/tollgate/tollgate-captive-portal-site/balance.html	935	6bffd13624cd52f859d160567843fe452f3027037d3561ad5883d442fb6db3b9
/etc/tollgate/tollgate-captive-portal-site/favicon.ico	185470	f1d05d28fc2556fc84882cfb3c3a7fa0ee8c4b66846f9408af55bb34909b7e36
/etc/tollgate/tollgate-captive-portal-site/locales/en.json	7892	dcfd699ce977fb56b1fabcde5835010e8750ca60e69b1ecd81a68ff000a141a3
/etc/tollgate/tollgate-captive-portal-site/logo192.png	18937	db9458336dc704b1be7c81de1a796c24c745c5ee0290c30ddaaee749eb3cb9c6
/etc/tollgate/tollgate-captive-portal-site/logo512.png	56701	0868b967a042c31cf78df829dd21b58c80e7c5284b1d6b3d95d21dbd478d2c76
/etc/tollgate/tollgate-captive-portal-site/manifest.json	528	958320fa037d9a44d0bab782543dbce199eac32e072ccb115b922b9e50b67146
/etc/tollgate/tollgate-captive-portal-site/splash.html	2959	8268215ee9043879f0ee8474d1972364b1e888f2ebbe2e41c081cc7056104aea
/www/tollgate/assets/brand/tollgate/icon-colour.png	52205	3befa0d105ceb77c35abdd3a2a701cb86a3a1ec9d1f9b88ae9029a9c20415a3e
/www/tollgate/assets/brand/tollgate/icon-white.png	49656	8158a4129b307802e8bc7ae3b34cfee92c09142d9a639690673e94cdf38cff35
/www/tollgate/assets/brand/tollgate/logo-colour.png	14283	d3c63fd1f9e5cf811f09024738be160beba07b3f4ecda4d258d3e5a43a11ed8b
/www/tollgate/assets/brand/tollgate/logo-white.png	10145	c77dad055d309c075788cb9e6a21560cf347f8e747053a320f7faf0ef0b8bd78
/www/tollgate/assets/index-DJpT8hFU.js	61962	d1c185d4592c231bc9f371f216542836089360ac3531445f83648c8168768dff
/www/tollgate/assets/index-jyv9UPXx.css	8499	26563d028a6a0ecbf1710d0b63605032ba673c3f619c8ca03b01ee1c2c91dc1f
/www/tollgate/index.html	766	150cfdb362d37d9408558b5fbdbc7a9e3a3c70271b9fb6a5a76d59a6478557e1
/www/tollgate/manifest.json	468	84fcb5e3a72fd6d0f4ae2f64a27dc31ae37082f416a7d20e9da951f4b74b43e7
EOF_ASSETS_ALPHA5

cat > "$W/expected-alpha4.tsv" <<'EOF_ASSETS_ALPHA4'
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
EOF_ASSETS_ALPHA4

EXP5_N=$(grep -c . "$W/expected-alpha5.tsv")
EXP4_N=$(grep -c . "$W/expected-alpha4.tsv")
echo " embedded tables: alpha5=$EXP5_N rows, alpha4=$EXP4_N rows (path<TAB>size<TAB>sha256)"
echo

# table_lookup TABLE PREFIX REF SIZE SHA -> MATCH | DIFFER | NONE
#   an exact on-device path match wins; otherwise a basename that is UNIQUE in
#   that table is used; anything else is not from that build.
table_lookup() { # table-file prefix ref size sha
  awk -F'\t' -v want="$2$3" -v b="${3##*/}" -v s="$4" -v h="$5" '
    {
      n=split($1,a,"/"); base=a[n]
      if ($1==want) { exact=1; if ($2==s && $3==h) { print "MATCH"; exit }
                      print "DIFFER"; exit }
      if (base==b) { seen++; if ($2==s && $3==h) hit=1 }
    }
    END {
      if (exact) exit
      if (seen==1) { if (hit) print "MATCH"; else print "DIFFER" }
      else if (seen>1) print "DIFFER"
      else print "NONE"
    }' "$1"
}

# verdict_for PREFIX REF SIZE SHA -> one token.  alpha5 FIRST, then alpha4.
verdict_for() { # prefix ref size sha
  local v5 v4
  v5=$(table_lookup "$W/expected-alpha5.tsv" "$1" "$2" "$3" "$4")
  if [ "$v5" = "MATCH" ]; then printf 'MATCHES alpha5'; return; fi
  v4=$(table_lookup "$W/expected-alpha4.tsv" "$1" "$2" "$3" "$4")
  if [ "$v4" = "MATCH" ]; then printf 'MATCHES alpha4'; return; fi
  if [ "$v5" = "DIFFER" ] || [ "$v4" = "DIFFER" ]; then printf 'DIFFERS'; return; fi
  printf 'ABSENT-FROM-BOTH'
}

MATCH5=0; MATCH4=0; DIFF=0; ABSENT=0; UNREAD=0; TOTAL=0; M5_DISTINCT=0

fingerprint_page() { # label url on-device-docroot
  local label="$1" url="$2" pref="$3"
  local c psz psha refs ref aref asz asha acode v fullsha v4b slug port="${4:-}"

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
    fullsha=$(sha256sum < "$ASSET" | cut -d' ' -f1)
    keep_body "asset $aref" "$ASSET"
    v=$(verdict_for "$pref" "$aref" "$asz" "$fullsha")
    case "$v" in
      "MATCHES alpha5")
        MATCH5=$((MATCH5+1))
        # alpha5-DISTINCTIVE only if the alpha4 table does NOT carry the same
        # bytes for this path (a byte-identical row proves neither build)
        v4b=$(table_lookup "$W/expected-alpha4.tsv" "$pref" "$aref" "$asz" "$fullsha")
        [ "$v4b" = "MATCH" ] || M5_DISTINCT=$((M5_DISTINCT+1))
        ;;
      "MATCHES alpha4") MATCH4=$((MATCH4+1)) ;;
      "DIFFERS")        DIFF=$((DIFF+1)) ;;
      "ABSENT-FROM-BOTH") ABSENT=$((ABSENT+1)) ;;
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

echo " assets checked: $TOTAL  (matches alpha5=$MATCH5 [of which alpha5-only=$M5_DISTINCT] matches alpha4=$MATCH4 differs=$DIFF absent-from-both=$ABSENT unreadable=$UNREAD)"
if [ "$TOTAL" -eq 0 ]; then
  echo " verdict: unknown (no assets readable)"
elif [ "$MATCH5" -eq 0 ] && [ "$MATCH4" -eq 0 ] && [ "$DIFF" -eq 0 ] && [ "$ABSENT" -eq 0 ]; then
  # nothing could be fingerprinted and the ONLY reason is that the fetches failed
  echo " verdict: unknown (no referenced asset could be fingerprinted - $UNREAD unreadable)"
elif [ "$DIFF" -eq 0 ] && [ "$ABSENT" -eq 0 ] && [ "$MATCH4" -eq 0 ] \
     && [ "$MATCH5" -gt 0 ] && [ "$M5_DISTINCT" -gt 0 ]; then
  if [ "$UNREAD" -gt 0 ]; then
    echo " verdict: alpha5-portalcu102ln004 DEPLOYED (partial - $UNREAD referenced asset(s) unreadable)"
  else
    echo " verdict: alpha5-portalcu102ln004 DEPLOYED"
  fi
elif [ "$DIFF" -eq 0 ] && [ "$ABSENT" -eq 0 ] && [ "$MATCH4" -gt 0 ] \
     && [ "$M5_DISTINCT" -eq 0 ]; then
  if [ "$UNREAD" -gt 0 ]; then
    echo " verdict: alpha4-portaldecode DEPLOYED (Bug A only - no LN004 mac fix) (partial - $UNREAD referenced asset(s) unreadable)"
  else
    echo " verdict: alpha4-portaldecode DEPLOYED (Bug A only - no LN004 mac fix)"
  fi
else
  echo " verdict: NOT a known e2e build (live bundles match neither the alpha5 nor the alpha4 table)"
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
echo "(probe v4 complete - read-only, nothing written to $R)"
