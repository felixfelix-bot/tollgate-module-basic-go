#!/bin/bash
# TollGate surface probe — NO password, NO install, NO writes.
#
# Confirms (a) which device answers at the router address and (b) whether the
# three surfaces respond, on whatever firmware is CURRENTLY installed.
#
# Usage:  bash <(curl -fsSL <raw-url>/probe-surfaces.sh) [router-ip]
set -u

ROUTER="${1:-192.168.8.1}"

echo "==================================================================="
echo " TollGate surface probe (read-only) | router=$ROUTER"
echo "==================================================================="
echo
echo "== device identity =="
echo -n "  ssh banner        : "
( ssh -o ConnectTimeout=6 -o PreferredAuthentications=none -o StrictHostKeyChecking=no \
      "root@$ROUTER" true 2>&1 | head -1 ) || true
echo -n "  hostname (mDNS?)  : "
(getent hosts "$ROUTER" 2>/dev/null | awk '{print $2}' | head -1) || true
echo
echo "== surfaces (HTTP status + a fingerprint of what answered) =="
probe() { # label url
  local label="$1" url="$2" code body
  code=$(curl -s -o /tmp/.probe.$$ -w '%{http_code}' -m 8 "$url" 2>/dev/null || echo "000")
  body=$(head -c 400 /tmp/.probe.$$ 2>/dev/null | tr -d '\n' | tr -s ' ')
  printf '  %-18s %-34s http=%s\n' "$label" "$url" "$code"
  case "$body" in
    *"<title>"*) printf '      title: %s\n' "$(printf '%s' "$body" | sed -n 's/.*<title>\([^<]*\)<.*/\1/p' | head -c 80)" ;;
  esac
  case "$body" in
    *TollGate*|*tollgate*) printf '      -> mentions TollGate\n' ;;
  esac
  rm -f /tmp/.probe.$$
}

probe "captive portal"  "http://$ROUTER:2051/splash.html"
probe "portal (404 pg)" "http://$ROUTER:2051/404.html"
probe "balance page"    "http://$ROUTER:2050/balance.html"
probe "balance root"    "http://$ROUTER:2050/"
probe "config UI"       "http://$ROUTER:8090/"
probe "LuCI"            "http://$ROUTER:8080/"
probe "merchant API"    "http://$ROUTER:2121/"
probe "admin (8443)"    "https://$ROUTER:8443/"
echo
echo "== which firmware is installed? =="
echo "  (needs ssh; without it, compare the portal bundle name on disk)"
echo "  expected-note: THIS build ships assets/index-fEkM58ty.js"
echo
echo "Reading these:"
echo "  2051 = captive portal (nodogsplash pre-auth)  2050 = balance page"
echo "  8090 = config UI (admin SPA)                  2121 = merchant JSON API"
echo "  8080 = LuCI                                   443/8443 = HTTPS redirect"
echo "  http=000 means nothing answered on that port."
