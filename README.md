# warp-ai-unlock

用 Cloudflare WARP 给代理节点解锁 ChatGPT / Claude / Gemini 等 AI 服务。支持两种后端：

- **XboardNode-Plus**（配合 wp2 面板）：路由规则在面板里填，自动下发到节点
- **soga**：改节点上的 `routes.toml`

## 原理

```
用户 ──> 节点(xboard-node / soga) ──┬── AI 域名 ──> 127.0.0.1:40000 (wireproxy) ──> Cloudflare WARP ──> ChatGPT/Claude/Gemini
                                     └── 其他流量 ──> 直连
```

- [wgcf](https://github.com/ViRb3/wgcf) 负责注册 WARP 账户，生成 WireGuard 配置
- [wireproxy](https://github.com/whyvl/wireproxy) 把 WireGuard 转成本地 SOCKS5，监听 `127.0.0.1:40000`
- 节点后端只把 AI 域名转发给这个 SOCKS5，其他流量照常直连，不影响速度

不改系统路由，也不改默认网卡，SSH 和其他业务不会受影响。

## 目录

1. [检测：本机需不需要 WARP](#1-检测本机需不需要-warp)
2. [安装 WARP](#2-安装-warp)
3. [配置后端：XboardNode-Plus + wp2 面板](#3a-配置后端xboardnode-plus--wp2-面板)
4. [配置后端：soga](#3b-配置后端soga)
5. [验证](#4-验证)
6. [WARP+ 与流量](#5-warp-与流量)
7. [管理命令](#6-管理命令)
8. [常见问题](#7-常见问题)

---

## 1. 检测：本机需不需要 WARP

```bash
wget -qO- https://raw.githubusercontent.com/acc66/warp-ai-unlock/main/warp-ai.sh | bash -s check
```

输出示例：

```
============ AI 解锁检测 ============
直连出口: 100.42.230.16
WARP 出口: 2a09:bac5:661c:1246::1d2:c9
-------------------------------------
Service     Direct            WARP
ChatGPT     Yes (US)          Yes (US)
Claude      Yes (US)          Yes (US)
Gemini      No (CHN)          Yes (USA)
-------------------------------------
```

| 结果 | 含义 |
|------|------|
| `Yes (地区)` | 可用 |
| `No (地区)` | 地区不支持 |
| `Web Only` / `App Only` | ChatGPT 只有网页版或只有 App 能用 |
| `Failed (Network)` | 连不上，检查网络或 WARP |

括号里是该服务识别到的地区。各家用的 IP 库不一样，同一个 IP 在 OpenAI 那里显示 US，在 Google 那里可能显示 CHN，这很正常。

**Direct 列全是 Yes 就不用装 WARP**，有 No 再继续往下装。

## 2. 安装 WARP

需要 root，支持 amd64 / arm64，Debian / Ubuntu / CentOS / Rocky 等带 systemd 的系统。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/acc66/warp-ai-unlock/main/warp-ai.sh) install
```

脚本依次执行：

1. 安装 curl、tar
2. 下载 wgcf、wireproxy 到 `/usr/local/bin`
3. 注册一个免费 WARP 账户（保存在 `/etc/warp-ai/`）
4. 创建并启动 systemd 服务 `warp-ai`
5. 自检 WARP 连通性并跑一次 AI 解锁检测
6. 打印面板要填的 JSON

看到这行说明 WARP 通了：

```
WARP 正常: ip=2a09:bac5:... loc=US warp=on
```

可选参数：

| 变量 | 说明 | 默认 |
|------|------|------|
| `SOCKS_PORT` | 本地 SOCKS5 端口，和其他程序冲突时修改 | `40000` |
| `WARP_KEY` | WARP+ license key，留空则使用免费版 | 空 |

```bash
SOCKS_PORT=40001 WARP_KEY=xxxxxxxx-xxxxxxxx-xxxxxxxx bash <(curl -fsSL https://raw.githubusercontent.com/acc66/warp-ai-unlock/main/warp-ai.sh) install
```

改了端口的话，后面后端配置里的 `40000` 也要一起改。

> WARP 必须和后端（xboard-node / soga）装在**同一台机器**上，后端是通过 `127.0.0.1` 连 WARP 的。

---

## 3A. 配置后端：XboardNode-Plus + wp2 面板

### 第 1 步：确认内核类型

在节点上运行：

```bash
grep -A2 'kernel:' /etc/XboardNode-Plus/config.yml
```

`type: "singbox"` 或者没有这一段，用的就是 sing-box（默认）；`type: "xray"` 是 Xray。两个内核的出站写法不一样，不能填错。

### 第 2 步：填写面板

wp2 后台 → 节点列表 → 找到节点，点 **编辑** → 往下拉，有两个框：

#### 框一：自定义出站（JSON）

**sing-box 内核**填这个：

```json
[
  {
    "tag": "warp",
    "protocol": "socks",
    "settings": {"server": "127.0.0.1", "server_port": 40000, "version": "5"}
  }
]
```

**Xray 内核**填这个：

```json
[
  {
    "tag": "warp",
    "protocol": "socks",
    "settings": {"servers": [{"address": "127.0.0.1", "port": 40000}]}
  }
]
```

只填一个，不要两段都粘进去。

#### 框二：自定义路由规则（JSON）

两个内核通用：

```json
[
  {
    "name": "ai-warp",
    "match": {
      "domain_suffixes": [
        "openai.com", "chatgpt.com", "oaistatic.com", "oaiusercontent.com", "sora.com",
        "anthropic.com", "claude.ai", "claude.com",
        "gemini.google.com", "bard.google.com", "aistudio.google.com",
        "generativelanguage.googleapis.com", "alkalimakersuite-pa.clients6.google.com",
        "makersuite.google.com", "notebooklm.google.com", "deepmind.google",
        "perplexity.ai", "x.ai", "grok.com", "copilot.microsoft.com", "meta.ai"
      ]
    },
    "action": {"type": "route", "target": "warp"}
  }
]
```

### 第 3 步：保存，等待生效

点保存。节点每 60 秒向面板拉一次配置，等一分钟左右就会生效，不用手动重启。

查看节点日志确认没有报错：

```bash
journalctl -u xboard-node -n 30 --no-pager
```

### 注意事项

- 两个框**都必须是 `[ ]` 包起来的数组**。
- 框一里每一项都要有 `"tag"`；框二的 `"target"` 要和框一的 `"tag"` 一模一样（都是 `warp`）。
- **两个框千万别填反**。路由规则填进了出站框，节点会起不来，并一直重启，日志里会出现：
  ```
  validate custom outbounds: custom_outbounds[0].tag is required
  ```
  遇到这种情况，先把两个框都清空保存，节点就能恢复，然后再按上面的内容重新填。
- 面板只检查 JSON 格式对不对，不检查内容，保存成功不代表配置正确，以节点日志为准。
- 想把其他服务（比如 Netflix）也走 WARP，往 `domain_suffixes` 里加域名就行。

### 已覆盖的服务

| 服务 | 域名 |
|------|------|
| ChatGPT / Sora | `openai.com` `chatgpt.com` `oaistatic.com` `oaiusercontent.com` `sora.com` |
| Claude | `anthropic.com` `claude.ai` `claude.com` |
| Gemini / AI Studio / NotebookLM | `gemini.google.com` `bard.google.com` `aistudio.google.com` `makersuite.google.com` `notebooklm.google.com` `generativelanguage.googleapis.com` 等 |
| Meta AI（Muse） | `meta.ai` |
| Grok | `x.ai` `grok.com` |
| Perplexity | `perplexity.ai` |
| Copilot | `copilot.microsoft.com` |

规则是后缀匹配，`meta.ai` 会把 `www.meta.ai` 等所有子域名一起覆盖。Meta AI 登录时会跳到 facebook.com / instagram.com，这两个域名不用加，加了反而会让整个 Facebook / Instagram 都走 WARP。

忘了怎么填的话，在节点上运行 `warp-ai panel`，会重新打印这几段。

---

## 3B. 配置后端：soga

soga 的路由不走面板下发，直接改节点上的 `/etc/soga/routes.toml`。

### 第 1 步：备份

```bash
cp /etc/soga/routes.toml /etc/soga/routes.toml.bak
```

### 第 2 步：编辑 routes.toml

```bash
nano /etc/soga/routes.toml
```

soga 从上往下匹配，**第一条命中的规则生效**。所以 WARP 规则要放在前面，`rules=["*"]` 兜底直连放在最后。

完整示例：

```toml
enable=true

# ========== AI 走 WARP ==========
[[routes]]
rules=[
	# OpenAI / ChatGPT
	"domain:openai.com",
	"domain:chatgpt.com",
	"domain:oaistatic.com",
	"domain:oaiusercontent.com",
	"domain:sora.com",

	# Claude
	"domain:anthropic.com",
	"domain:claude.ai",
	"domain:claude.com",

	# Google Gemini / AI Studio
	"domain:gemini.google.com",
	"domain:bard.google.com",
	"domain:ai.google.dev",
	"domain:aistudio.google.com",
	"domain:makersuite.google.com",
	"domain:notebooklm.google.com",
	"domain:generativeai.google",
	"domain:deepmind.com",
	"domain:deepmind.google",
	"domain:generativelanguage.googleapis.com",
	"domain:proactivebackend-pa.googleapis.com",
	"domain:aisandbox-pa.googleapis.com",
	"domain:alkalimakersuite-pa.clients6.google.com",
	"domain:alkalicore-pa.clients6.google.com",
	"domain:waa-pa.clients6.google.com",
	"domain:robinfrontend-pa.googleapis.com",

	# Meta AI（Muse）
	"domain:meta.ai",

	# 其他
	"domain:perplexity.ai",
	"domain:x.ai",
	"domain:grok.com"
]

[[routes.Outs]]
listen=""          # 出口网卡 ip，不配置则由系统决定
type="socks"
server="127.0.0.1"
port=40000
username=""
password=""

# ========== 你原有的其他规则（中转等）放这里 ==========

# ========== 兜底直连，必须放最后 ==========
[[routes]]
rules=["*"]
[[routes.Outs]]
type="direct"
```

### 第 3 步：重启 soga

```bash
soga restart
soga log    # 看有没有报错
```

### 注意事项

- 同一个域名只能出现在一条规则里。原来已经有走别的中转的 Gemini / ChatGPT 规则的话，要么删掉旧的，要么从 WARP 段里删掉，不然只有写在前面的那条生效。
- 改坏了用备份恢复：`cp /etc/soga/routes.toml.bak /etc/soga/routes.toml && soga restart`。

---
## 4. 验证

**节点上：**

```bash
warp-ai check
```

WARP 列都是 `Yes`，说明 WARP 出口可以解锁。

**客户端上：**

连上这个节点，打开 [chatgpt.com](https://chatgpt.com)、[claude.ai](https://claude.ai)、[gemini.google.com](https://gemini.google.com)，能正常打开、不提示地区不支持就成功了。

想确认 AI 流量真的走了 WARP，可以打开 `https://chatgpt.com/cdn-cgi/trace`，看到 `warp=on` 或 `warp=plus` 就对了。再打开 `https://www.cloudflare.com/cdn-cgi/trace` 对比一下：这个域名不在规则里，应该显示 `warp=off`，出口是节点自己的 IP。

---

## 5. WARP+ 与流量

| | 免费 WARP | WARP+ |
|---|---|---|
| 流量 | 不限 | 不限 |
| 速度 | 看线路，高峰期可能慢 | Argo 智能路由，更快更稳 |
| 解锁 AI | ✅ | ✅ |
| 价格 | 免费 | 按地区定价，以 App 内显示为准 |

**能不能解锁 AI，看的是出口 IP 所在地区，和速度无关，所以免费版就够用。** WARP+ 只是让速度更快、线路更稳。

早年邀请好友送的 "WARP+ 流量" 是加速额度，用完会回到免费 WARP，网络不会断。

### 开通 WARP+

1. 手机装 Cloudflare 的 **1.1.1.1** App（App Store / Google Play）
2. App 里订阅 **WARP+**
3. 菜单 → 账户 → **按键**，复制 license key（格式：`xxxxxxxx-xxxxxxxx-xxxxxxxx`）

注意：Cloudflare 网站的 Pro / Business 套餐、Zero Trust 都和 WARP+ 是不同的产品，没有这种 key。

### 绑定 key

已经装好的节点不用重装：

```bash
warp-ai key xxxxxxxx-xxxxxxxx-xxxxxxxx
```

也可以运行 `warp-ai` 进菜单，选 5。

看到 `WARP+ 已生效（Account type: unlimited）` 就成功了。一个 key 最多绑 5 台设备（手机也算一台）。绑定失败（key 无效或已绑满）时会自动退回原来的账户，不会断网。

手动确认：

```bash
cd /etc/warp-ai && wgcf status
```

`Account type` 显示 `unlimited` 或 `limited` 就说明 WARP+ 生效了。

> 用 wgcf 连接时，trace 页面经常一直显示 `warp=on` 而不是 `warp=plus`，这是正常的，判断有没有生效以 `Account type` 为准。

---

## 6. 管理命令

安装完成后，系统里会多一个 `warp-ai` 命令：

```bash
warp-ai               # 交互菜单
warp-ai install       # 安装 / 重装
warp-ai check         # AI 解锁检测（直连 vs WARP）
warp-ai key <key>     # 绑定 / 更换 WARP+ key
warp-ai status        # 服务状态 + WARP 连通性
warp-ai panel         # 重新打印面板 JSON
warp-ai version       # 查看当前版本和最新版本
warp-ai update        # 在线升级
warp-ai uninstall     # 卸载

systemctl restart warp-ai  # 重启 WARP
journalctl -u warp-ai -f   # 实时日志
```

### 在线升级

```bash
warp-ai update
```

会做这几件事：

1. 从 GitHub 下载最新脚本，先检查语法，没问题才替换（下载失败或文件损坏时保留旧版本）
2. 把 wgcf、wireproxy 更新到最新 release
3. 重启 `warp-ai` 服务，自检 WARP 连通性

WARP 账户、已绑定的 key、端口配置都不会动，升级不会换出口 IP。

版本号没变也想重新拉一遍：`warp-ai update -f`。

**v1.1.0 之前装的节点**还没有 `warp-ai` 命令，先运行一次：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/acc66/warp-ai-unlock/main/warp-ai.sh) update
```

以后就能直接用 `warp-ai` 了。

文件位置：

| 路径 | 内容 |
|------|------|
| `/etc/warp-ai/wgcf-account.toml` | WARP 账户（含私钥，不要外泄） |
| `/etc/warp-ai/wgcf-profile.conf` | WireGuard 配置 |
| `/etc/warp-ai/wireproxy.conf` | SOCKS5 监听配置 |
| `/etc/systemd/system/warp-ai.service` | systemd 服务 |

---

## 7. 常见问题

**注册失败**

Cloudflare 限制了注册接口的频率，过几分钟再试。

**`WARP 未连通`**

运行 `journalctl -u warp-ai -n 50` 看日志。常见原因是机器的 UDP 2408 端口出站被封（有些云厂商的安全组默认会拦），去安全组里放行 UDP 出站。

**节点日志报 `custom_outbounds[0].tag is required`，节点一直重启**

面板里两个框填反了，或者出站框里混进了路由规则。按 [3A 注意事项](#注意事项) 处理。

**Direct 列 Gemini 显示 `No (CHN)`，ChatGPT 却是 `Yes (US)`**

Google 的 IP 库把你的机器判成了中国。按上面配好路由后，Gemini 会走 WARP，就能正常用。

**WARP 列也是 No，或者用着用着被风控**

WARP 出口 IP 是很多人共用的，偶尔会被 AI 网站限制。重新注册就能换一个 IP：

```bash
warp-ai uninstall && warp-ai install
```

注意：重新注册会生成新账户，之前绑的 WARP+ key 要重新绑定。

**规则不生效，AI 还是走直连**

- XboardNode-Plus：确认两个框都保存了，`target` 和 `tag` 一致，节点日志没有报错
- soga：确认 WARP 规则在 `rules=["*"]` 前面，并且已经 `soga restart`
- 路由按域名匹配，客户端要以域名的形式发请求（默认都是这样）。如果客户端在本地先解析成 IP 再连，规则匹配不到

**日志报 `sendmmsg: network is unreachable`，握手一直重试**

endpoint 的 IP 协议选错了，比如机器没有 IPv6，却连到了 IPv6 endpoint。重新运行 install 即可，账户和已绑定的 key 都会保留，脚本会按路由表重新选择：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/acc66/warp-ai-unlock/main/warp-ai.sh) install
```

自动选得不对的话，可以手动指定：

```bash
WARP_ENDPOINT=162.159.192.1:2408 warp-ai install              # 走 IPv4
WARP_ENDPOINT=[2606:4700:d0::a29f:c001]:2408 warp-ai install  # 走 IPv6
```

握手正常但连不上时，2408 端口可能被封，可以换 500、1701、4500 这几个端口试试。

**纯 IPv6 机器**

脚本会自动改用 WARP 的 IPv6 endpoint，不用额外设置。

---

## 安全说明

- SOCKS5 只监听 `127.0.0.1`，不需要认证，外部访问不到。**不要改成 `0.0.0.0`**，否则会变成公开代理。
- wireproxy 以 systemd 的 `DynamicUser` 运行，没有 root 权限。
- `/etc/warp-ai/wgcf-account.toml` 里有 WARP 私钥和 license key，不要外传。

## 致谢

- [ViRb3/wgcf](https://github.com/ViRb3/wgcf)
- [whyvl/wireproxy](https://github.com/whyvl/wireproxy)
- 检测思路参考 [1-stream/RegionRestrictionCheck](https://github.com/1-stream/RegionRestrictionCheck)
