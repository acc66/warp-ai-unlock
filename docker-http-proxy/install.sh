#!/usr/bin/env bash
set -euo pipefail
[[ ${EUID} -eq 0 ]] || { echo 'Run as root'; exit 1; }
for cmd in docker git curl openssl; do command -v "$cmd" >/dev/null || { echo "Missing $cmd"; exit 1; }; done
docker compose version >/dev/null || { echo 'Docker Compose v2 required'; exit 1; }
dest=/opt/warp-http-proxy
if [[ ! -d "$dest/.git" ]]; then git clone https://github.com/acc66/warp-ai-unlock.git "$dest"; else git -C "$dest" pull --ff-only; fi
cd "$dest/docker-http-proxy"
if [[ ! -f .env ]]; then
 umask 077
 read -rp 'Proxy username [warpuser]: ' u; u=${u:-warpuser}
 read -rsp 'Proxy password (blank = random): ' p; echo
 if [[ -z "$p" ]]; then p=$(openssl rand -hex 20); fi
 [[ "$u" =~ ^[a-zA-Z0-9_-]+$ && "$p" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Use letters, digits, _ and -'; exit 1; }
 printf 'PROXY_USER=%s\nPROXY_PASS=%s\nBIND_IP=0.0.0.0\n' "$u" "$p" > .env
fi
chmod 600 .env
docker compose config -q
docker compose up -d --build
echo 'Installed five HTTP proxy ports 40001-40005.'
echo 'Run: cd /opt/warp-http-proxy/docker-http-proxy && bash manage.sh check'
echo 'Run: bash manage.sh list YOUR_PUBLIC_IP'
echo 'Restrict inbound ports 40001-40005 to trusted IPs.'
