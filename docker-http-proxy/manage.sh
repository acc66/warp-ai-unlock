#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[[ -f .env ]] || { echo "Missing .env"; exit 1; }
set -a; source .env; set +a
check() {
 local port="$1" trace ip loc warp
 trace=$(curl --noproxy '' -fsS --max-time 30 -x "http://127.0.0.1:$port" -U "$PROXY_USER:$PROXY_PASS" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) || { printf '%s\tFAIL\t-\t-\n' "$port"; return; }
 ip=$(sed -n 's/^ip=//p' <<<"$trace" | head -1)
 loc=$(sed -n 's/^loc=//p' <<<"$trace" | head -1)
 warp=$(sed -n 's/^warp=//p' <<<"$trace" | head -1)
 [[ "$warp" == on || "$warp" == plus ]] && printf '%s\tOK\t%s\t%s\n' "$port" "$ip" "$loc" || printf '%s\tNOT_WARP\t%s\t%s\n' "$port" "$ip" "$loc"
}
case "${1:-help}" in
 check|ips)
  printf 'PORT\tSTATUS\tEXIT_IP\tREGION\tDUPLICATE\n'
  seen=' '
  for port in 40001 40002 40003 40004 40005; do
   line=$(check "$port"); IFS=$'\t' read -r p status ip loc <<< "$line"
   duplicate=NO
   if [[ "$status" == OK && "$seen" == *" $ip "* ]]; then duplicate=YES; fi
   printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$status" "$ip" "$loc" "$duplicate"
   if [[ "$status" == OK ]]; then seen+="$ip "; fi
  done
  ;;
 list)
  host="${2:-}"; [[ -n "$host" ]] || { echo 'Usage: bash manage.sh list PUBLIC_IP'; exit 1; }
  for port in 40001 40002 40003 40004 40005; do printf '%s:%s@%s:%s\n' "$PROXY_USER" "$PROXY_PASS" "$host" "$port"; done
  echo 'WARNING: output contains proxy password' >&2
  ;;
 status) docker compose ps ;;
 logs|restart)
  action="$1"; n="${2:-1}"; [[ "$n" =~ ^[1-5]$ ]] || exit 2
  if [[ "$action" == logs ]]; then docker compose logs --tail=100 "warp-$n" "http-proxy-$n"; else docker compose restart "warp-$n" "http-proxy-$n"; fi
  ;;
 start) docker compose up -d --build ;;
 stop) docker compose stop ;;
 *) echo 'Usage: bash manage.sh {start|stop|status|check|ips|list PUBLIC_IP|logs N|restart N}' ;;
esac
