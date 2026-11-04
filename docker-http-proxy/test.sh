#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
base="http://127.0.0.1:${PROXY_PORT:-40001}"
code=$(curl --noproxy '' -sS -o /dev/null -w '%{http_code}' -x "$base" https://www.cloudflare.com/cdn-cgi/trace || true)
[[ "$code" == 407 ]] || { echo "FAIL unauthenticated: $code"; exit 1; }
code=$(curl --noproxy '' -sS -o /dev/null -w '%{http_code}' -x "$base" -U "$PROXY_USER:wrong-password" https://www.cloudflare.com/cdn-cgi/trace || true)
[[ "$code" == 407 ]] || { echo "FAIL wrong password: $code"; exit 1; }
trace=$(curl --noproxy '' -fsS --max-time 30 -x "$base" -U "$PROXY_USER:$PROXY_PASS" https://www.cloudflare.com/cdn-cgi/trace)
printf '%s\n' "$trace" | grep -Eq '^warp=(on|plus)$' || { echo "FAIL: WARP exit not verified"; exit 1; }
printf '%s\n' "$trace" | grep -E '^(ip|loc|warp)='
curl --noproxy '' -fsS --max-time 30 -x "$base" -U "$PROXY_USER:$PROXY_PASS" http://example.com/ >/dev/null
echo 'PASS: auth, CONNECT, WARP exit, HTTP'
