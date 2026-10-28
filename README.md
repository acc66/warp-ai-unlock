# warp-ai-unlock

用 Cloudflare WARP 给 [XboardNode-Plus](https://github.com/acc66/XboardNode-Plus) 节点解锁 ChatGPT / Claude / Gemini 等 AI 服务，规则由 wp2 面板下发。

原理：节点上用 [wgcf](https://github.com/ViRb3/wgcf) 注册 WARP，用 [wireproxy](https://github.com/whyvl/wireproxy) 在 `127.0.0.1:40000` 开一个 SOCKS5。面板下发 socks 出站加域名路由，只让 AI 域名走 WARP，其余流量照常直连。xray 和 sing-box 两个内核都能用。

## 0. 先检测：本机是否需要 WARP

```bash
wget -qO- https://raw.githubusercontent.com/acc66/warp-ai-unlock/main/warp-ai.sh | bash
```

在终端里运行会进入菜单，没有终端时直接跑 AI 解锁检测。检测会把 ChatGPT / Claude / Gemini 的直连结果和 WARP 结果并排列出来：

```
Service     Direct            WARP
ChatGPT     App Only (HK)     Yes (US)
Claude      No (HK)           Yes (US)
Gemini      No (HKG)          Yes (USA)
```

- `Yes`：可用。`No`：地区不支持。`Web Only` / `App Only`：ChatGPT 只有网页版或只有 App 能用。括号里是服务端识别到的地区。
- 直连已经全是 `Yes`，就不用装 WARP。

只跑检测：

```bash
wget -qO- https://raw.githubusercontent.com/acc66/warp-ai-unlock/main/warp-ai.sh | bash -s check
```

## 1. 节点安装

root 运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/acc66/warp-ai-unlock/main/warp-ai.sh) install
```

装好后脚本会自动跑一次 AI 解锁检测。

可选环境变量：

| 变量 | 说明 | 默认 |
|------|------|------|
| `SOCKS_PORT` | 本地 SOCKS5 端口 | `40000` |
| `WARP_KEY` | WARP+ license key，留空就用免费版 | 空 |

```bash
SOCKS_PORT=40001 WARP_KEY=xxxxxxxx-xxxxxxxx-xxxxxxxx bash warp-ai.sh install
```

装完会自检，看到 `WARP 正常: ip=... warp=on` 就说明通了。

## 2. 面板配置

wp2 后台 → 节点 → 编辑，填两个框。

**自定义出站（JSON）**，sing-box 内核（XboardNode-Plus 默认）：

```json
[
  {"tag": "warp", "protocol": "socks",
   "settings": {"server": "127.0.0.1", "server_port": 40000, "version": "5"}}
]
```

Xray 内核换成：

```json
[
  {"tag": "warp", "protocol": "socks",
   "settings": {"servers": [{"address": "127.0.0.1", "port": 40000}]}}
]
```

**自定义路由规则（JSON）**，两个内核通用：

```json
[
  {"name": "ai-warp",
   "match": {"domain_suffixes": [
     "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "sora.com",
     "anthropic.com", "claude.ai", "claude.com",
     "gemini.google.com", "bard.google.com", "aistudio.google.com",
     "generativelanguage.googleapis.com", "alkalimakersuite-pa.clients6.google.com",
     "makersuite.google.com", "notebooklm.google.com", "deepmind.google",
     "perplexity.ai", "x.ai", "grok.com", "copilot.microsoft.com", "meta.ai"
   ]},
   "action": {"type": "route", "target": "warp"}}
]
```

保存后等约 60 秒，节点拉取到新配置就会生效。也可以在节点上运行 `bash warp-ai.sh panel` 重新打印这几段。

想把 Netflix 之类的服务也走 WARP，把对应域名加进 `domain_suffixes` 就行。

## 3. 管理命令

```bash
bash warp-ai.sh            # 交互菜单
bash warp-ai.sh check      # AI 解锁检测（直连 vs WARP）
bash warp-ai.sh key <key>  # 绑定 / 更换 WARP+ key
bash warp-ai.sh status     # 服务状态 + WARP 连通性
bash warp-ai.sh panel      # 重新打印面板 JSON
bash warp-ai.sh uninstall  # 卸载
journalctl -u warp-ai -f   # 查看日志
```

## 流量与套餐

- **免费 WARP**：没有流量上限，可以一直用。速度看线路，高峰期可能变慢。
- **WARP+**：付费订阅，同样不限流量，区别是走 Cloudflare 的 Argo 智能路由，速度和稳定性更好。早年邀请好友送的 "WARP+ 流量" 是加速额度，用完会回落到免费 WARP，网络不会断。
- **开通 WARP+**：手机装 Cloudflare 的 **1.1.1.1** App → 订阅 WARP+（价格按地区不同，以 App 内显示为准）→ 菜单 → 账户 → 按键，复制 license key，然后：
  ```bash
  WARP_KEY=你的key bash warp-ai.sh install
  ```
  已经装好的节点直接绑定，不用重装（菜单里选 5 也可以）：
  ```bash
  bash warp-ai.sh key xxxxxxxx-xxxxxxxx-xxxxxxxx
  ```
  绑定成功后，出口会显示 `warp=plus`。如果绑定失败（key 无效或已经绑满），会自动退回原来的账户，不会断网。一个 key 最多绑 5 台设备。

解锁 AI 的关键是 IP 是否干净，跟速度关系不大，所以一般用免费版就够了。

## 常见问题

- **注册失败**：Cloudflare 对注册接口有频率限制，过几分钟再试。
- **直连 Gemini 显示 `No (CHN)`，而 ChatGPT 是 `Yes (US)`**：每家用的 IP 库不一样，Google 可能把你这台机器的 IP 判成中国。Gemini 的域名已经在路由规则里，下发后走 WARP 就能解决。
- **AI 网站仍然打不开或提示地区不支持**：WARP 出口 IP 由 Cloudflare 分配，偶尔会分到被限制的段。可以运行 `bash warp-ai.sh uninstall && bash warp-ai.sh install` 重新注册换 IP，再用 `status` 查看出口 `loc`。
- **规则不生效**：路由按域名匹配，客户端要以域名的形式发请求（默认都是这样）。确认面板里两个框的 JSON 都已保存，并且 `target` 和出站的 `tag` 一致（都是 `warp`）。
- **纯 IPv6 机器**：脚本会自动切到 WARP 的 IPv6 endpoint。

## 安全说明

SOCKS5 只监听 `127.0.0.1`，没有认证，外部访问不到，不要改成 `0.0.0.0`。WARP 私钥保存在 `/etc/warp-ai/` 下。
