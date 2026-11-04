#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a
base="http://127.0.0.1:${PROXY_PORT:-40001}"
echo "Checking unauthenticated CONNECT..."
headers=$(curl --noproxy '' -sS --max-time 10 -x "$base" -D - -o /dev/null http://example.com/ 2>/dev/null || true)
printf '%s\n' "$headers" | grep -Eq '^HTTP/[0-9.]+ 407' || { echo "FAIL: missing 407"; exit 1; }
echo "PASS: authentication required"
headers=$(curl --noproxy '' -sS --max-time 10 -x "$base" -U "$PROXY_USER:wrong-password" -D - -o /dev/null http://example.com/ 2>/dev/null || true)
printf '%s\n' "$headers" | grep -Eq '^HTTP/[0-9.]+ 407' || { echo "FAIL: wrong password not rejected"; exit 1; }
echo "PASS: wrong password rejected"
echo "Checking authenticated HTTPS over WARP..."
trace=$(curl --noproxy '' -fsS --max-time 35 -x "$base" -U "$PROXY_USER:$PROXY_PASS" https://www.cloudflare.com/cdn-cgi/trace)
printf '%s\n' "$trace" | grep -Eq '^warp=(on|plus)$' || { echo "FAIL: WARP exit not verified"; exit 1; }
printf '%s\n' "$trace" | grep -E '^(ip|loc|warp)='
curl --noproxy '' -fsS --max-time 30 -x "$base" -U "$PROXY_USER:$PROXY_PASS" http://example.com/ >/dev/null
echo "PASS: authentication, HTTPS CONNECT, WARP exit, HTTP"
