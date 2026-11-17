# ZCode Cloudflare Tunnel + 内网双通道 部署示例（占位版）

> 本分支是**脱敏后的部署示例**：域名 / 路径 / 凭据全部为占位符，对照改成自己的值即可。
> 容器镜像与完整说明见 main 分支 README 与 GHCR 镜像 `ghcr.io/cshdotcom/zcode-container`。

## 接线总览（8 条路由，双域名同理）

| 公网域名 | 隧道源 | 说明 |
|---|---|---|
| `zcode.example-a.com` | `http://zcode:3030` | ZCode 网页端（URL token） |
| `desktop.example-a.com` | `http://preview:83` | Selkies 桌面（经 nginx 网关，CF 真实 IP 还原） |
| `preview.example-a.com` | `http://preview:81` | 动态优先 :8080 + 静态兑底 |
| `preview2.example-a.com` | `http://preview:82` | 动态优先 :8090 + 静态兑底 |

桌面三入口（同一会话）：desktop 域名（CF 边缘 TLS）/ 内网 `http://IP:47183`（明文）/ 内网 `https://IP:47184`（nginx 自签 TLS，安全上下文）。**Selkies 本体恒为 HTTP(:7183)，TLS 全部由网关 nginx 终止**——隧道源保持明文 http，绝不 502。

## 三步初始化

1. **建隧道与域名**：Cloudflare Zero Trust 建隧道（TunnelID / TunnelSecret / AccountTag 填入 `config/tunnel-credentials.json` 占位符）；DNS 加 4×2 条 proxied CNAME 指向 `<TunnelID>.cfargotunnel.com`；把 `config/config.yml` 与 `config/nginx-*.conf` 里的 `example-a.com` / `example-b.com` 换成你的域名
2. **生成自签证书**（内网 https://IP:47184 用）：见 `config/certs/README.md`——不生成则 nginx 容器起不来
3. **填 .env 并启动**：`cp .env.example .env`，替换 REPLACE_WITH_* 凭据；`docker compose up -d`；健康检查通过后把 `ZCODE-AI-PROMPT.md` 贴进 ZCode 个性化提示词

## 内网/VPN 直连端口（全部高位，宿主不开 443）

| 宿主端口 | 容器内 | 用途 |
|---|---|---|
| 43030 | 3030 | ZCode 网页端 |
| 47183 | 7183 | 桌面 HTTP 明文（直连 Selkies） |
| 47184 | 443 | 桌面 HTTPS（nginx 自签 TLS -> zcode:7183） |
| 40881 / 40882 / 40883 | 80 / 81 / 82 | 纯静态 / 动态优先1 / 动态优先2 预览 |
| 40808 / 40809 | 8080 / 8090 | AI 动态服务直连（不经 nginx） |

`EXT_BIND_ADDR` 可绑定 VPN 网卡 IP（公网网卡零端口）；数据根目录 `ZCODE_BASE_DIR` 默认 `/srv/zcode`。

## 日常操作

```bash
docker compose ps && docker compose logs -f cloudflared
docker exec -it zcode-container desktop-on.sh   # 开桌面（三入口同会话）
docker exec -it zcode-container desktop-status.sh
docker exec -it zcode-container desktop-off.sh
```
