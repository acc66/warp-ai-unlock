#!/usr/bin/env bash
# WARP SOCKS5 for XboardNode-Plus AI unlock
# 用法: warp-ai [install|uninstall|status|check|key|panel|update|version|timer|logs]，不带参数进入菜单
set -uo pipefail

VERSION=1.2.0
SCRIPT_URL=https://raw.githubusercontent.com/acc66/warp-ai-unlock/main/warp-ai.sh
SELF=/usr/local/bin/warp-ai
SOURCE_SCRIPT=${BASH_SOURCE[0]}

WARP_DIR=/etc/warp-ai
BIN_DIR=/usr/local/bin
SOCKS_PORT="${SOCKS_PORT:-40000}"
SERVICE=warp-ai
TIMER_UNIT=${SERVICE}-reconnect
SYSTEMD_DIR=/etc/systemd/system
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
  local tmp; tmp=$(mktemp)
  curl -fL -o "$tmp" \
    "https://github.com/ViRb3/wgcf/releases/download/v${v}/wgcf_${v}_linux_${ARCH}" \
    || { rm -f "$tmp"; die "wgcf 下载失败"; }
  chmod +x "$tmp" && mv -f "$tmp" "$BIN_DIR/wgcf"
}

install_wireproxy() {
  local v; v=$(latest_tag whyvl/wireproxy); v=${v:-$WIREPROXY_FALLBACK}
  # 先解压到临时目录再 mv，升级时不会碰到正在运行的二进制（Text file busy）
  local d; d=$(mktemp -d)
  curl -fL "https://github.com/whyvl/wireproxy/releases/download/${v}/wireproxy_linux_${ARCH}.tar.gz" \
    | tar xz -C "$d" wireproxy || { rm -rf "$d"; die "wireproxy 下载失败"; }
  if ! chmod +x "$d/wireproxy" || ! mv -f "$d/wireproxy" "$BIN_DIR/wireproxy"; then
    rm -rf "$d"
    return 1
  fi
  rm -rf "$d"
}

# 按路由表选 endpoint：有 v4 路由用 v4，只有 v6 才用 v6；可用 WARP_ENDPOINT 手动指定
pick_endpoint() {
  if [[ -n "${WARP_ENDPOINT:-}" ]]; then
    echo "$WARP_ENDPOINT"
  elif ip -4 route get 162.159.192.1 >/dev/null 2>&1; then
    echo "162.159.192.1:2408"
  elif ip -6 route get 2606:4700:d0::a29f:c001 >/dev/null 2>&1; then
    echo "[2606:4700:d0::a29f:c001]:2408"
  else
    echo "162.159.192.1:2408"
  fi
}

register_warp() {
  mkdir -p "$WARP_DIR" && cd "$WARP_DIR" || die "无法创建 $WARP_DIR"
  if [[ ! -f wgcf-account.toml ]]; then
    wgcf register --accept-tos >/dev/null || die "WARP 注册失败（可能被 CF 限速，稍后重试）"
  fi
  # WARP+ license（可选）：WARP_KEY=xxxx bash warp-ai.sh install
  [[ -n "${WARP_KEY:-}" ]] && apply_key "$WARP_KEY"
  gen_profile
}

# 绑定 WARP+ key，失败返回 1（保留原账户继续用免费版）
apply_key() {
  local key=$1
  [[ "$key" =~ ^[A-Za-z0-9]{8}-[A-Za-z0-9]{8}-[A-Za-z0-9]{8}$ ]] \
    || { red "key 格式不对，应为 xxxxxxxx-xxxxxxxx-xxxxxxxx"; return 1; }
  cd "$WARP_DIR" || return 1
  cp wgcf-account.toml wgcf-account.toml.bak
  sed -i "s/^license_key = .*/license_key = '${key}'/" wgcf-account.toml
  if ! wgcf update; then
    mv wgcf-account.toml.bak wgcf-account.toml
    red "WARP+ key 绑定失败（key 无效或已绑满 5 台设备），继续使用原账户"
    return 1
  fi
  rm -f wgcf-account.toml.bak
}

