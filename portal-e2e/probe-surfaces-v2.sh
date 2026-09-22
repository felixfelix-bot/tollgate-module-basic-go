#!/bin/bash
# TollGate surface probe v2 - read-only. No password, no install, no writes.
#
# v2 fixes a v1 mistake: the balance page is served at the ROOT of :2050,
# not at /balance.html (v1 probed the wrong path and reported a false 404).

R="${1:-192.168.8.1}"
get() { curl -s -o /tmp/_p.html -w '%{http_code}' --max-time 6 "$1" 2>/dev/null || echo 000; }

echo "==================================================================="
echo " TollGate surface probe v2 (read-only) | router=$R"
echo "==================================================================="

echo
echo "== device identity (no auth) =="
echo -n " ssh banner       : "
timeout 6 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
  -o PreferredAuthentications=none root@"$R" true 2>&1 | head -1
echo -n " mDNS name        : "
getent hosts TollGate.lan 2>/dev/null | head -1 || echo "(no mDNS resolution)"

echo
echo "== surfaces =="
probe() { # label url
  c=$(get "$1")
  t=$(grep -oiE '<title>[^<]*' /tmp/_p.html 2>/dev/null | head -1 | sed 's/<title>//i')
  m=""
  grep -qiE 'tollgate|cashu|mint' /tmp/_p.html 2>/dev/null && m=" [mentions TollGate]"
  printf ' %-22s %-42s http=%s  title:%s%s\n' "$2" "$1" "$c" "${t:-none}" "$m"
}
probe "http://$R:2051/splash.html" "captive portal"
probe "http://$R:2050/"            "balance page (root)"
probe "http://$R:8090/"            "config UI (admin SPA)"
probe "http://$R:2121/"            "merchant API"
probe "http://$R:8080/"            "LuCI (expect 307)"
probe "https://$R/"                "LuCI over HTTPS"

echo
echo "== reading these =="
cat <<'EOF'
 2051 = captive portal (nodogsplash pre-auth)
 2050 = balance page  <-- root path, NOT /balance.html
 8090 = config UI (admin SPA, the LuCI alternative)
 2121 = merchant JSON API
 8080 = LuCI  -> 307 redirect to 443
 443  = HTTPS (offers LuCI)
 http=000 means nothing answered on that port.
EOF

echo
echo "== HTTPS on 8443 =="
printf ' admin (8443)           https://%s:8443/           http=%s\n' "$R" "$(get "https://$R:8443/")"
echo " (8443 is only enabled on newer firmware; silent is normal on older builds)"
