#!/usr/bin/env bash
# WARP SOCKS5 for XboardNode-Plus AI unlock
# 用法: bash warp-ai.sh [install|uninstall|status|check|panel]，不带参数进入菜单
set -uo pipefail

WARP_DIR=/etc/warp-ai
BIN_DIR=/usr/local/bin
SOCKS_PORT="${SOCKS_PORT:-40000}"
SERVICE=warp-ai
WGCF_FALLBACK=2.2.29
WIREPROXY_FALLBACK=v1.0.9

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
die()    { red "$*"; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "请用 root 运行"; }

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

install_deps() {
  if command -v apt-get >/dev/null; then
    apt-get update -y && apt-get install -y curl tar
  elif command -v dnf >/dev/null; then
    dnf install -y curl tar
  elif command -v yum >/dev/null; then
    yum install -y curl tar
  fi
}

latest_tag() { # $1=owner/repo
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name"' | cut -d'"' -f4
}

install_wgcf() {
  local v; v=$(latest_tag ViRb3/wgcf); v=${v#v}; v=${v:-$WGCF_FALLBACK}
  curl -fL -o "$BIN_DIR/wgcf" \
    "https://github.com/ViRb3/wgcf/releases/download/v${v}/wgcf_${v}_linux_${ARCH}" \
    || die "wgcf 下载失败"
  chmod +x "$BIN_DIR/wgcf"
}

install_wireproxy() {
  local v; v=$(latest_tag whyvl/wireproxy); v=${v:-$WIREPROXY_FALLBACK}
  curl -fL "https://github.com/whyvl/wireproxy/releases/download/${v}/wireproxy_linux_${ARCH}.tar.gz" \
    | tar xz -C "$BIN_DIR" wireproxy || die "wireproxy 下载失败"
  chmod +x "$BIN_DIR/wireproxy"
}

# 纯 v6 机器用 v6 endpoint，否则用 v4
pick_endpoint() {
  if curl -4 -fsS -m 5 https://www.cloudflare.com/cdn-cgi/trace >/dev/null 2>&1; then
    echo "162.159.192.1:2408"
  else
    echo "[2606:4700:d0::a29f:c001]:2408"
  fi
}

register_warp() {
  mkdir -p "$WARP_DIR" && cd "$WARP_DIR" || die "无法创建 $WARP_DIR"
  if [[ ! -f wgcf-account.toml ]]; then
    wgcf register --accept-tos >/dev/null || die "WARP 注册失败（可能被 CF 限速，稍后重试）"
  fi
  # WARP+ license（可选）：WARP_KEY=xxxx bash warp-ai.sh install
  if [[ -n "${WARP_KEY:-}" ]]; then
    [[ "$WARP_KEY" =~ ^[A-Za-z0-9-]+$ ]] || die "WARP_KEY 格式不对"
    sed -i "s/^license_key = .*/license_key = '${WARP_KEY}'/" wgcf-account.toml
    wgcf update || red "WARP+ key 绑定失败，继续使用免费版"
  fi
  wgcf generate >/dev/null || die "生成 WARP 配置失败"
  # wireproxy 不需要 DNS/MTU 以外的字段；替换 endpoint 兼容纯 v6
  local ep; ep=$(pick_endpoint)
  sed -i "s|^Endpoint = .*|Endpoint = ${ep}|" wgcf-profile.conf
  sed -i "s|^MTU = .*|MTU = 1280|" wgcf-profile.conf
}

write_config() {
  cat > "$WARP_DIR/wireproxy.conf" <<EOF
WGConfig = $WARP_DIR/wgcf-profile.conf

[Socks5]
BindAddress = 127.0.0.1:${SOCKS_PORT}
EOF

  cat > /etc/systemd/system/${SERVICE}.service <<EOF
[Unit]
Description=WARP SOCKS5 (wireproxy) for AI unlock
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN_DIR/wireproxy -c $WARP_DIR/wireproxy.conf
Restart=always
RestartSec=5
DynamicUser=yes
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$WARP_DIR"/*.conf
  systemctl daemon-reload
  systemctl enable ${SERVICE} >/dev/null 2>&1
  systemctl restart ${SERVICE} || die "服务启动失败: journalctl -u ${SERVICE} -n 50"
}

WARP_PX=(-x "socks5h://127.0.0.1:${SOCKS_PORT}")

warp_ok() {
  local trace
  trace=$(curl -s -m 10 "${WARP_PX[@]}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
  if grep -qE "warp=(on|plus)" <<<"$trace"; then
    green "WARP 正常: $(grep -E '^(ip|loc|warp)=' <<<"$trace" | tr '\n' ' ')"
  else
    red "WARP 未连通，查看日志: journalctl -u ${SERVICE} -n 50"
    return 1
  fi
}

# ---------- AI 解锁检测，参数为 curl 代理参数（空 = 直连） ----------
loc_of() { curl "$@" -s -m 8 "$URL_TRACE" 2>/dev/null | sed -n 's/^loc=//p'; }

check_chatgpt() {
  local web ios loc w=0 i=0
  web=$(curl "$@" -s -m 10 -A "$UA" https://api.openai.com/compliance/cookie_requirements \
    -H 'authorization: Bearer null' -H 'origin: https://platform.openai.com' \
    -H 'referer: https://platform.openai.com/' 2>/dev/null)
  ios=$(curl "$@" -s -m 10 -A "$UA" https://ios.chat.openai.com/ 2>/dev/null)
  [[ -z "$web" && -z "$ios" ]] && { echo "ERR Failed (Network)"; return; }
  grep -qi 'unsupported_country' <<<"$web" && w=1
  grep -qi 'VPN' <<<"$ios" && i=1
  loc=$(URL_TRACE=https://chatgpt.com/cdn-cgi/trace loc_of "$@")
  case "$w$i" in
    00) echo "OK Yes (${loc:-?})" ;;
    01) echo "WARN Web Only (${loc:-?})" ;;
    10) echo "WARN App Only (${loc:-?})" ;;
    11) echo "NO No (${loc:-?})" ;;
  esac
}