gen_profile() {
  cd "$WARP_DIR" || die "找不到 $WARP_DIR"
  wgcf generate >/dev/null || die "生成 WARP 配置失败"
  # 替换 endpoint 兼容纯 v6
  local ep; ep=$(pick_endpoint)
  sed -i "s|^Endpoint = .*|Endpoint = ${ep}|" wgcf-profile.conf
  sed -i "s|^MTU = .*|MTU = 1280|" wgcf-profile.conf
  chmod 644 wgcf-profile.conf
}

# 已安装的节点单独绑定 / 更换 WARP+ key
do_key() {
  [[ -f "$WARP_DIR/wgcf-account.toml" ]] || die "还没安装 WARP，先运行 install"
  local key=${1:-}
  [[ -z "$key" ]] && read -rp "输入 WARP+ key: " key </dev/tty
  apply_key "$key" || return 1
  gen_profile
  systemctl restart ${SERVICE} || die "服务重启失败: journalctl -u ${SERVICE} -n 50"
  sleep 3
  warp_ok
  # trace 里的 warp=plus 对 wgcf 客户端不可靠，以账户类型为准
  local type
  type=$(cd "$WARP_DIR" && wgcf status 2>/dev/null | sed -n 's/^Account type *: *//p')
  case "$type" in
    unlimited|limited) green "WARP+ 已生效（Account type: $type）" ;;
    *) yellow "账户类型为 ${type:-未知}，key 没生效，确认是 1.1.1.1 App 里 WARP+ 的 key" ;;
  esac
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
  systemctl daemon-reload || return 1
  systemctl enable ${SERVICE} >/dev/null 2>&1 || return 1
  systemctl restart ${SERVICE} || die "服务启动失败: journalctl -u ${SERVICE} -n 50"
}

WARP_PX=(-x "socks5h://127.0.0.1:${SOCKS_PORT}")

warp_ok() {
  local trace
  if ! probe_http "${WARP_PX[@]}" https://www.cloudflare.com/cdn-cgi/trace; then
    red "WARP 连接失败: $(probe_error)，查看日志: journalctl -u ${SERVICE} -n 50"
    return 1
  fi
  trace=$PROBE_BODY
  if [[ "$PROBE_CODE" == 200 ]] && grep -qE $'^warp=(on|plus)\r?$' <<<"$trace"; then
    green "WARP 正常: $(grep -E '^(ip|loc|warp)=' <<<"$trace" | tr '\n' ' ')"
  else
    red "WARP 未连通，查看日志: journalctl -u ${SERVICE} -n 50"
    return 1
  fi
}

# ---------- AI 解锁检测，参数为 curl 代理参数（空 = 直连） ----------
# 显式禁用环境代理；传入 -x 时使用指定代理，同时忽略 NO_PROXY 绕过规则。
# curl 退出码比错误文本稳定，不依赖系统语言，也不泄露代理凭据。
probe_error() {
  case "$PROBE_RC" in
    5) echo 'Proxy DNS' ;;
    6) echo 'DNS' ;;
    7) echo 'Connect' ;;
    28) echo 'Timeout' ;;
    35|60) echo 'TLS' ;;
    97) echo 'SOCKS handshake' ;;
    *) echo "curl:$PROBE_RC" ;;
  esac
}

loc_of() {
  if probe_http "$@" "$URL_TRACE" && [[ "$PROBE_CODE" == 200 ]]; then
    sed -n 's/^loc=//p' <<<"$PROBE_BODY" | tr -d '\r'
  fi
}

