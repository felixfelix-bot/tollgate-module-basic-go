#!/bin/sh
# Read-only capability probe for a TollGate router.
# Run ON the router (ssh root@<router>). Uses only tools proven present on the
# lab GL-MT3000 (OpenWrt 25.12.5, apk-tools 3.x). Modifies nothing.
echo "== build =="
printf '  setup marker : '; cat /etc/tollgate-setup-done 2>/dev/null || echo "(absent)"
printf '  apk          : '; apk --version 2>/dev/null | head -1
apk list --installed 2>/dev/null | grep -i tollgate | sed 's/^/  pkg          : /'
echo "== solver-pulled runtime deps =="
apk info -a tollgate-wrt 2>&1 | sed -n '/depends on/,/^$/p' | sed 's/^/  /'
echo "  replaces     : $(apk info -a tollgate-wrt 2>&1 | grep -ci replaces) (0 = none; it does not claim to replace a daemon)"
echo "== pre-auth allow list (nodogsplash users_to_router) =="
uci show nodogsplash 2>/dev/null | sed -n "s/.*users_to_router='\(.*\)'/\1/p" | tr -d "'" | sed 's/  */ /g'
echo "== capability checks =="
alc=$(uci show nodogsplash 2>/dev/null | sed -n "s/.*users_to_router='\(.*\)'/\1/p" | tr -d "'")
echo "$alc" | awk '{for(i=2;i<=NF;i++) if($i=="443" && $(i-1)=="port") f=1} END{print (f?"  443  ALLOWED pre-auth":"  443  MISSING pre-auth")}'
if command -v ndsctl >/dev/null 2>&1; then
    echo "== nodogsplash daemon =="
    ndsctl status 2>&1 | head -12 | sed 's/^/  /'
else
    echo "== nodogsplash daemon: ndsctl not present =="
fi
echo "== end =="