check_claude() {
  local url loc
  url=$(curl "$@" -s -L -m 10 -A "$UA" -o /dev/null -w '%{url_effective}' https://claude.ai/ 2>/dev/null)
  [[ -z "$url" ]] && { echo "ERR Failed (Network)"; return; }
  loc=$(URL_TRACE=https://claude.ai/cdn-cgi/trace loc_of "$@")
  if [[ "$url" == *app-unavailable-in-region* ]]; then
    echo "NO No (${loc:-?})"
  else
    echo "OK Yes (${loc:-?})"
  fi
}

check_gemini() {
  local html region
  html=$(curl "$@" -s -L -m 10 -A "$UA" https://gemini.google.com/ 2>/dev/null)
  [[ -z "$html" ]] && { echo "ERR Failed (Network)"; return; }
  region=$(grep -oE ',2,1,200,"[A-Z]{3}"' <<<"$html" | head -1 | grep -oE '[A-Z]{3}')
  if grep -q '45631641,null,true' <<<"$html"; then
    echo "OK Yes (${region:-?})"
  else
    echo "NO No (${region:-?})"
  fi
}


paint() { # 按结果前缀上色
  local s=${1#* }
  case "${1%% *}" in
    OK) printf '\033[32m%-18s\033[0m' "$s" ;;
    WARN) printf '\033[33m%-18s\033[0m' "$s" ;;
    NO|ERR) printf '\033[31m%-18s\033[0m' "$s" ;;
    *) printf '%-18s' "$1" ;;
  esac
}

