#!/usr/bin/env bash
set -euo pipefail
[[ ${EUID} -eq 0 ]] || { echo 'Run as root'; exit 1; }
command -v docker >/dev/null || { echo 'Install Docker Engine and Compose plugin first: https://docs.docker.com/engine/install/'; exit 1; }
docker compose version >/dev/null || { echo 'Docker Compose v2 required'; exit 1; }
command -v git >/dev/null || { echo 'Install git first'; exit 1; }
dest=/opt/warp-http-proxy
if [[ ! -d "$dest/.git" ]]; then git clone https://github.com/acc66/warp-ai-unlock.git "$dest"; else git -C "$dest" pull --ff-only; fi
cd "$dest/docker-http-proxy"
if [[ ! -f .env ]]; then
  umask 077
  read -rp 'Proxy username [warpuser]: ' u
  u=${u:-warpuser}
  read -rsp 'Proxy password (blank = random): ' p; echo
  if [[ -z "$p" ]]; then p=$(openssl rand -hex 20); fi
  [[ "$u" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid username'; exit 1; }
  [[ "$p" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Use letters, numbers, _ or - in password'; exit 1; }
  printf 'PROXY_USER=%s\nPROXY_PASS=%s\nPROXY_PORT=40001\nBIND_IP=0.0.0.0\n' "$u" "$p" > .env
fi
docker compose config -q
docker compose up -d --build
echo 'Installed. Open TCP 40001 only for trusted client IPs.'
echo 'Credentials: /opt/warp-http-proxy/docker-http-proxy/.env'
echo 'Test: cd /opt/warp-http-proxy/docker-http-proxy && bash test.sh'