probe_http() {
  local response meta
  PROBE_BODY= PROBE_CODE=000 PROBE_URL= PROBE_RC=0
  response=$(curl --disable --proxy '' --noproxy '' "$@" -sS -L \
    --connect-timeout 5 -m 15 -A "$UA" \
    -w '\n%{http_code} %{url_effective}' 2>/dev/null) || PROBE_RC=$?
  meta=${response##*$'\n'}
  PROBE_BODY=${response%$'\n'*}
  PROBE_CODE=${meta%% *}
  PROBE_URL=${meta#* }
  (( PROBE_RC == 0 ))
}

probe_challenged() {
  grep -qiE 'captcha|just a moment|cf-chl-|access denied' <<<"$PROBE_BODY"
}

probe_unknown() {
  if probe_challenged; then
    echo "Challenge/HTTP $PROBE_CODE"
  else
    echo "HTTP $PROBE_CODE"
  fi
}

check_chatgpt() {
  local region_state=unknown ios_state=unknown loc
  if probe_http "$@" https://api.openai.com/compliance/cookie_requirements \
      -H 'authorization: Bearer null' -H 'origin: https://platform.openai.com' \
      -H 'referer: https://platform.openai.com/'; then
    if grep -qiE 'unsupported_country|unsupported_country_region_territory' <<<"$PROBE_BODY"; then
      region_state=blocked
    elif probe_challenged; then
      region_state=$(probe_unknown)
    elif [[ "$PROBE_CODE" == 2?? ]] && [[ "$PROBE_BODY" =~ ^[[:space:]]*\{ ]] \
        && ! grep -qiE '"(error|errors)"[[:space:]]*:' <<<"$PROBE_BODY"; then
      region_state=ok
    else
      region_state=$(probe_unknown)
    fi
  else
    region_state=$(probe_error)
  fi
  if probe_http "$@" https://ios.chat.openai.com/; then
    if grep -qiE 'unsupported_country|blocked_why_headline|disallowed isp|VPN you are using|Please disable your VPN' <<<"$PROBE_BODY"; then
      ios_state=blocked
    elif [[ "$PROBE_CODE" == 2?? && -n "$PROBE_BODY" ]] \
        && ! probe_challenged; then
      ios_state=ok
    else
      ios_state=$(probe_unknown)
    fi
  else
    ios_state=$(probe_error)
  fi
  loc=$(URL_TRACE=https://chatgpt.com/cdn-cgi/trace loc_of "$@")
  # compliance 端点只检查 OpenAI 地区策略，不代表 ChatGPT 网页已通过。
  # App 探测失败时仍保留已经确认的地区结果。
  case "$region_state/$ios_state" in
    ok/ok) echo "OK Region+App OK (${loc:-?})" ;;
    ok/blocked) echo "WARN Region OK; App blocked (${loc:-?})" ;;
    blocked/ok) echo "WARN Region blocked; App OK (${loc:-?})" ;;
    blocked/blocked) echo "NO Region+App blocked (${loc:-?})" ;;
    ok/*) echo "WARN Region OK; App:$ios_state" ;;
    blocked/*) echo "NO Region blocked; App:$ios_state" ;;
    *) echo "WARN Region:$region_state; App:$ios_state" ;;
  esac
}

check_claude() {
  local loc
  if ! probe_http "$@" https://claude.ai/; then
    echo "ERR Failed ($(probe_error))"; return
  fi
  if [[ "$PROBE_URL" == *app-unavailable-in-region* ]]; then
    echo "NO No (Region)"; return
  fi
  if [[ "$PROBE_CODE" != 2?? || -z "$PROBE_BODY" ]] \
      || grep -qiE 'captcha|just a moment|cf-chl-|access denied' <<<"$PROBE_BODY"; then
    echo "WARN Probe blocked ($(probe_unknown))"; return
  fi
  loc=$(URL_TRACE=https://claude.ai/cdn-cgi/trace loc_of "$@")
  echo "OK Page OK (${loc:-?})"
}

# Google 页面中的地区代码仅作参考；Page OK 只表示页面可访问，不证明账号能对话。

check_gemini() {
  local html region
  if ! probe_http "$@" -H 'accept-language: en-US' https://gemini.google.com/; then
    echo "ERR Failed ($(probe_error))"; return
  fi
  if [[ "$PROBE_CODE" != 2?? || -z "$PROBE_BODY" ]]; then
    echo "WARN Probe blocked ($(probe_unknown))"; return
  fi
  if probe_challenged; then
    echo "WARN Probe blocked ($(probe_unknown))"; return
  fi
  html=$PROBE_BODY
  region=$(grep -oE ',2,1,200,"[A-Z]{3}"' <<<"$html" | head -1 | grep -oE '[A-Z]{3}')
  if [[ -z "$region" ]]; then
    echo "WARN Page OK (Region:unparsed)"
  else
    echo "OK Page OK (Region:$region)"
  fi
}


paint() { # 按结果前缀上色
  local s=${1#* }
  case "${1%% *}" in
    OK) printf '\033[32m%-58s\033[0m' "$s" ;;
    WARN) printf '\033[33m%-58s\033[0m' "$s" ;;
    NO|ERR) printf '\033[31m%-58s\033[0m' "$s" ;;
    *) printf '%-58s' "$1" ;;
  esac
}

check_ai() {
  local has_warp=0 svc direct_trace= warp_trace= direct_error= warp_error=
  if probe_http https://www.cloudflare.com/cdn-cgi/trace; then
    direct_trace=$PROBE_BODY
    [[ "$PROBE_CODE" == 200 ]] || direct_error="HTTP $PROBE_CODE"
  else
    direct_error=$(probe_error)
  fi
  if probe_http "${WARP_PX[@]}" https://www.cloudflare.com/cdn-cgi/trace; then
    warp_trace=$PROBE_BODY
    if [[ "$PROBE_CODE" == 200 ]] && grep -qE $'^warp=(on|plus)\r?$' <<<"$warp_trace"; then
      has_warp=1
    else
      warp_error="HTTP $PROBE_CODE / trace 未确认 WARP"
    fi
  else
    warp_error=$(probe_error)
  fi

  echo
  echo "============ AI 解锁检测 ============"
  echo "直连出口: $(sed -n 's/^ip=//p' <<<"$direct_trace")${direct_error:+ (失败: $direct_error)}"
  if (( has_warp )); then
    echo "WARP 出口: $(sed -n 's/^ip=//p' <<<"$warp_trace")"
  else
    yellow "WARP 检测失败: $warp_error（SOCKS 127.0.0.1:${SOCKS_PORT}），只检测直连"
  fi
  echo "-------------------------------------"
  printf '%-12s%-58s%s\n' "Service" "Direct" "WARP"
  local -A name=([chatgpt]=ChatGPT [claude]=Claude [gemini]=Gemini)
  # 每条探测有独立的进程/结果文件，避免多个服务串行等待超时。
  # 子 shell 的 EXIT trap 仅清理本轮临时文件，不覆盖调用者的 trap。
  (
    local results
    results=$(mktemp -d) || { red "无法创建检测临时目录"; exit 1; }
    trap 'rm -rf -- "$results"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for svc in chatgpt claude gemini; do
      "check_$svc" >"$results/$svc.direct" &
      if (( has_warp )); then
        "check_$svc" "${WARP_PX[@]}" >"$results/$svc.warp" &
      fi
    done
    wait
    for svc in chatgpt claude gemini; do
      printf '%-12s' "${name[$svc]}"
      paint "$(<"$results/$svc.direct")"
      if (( has_warp )); then paint "$(<"$results/$svc.warp")"; else printf -- '-'; fi
      echo
    done
  ) || return 1
  echo "-------------------------------------"
  echo "Region OK=地区检查通过；Page OK=页面可访问；App OK=App 探测通过。均不保证账号能对话。"
  echo "Probe blocked=检测请求被拦；Challenge=人机验证，无法确认解锁。DNS/Connect/Timeout/TLS 为网络错误。"
}

print_panel() {
  local domains='"openai.com","chatgpt.com","oaistatic.com","oaiusercontent.com","sora.com","anthropic.com","claude.ai","claude.com","gemini.google.com","bard.google.com","aistudio.google.com","generativelanguage.googleapis.com","alkalimakersuite-pa.clients6.google.com","makersuite.google.com","notebooklm.google.com","deepmind.google","perplexity.ai","x.ai","grok.com","copilot.microsoft.com","meta.ai","metaaivm.com","metaaiusercontent.com"'

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
  install_deps || die "依赖安装失败"
  install_wgcf || die "wgcf 安装失败"
  install_wireproxy || die "wireproxy 安装失败"
  register_warp || die "WARP 配置失败"
  write_config || die "服务配置失败"
  install_self || die "warp-ai 命令安装失败"
  sleep 3
  warp_ok || return 1
  check_ai || return 1
  print_panel
  green "\n以后直接运行 warp-ai 即可打开菜单"
}

# 下载最新脚本到临时文件，校验语法后输出路径
fetch_script() {
  local tmp; tmp=$(mktemp) || return 1
  if ! curl -fsSL -m 30 "$SCRIPT_URL" -o "$tmp" || ! bash -n "$tmp" 2>/dev/null \
     || ! grep -q '^VERSION=' "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  echo "$tmp"
}

# 装成 /usr/local/bin/warp-ai；用 mv 替换，避免覆盖正在运行的脚本
install_self() {
  local tmp
  tmp=$(mktemp) || return 1
  # 本地执行时安装当前脚本，避免下载旧版覆盖本地修复；管道执行才从远端下载。
  if [[ -f "$SOURCE_SCRIPT" && -r "$SOURCE_SCRIPT" ]]; then
    cp -- "$SOURCE_SCRIPT" "$tmp" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp"
    tmp=$(fetch_script) || return 1
  fi
  if ! bash -n "$tmp" || ! chmod 755 "$tmp" || ! mv -f "$tmp" "$SELF"; then
    rm -f "$tmp"
    return 1
  fi
}

remote_version() { curl -fsSL -m 10 "$SCRIPT_URL" 2>/dev/null | sed -n 's/^VERSION=//p' | head -1; }

do_version() {
  echo "当前版本: $VERSION"
  local r; r=$(remote_version)
  echo "最新版本: ${r:-获取失败}"
  [[ -n "$r" && "$r" != "$VERSION" ]] && yellow "有新版本，运行 warp-ai update 升级"
  [[ -x "$BIN_DIR/wgcf" ]] && echo "wgcf: $("$BIN_DIR/wgcf" --version 2>/dev/null | head -1)"
  [[ -x "$BIN_DIR/wireproxy" ]] && echo "wireproxy: $("$BIN_DIR/wireproxy" --version 2>/dev/null | head -1)"
  return 0
}

# 在线升级：脚本 + wgcf + wireproxy，配置和账户不动
do_update() {
  local tmp new
  tmp=$(fetch_script) || die "下载新版本失败，请检查网络"
  new=$(sed -n 's/^VERSION=//p' "$tmp" | head -1)
  if [[ "$new" != "$VERSION" && "$(printf '%s\n' "$VERSION" "$new" | sort -V | head -1)" == "$new" ]]; then
    rm -f "$tmp"
    die "远端版本 $new 低于当前版本 $VERSION，已阻止降级"
  fi
  if [[ "$new" == "$VERSION" && "${1:-}" != "-f" ]]; then
    green "已是最新版本 $VERSION"
  else
    chmod 755 "$tmp" && mv -f "$tmp" "$SELF"
    green "脚本已升级: $VERSION -> $new"
  fi
  rm -f "$tmp"
  if [[ -f "$WARP_DIR/wireproxy.conf" ]]; then
    detect_arch
    echo "更新 wgcf / wireproxy ..."
    install_wgcf
    install_wireproxy
    systemctl restart ${SERVICE} || die "服务重启失败: journalctl -u ${SERVICE} -n 50"
    sleep 3
    warp_ok
  fi
  green "升级完成，运行 warp-ai 使用新版本"
}

do_uninstall() {
  timer_remove || return 1
  systemctl disable --now ${SERVICE} 2>/dev/null
  rm -f /etc/systemd/system/${SERVICE}.service "$BIN_DIR/wireproxy" "$BIN_DIR/wgcf" "$SELF"
  rm -rf "$WARP_DIR"
  systemctl daemon-reload
  green "已卸载"
}

# 定时重启只重连服务，不重新安装或注册账户。
timer_status() {
  if [[ ! -f "$SYSTEMD_DIR/$TIMER_UNIT.timer" ]]; then
    echo "定时重启：未开启"
    return 0
  fi
  local interval
  interval=$(sed -n 's/^OnUnitActiveSec=//p' "$SYSTEMD_DIR/$TIMER_UNIT.timer")
  echo "定时重启间隔：${interval:-未知}"
  systemctl is-enabled "$TIMER_UNIT.timer" || return 1
  systemctl list-timers --all "$TIMER_UNIT.timer" --no-pager
}

timer_set() {
  local interval=${1-1h}
  # 不把任意输入写入 systemd；支持正整数分钟、小时、天。
  if [[ ! "$interval" =~ ^[1-9][0-9]{0,5}[mhd]$ ]]; then
    red "间隔格式错误：请输入正整数加 m/h/d，例如 30m、1h、3h、1d"
    return 1
  fi
  [[ -f "$SYSTEMD_DIR/$SERVICE.service" ]] || { red "请先安装 WARP"; return 1; }
  cat > "$SYSTEMD_DIR/$TIMER_UNIT.service" <<EOF
[Unit]
Description=Reconnect WARP AI tunnel

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl try-restart $SERVICE.service
EOF
  [[ $? -eq 0 ]] || return 1
  cat > "$SYSTEMD_DIR/$TIMER_UNIT.timer" <<EOF
[Unit]
Description=Reconnect WARP AI every $interval

[Timer]
OnActiveSec=$interval
OnUnitActiveSec=$interval
AccuracySec=1s
Unit=$TIMER_UNIT.service

[Install]
WantedBy=timers.target
EOF
  [[ $? -eq 0 ]] || return 1
  chmod 644 "$SYSTEMD_DIR/$TIMER_UNIT.service" "$SYSTEMD_DIR/$TIMER_UNIT.timer" || return 1
  systemctl daemon-reload || return 1
  systemctl enable "$TIMER_UNIT.timer" || return 1
  # restart 让修改后的间隔从现在重新计时，不立即重启 WARP。
  systemctl restart "$TIMER_UNIT.timer" || return 1
  green "已开启每 $interval 重启 WARP（开机自动启用）"
  timer_status
}

timer_remove() {
  if [[ -f "$SYSTEMD_DIR/$TIMER_UNIT.timer" ]]; then
    systemctl disable --now "$TIMER_UNIT.timer" || return 1
  fi
  if [[ -f "$SYSTEMD_DIR/$TIMER_UNIT.service" ]]; then
    systemctl stop "$TIMER_UNIT.service" || return 1
  fi
  rm -f "$SYSTEMD_DIR/$TIMER_UNIT.timer" "$SYSTEMD_DIR/$TIMER_UNIT.service" || return 1
  systemctl daemon-reload || return 1
  green "已删除定时重启任务"
}

do_logs() {
  case "${1:-}" in
    "") journalctl -u "$SERVICE" -n 100 --no-pager ;;
    -f|--follow) journalctl -u "$SERVICE" -n 100 -f ;;
    *) echo "用法: warp-ai logs [-f|--follow]"; return 1 ;;
  esac
}

timer_menu() {
  local choice interval
  while true; do
    echo
    echo "===== 定时重启 WARP ====="
    timer_status
    echo " 1. 开启每小时重启"
    echo " 2. 自定义重启间隔"
    echo " 3. 删除定时任务"
    echo " 0. 返回"
    read -rp "请选择: " choice </dev/tty || return 0
    case "$choice" in
      1) need_root; timer_set 1h ;;
      2) need_root
         read -rp "输入间隔（如 30m=30分钟、3h=3小时、1d=1天）: " interval </dev/tty || return 0
         timer_set "$interval" ;;
      3) need_root; timer_remove ;;
      0) return 0 ;;
      *) red "无效选项" ;;
    esac
  done
}

do_timer() {
  case "${1:-status}" in
    status) timer_status ;;
    off|delete) need_root; timer_remove ;;
    *) need_root; timer_set "$1" ;;
  esac
}

menu() {
  local c
  while true; do
    echo
    echo "===== WARP AI 解锁 v${VERSION} ====="
    echo " 1. 安装 / 重装 WARP"
    echo " 2. AI 解锁检测"
    echo " 3. 查看状态"
    echo " 4. 打印面板配置"
    echo " 5. 绑定 / 更换 WARP+ key"
    echo " 6. 在线升级"
    echo " 7. 卸载"
    echo " 8. 定时重启（每小时 / 自定义 / 删除）"
    echo " 9. 查看日志（最近 100 条）"
    echo " 0. 退出"
    # 兼容 curl | bash：从终端读输入
    read -rp "请选择: " c </dev/tty || exit 0
    case "$c" in
      1) need_root; do_install ;;
      2) check_ai ;;
      3) systemctl status ${SERVICE} --no-pager; warp_ok ;;
      4) print_panel ;;
      5) need_root; do_key ;;
      6) need_root; do_update; exit 0 ;;
      7) need_root; do_uninstall ;;
      8) timer_menu ;;
      9) do_logs ;;
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
  logs|log)  do_logs "${2:-}" ;;
  key)       need_root; do_key "${2:-}" ;;
  panel)     print_panel ;;
  timer)     do_timer "${2:-status}" ;;
  update)    need_root; do_update "${2:-}" ;;
  version|-v|--version) do_version ;;
  "")        if [[ -r /dev/tty ]]; then menu; else check_ai; fi ;;
  *) echo "warp-ai v${VERSION}"
     echo "用法: warp-ai [install|uninstall|status|check|key|panel|update|version|timer|logs]" ;;
esac
