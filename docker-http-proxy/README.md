# Docker 多 WARP HTTP 代理

同一台 A 服务器部署 5 组独立的 WARP + HTTP 代理，公网端口 40001–40005。每个实例独立注册和保存 WARP 配置，全部 HTTP 代理共用 .env 账号密码。WARP 断开时不配置直连回退。

## 一键安装或升级

需预先安装 Docker Engine、Compose v2、git、curl、openssl。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/acc66/warp-ai-unlock/main/docker-http-proxy/install.sh)
```

升级时保留原 40001 使用的 docker-http-proxy_warp-config 卷，并替换旧单实例容器；升级会有短暂中断。建议先备份 .env 和卷数据。

## 管理

```bash
cd /opt/warp-http-proxy/docker-http-proxy
bash manage.sh status
bash manage.sh check
bash manage.sh list 35.197.137.58
bash manage.sh logs 2
bash manage.sh restart 2
bash manage.sh stop
bash manage.sh start
```

check 会逐一检测 WARP 出口、地区并标记重复 IP。Cloudflare 不保证每个独立 WARP 实例获得不同出口 IP。list 会输出包含密码的代理地址，注意保密。

## 远程测试

```bash
curl -x http://A服务器公网IP:40002 -U '用户名:密码' https://www.cloudflare.com/cdn-cgi/trace
```

期望返回 warp=on 或 warp=plus。只允许可信客户端来源 IP 访问 TCP 40001–40005。HTTP Basic 认证不加密凭据；请避免在不可信网络直接使用。生产使用前还应验证 WARP 断线不回退及 Docker 重启恢复。