check_ai() {
  local has_warp=0 svc
  curl -s -m 8 "${WARP_PX[@]}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    | grep -qE "warp=(on|plus)" && has_warp=1

  echo
  echo "============ AI 解锁检测 ============"
  echo "直连出口: $(curl -s -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p')"
  if (( has_warp )); then
    echo "WARP 出口: $(curl -s -m 8 "${WARP_PX[@]}" https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^ip=//p')"
  else
    yellow "WARP 未安装或未运行，只检测直连"
  fi
  echo "-------------------------------------"
  printf '%-12s%-18s%s\n' "Service" "Direct" "WARP"
  local -A name=([chatgpt]=ChatGPT [claude]=Claude [gemini]=Gemini)
  for svc in chatgpt claude gemini; do
    printf '%-12s' "${name[$svc]}"
    paint "$(check_$svc)"
    if (( has_warp )); then paint "$(check_$svc "${WARP_PX[@]}")"; else printf -- '-'; fi
    echo
  done
  echo "-------------------------------------"
  echo "直连已解锁就不需要 WARP；WARP 列为绿色时，面板下发路由后节点即可解锁。"
}

print_panel() {
  local domains='"openai.com","chatgpt.com","oaistatic.com","oaiusercontent.com","sora.com","anthropic.com","claude.ai","claude.com","gemini.google.com","bard.google.com","aistudio.google.com","generativelanguage.googleapis.com","alkalimakersuite-pa.clients6.google.com","makersuite.google.com","notebooklm.google.com","deepmind.google","perplexity.ai","x.ai","grok.com","copilot.microsoft.com","meta.ai"'

  green "\n===== wp2 后台 -> 节点 -> 编辑，填两个框 ====="
  echo -e "\n【自定义出站（JSON）】sing-box 内核（XboardNode-Plus 默认）:"
  cat <<EOF
[
  {"tag": "warp", "protocol": "socks",
   "settings": {"server": "127.0.0.1", "server_port": ${SOCKS_PORT}, "version": "5"}}
]
EOF
  echo -e "\n【自定义出站（JSON）】Xray 内核用这个替换上面那段:"
  cat <<EOF
[
  {"tag": "warp", "protocol": "socks",
   "settings": {"servers": [{"address": "127.0.0.1", "port": ${SOCKS_PORT}}]}}
]
EOF
  echo -e "\n【自定义路由规则（JSON）】两个内核通用:"
  cat <<EOF
[
  {"name": "ai-warp", "match": {"domain_suffixes": [${domains}]},
   "action": {"type": "route", "target": "warp"}}
]
EOF
}

do_install() {
  detect_arch
  install_deps
  install_wgcf
  install_wireproxy
  register_warp
  write_config
  sleep 3
  warp_ok && check_ai
  print_panel
}

do_uninstall() {
  systemctl disable --now ${SERVICE} 2>/dev/null
  rm -f /etc/systemd/system/${SERVICE}.service "$BIN_DIR/wireproxy" "$BIN_DIR/wgcf"
  rm -rf "$WARP_DIR"
  systemctl daemon-reload
  green "已卸载"
}

menu() {
  local c
  while true; do
    echo
    echo "======== WARP AI 解锁 ========"
    echo " 1. 安装 / 重装 WARP"
    echo " 2. AI 解锁检测"
    echo " 3. 查看状态"
    echo " 4. 打印面板配置"
    echo " 5. 卸载"
    echo " 0. 退出"
    # 兼容 curl | bash：从终端读输入
    read -rp "请选择: " c </dev/tty || exit 0
    case "$c" in
      1) need_root; do_install ;;
      2) check_ai ;;
      3) systemctl status ${SERVICE} --no-pager; warp_ok ;;
      4) print_panel ;;
      5) need_root; do_uninstall ;;
      0) exit 0 ;;
      *) red "无效选项" ;;
    esac
  done
}

case "${1:-}" in
  install)   need_root; do_install ;;
  uninstall) need_root; do_uninstall ;;
  status)    systemctl status ${SERVICE} --no-pager; warp_ok ;;
  check)     check_ai ;;
  panel)     print_panel ;;
  "")        if [[ -r /dev/tty ]]; then menu; else check_ai; fi ;;
  *) echo "用法: $0 [install|uninstall|status|check|panel]" ;;
esac
