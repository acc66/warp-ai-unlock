#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source <(sed '/^case "${1:-}" in/,$d' warp-ai.sh)
passed=0
expect() {
  local actual=$1 expected=$2
  [[ "$actual" == "$expected" ]] || { printf 'FAIL: expected <%s>, got <%s>\n' "$expected" "$actual"; exit 1; }
  passed=$((passed + 1))
}
# Test the real request wrapper without external networking.
curl() {
  [[ "$1" == --disable && "$2" == --proxy && -z "$3" && "$4" == --noproxy && -z "$5" ]] || return 99
  printf 'line one\nline two\n200 https://example.test/final'
}
probe_http https://example.test/
expect "$PROBE_BODY" $'line one\nline two'
expect "$PROBE_CODE" 200
expect "$PROBE_URL" https://example.test/final
curl() { return "$mock_rc"; }
for pair in '5:Proxy DNS' '6:DNS' '7:Connect' '28:Timeout' '35:TLS' '60:TLS' '97:SOCKS handshake' '52:curl:52'; do
  mock_rc=${pair%%:*}
  if probe_http https://example.test/; then echo 'FAIL: failed curl reported success'; exit 1; fi
  expect "$(probe_error)" "${pair#*:}"
  expect "$PROBE_RC" "$mock_rc"
done
# Endpoint fixtures; function runs unchanged against these responses.
probe_http() {
  PROBE_RC=0 PROBE_CODE=200 PROBE_URL="${*: -1}" PROBE_BODY='{}'
  case "$*" in
    *cdn-cgi/trace*) PROBE_BODY=$'ip=192.0.2.1\nloc=US\r\nwarp=on\r' ;;
    *api.openai.com*)
      case "$scenario" in
        blocked|webblocked) PROBE_CODE=403; PROBE_BODY='{"error":{"code":"unsupported_country_region_territory"}}' ;;
        challenge) PROBE_CODE=403; PROBE_BODY='Just a moment' ;;
        network) PROBE_RC=28; return 1 ;;
      esac ;;
    *ios.chat.openai.com*)
      case "$scenario" in
        blocked|appblocked) PROBE_CODE=403; PROBE_BODY='Please disable your VPN' ;;
        challenge) PROBE_CODE=403; PROBE_BODY='Just a moment' ;;
        app403) PROBE_CODE=403; PROBE_BODY='Forbidden' ;;
        ispblocked) PROBE_CODE=403; PROBE_BODY='{"blocked_why_headline":"Request blocked"}' ;;
        *) PROBE_BODY='<html>Welcome; VPN help available</html>' ;;
      esac ;;
    *claude.ai*)
      case "$scenario" in
        blocked) PROBE_URL=https://claude.ai/app-unavailable-in-region ;;
        challenge) PROBE_CODE=403; PROBE_BODY='Just a moment' ;;
        http) PROBE_CODE=503; PROBE_BODY=unavailable ;;
        network) PROBE_RC=6; return 1 ;;
      esac ;;
    *gemini.google.com*)
      case "$scenario" in
        challenge) PROBE_CODE=200; PROBE_BODY='captcha' ;;
        region) PROBE_BODY='<html>,2,1,200,"USA"</html>' ;;
        singapore) PROBE_BODY='<html>,2,1,200,"SGP"</html>' ;;
        *) PROBE_BODY='<html>unrecognized page</html>' ;;
      esac ;;
  esac
}
scenario=ok; expect "$(check_chatgpt)" 'OK Region+App OK (US)'
scenario=blocked; expect "$(check_chatgpt)" 'NO Region+App blocked (US)'
scenario=webblocked; expect "$(check_chatgpt)" 'WARN Region blocked; App OK (US)'
scenario=appblocked; expect "$(check_chatgpt)" 'WARN Region OK; App blocked (US)'
scenario=challenge; expect "$(check_chatgpt)" 'WARN Region:Challenge/HTTP 403; App:Challenge/HTTP 403'
scenario=network; expect "$(check_chatgpt)" 'WARN Region:Timeout; App:ok'
scenario=app403; expect "$(check_chatgpt)" 'WARN Region OK; App:HTTP 403'
scenario=ispblocked; expect "$(check_chatgpt)" 'WARN Region OK; App blocked (US)'
scenario=ok; expect "$(check_claude)" 'OK Page OK (US)'
scenario=singapore; expect "$(check_gemini)" 'OK Page OK (Region:SGP)'
scenario=blocked; expect "$(check_claude)" 'NO No (Region)'
scenario=challenge; expect "$(check_claude)" 'WARN Probe blocked (Challenge/HTTP 403)'
scenario=http; expect "$(check_claude)" 'WARN Probe blocked (HTTP 503)'
scenario=network; expect "$(check_claude)" 'ERR Failed (DNS)'
scenario=region; expect "$(check_gemini)" 'OK Page OK (Region:USA)'
scenario=unknown; expect "$(check_gemini)" 'WARN Page OK (Region:unparsed)'
scenario=challenge; expect "$(check_gemini)" 'WARN Probe blocked (Challenge/HTTP 200)'
scenario=ok
output=$(check_ai)
[[ "$output" == *'WARP 出口: 192.0.2.1'* && "$output" == *ChatGPT* && "$output" == *Claude* && "$output" == *Gemini* ]] || { echo 'FAIL: parallel output'; exit 1; }
passed=$((passed + 1))
expect "$(warp_ok)" $'\033[32mWARP 正常: ip=192.0.2.1 loc=US\r warp=on\r \033[0m'
printf 'PASS: %s assertions\n' "$passed"
