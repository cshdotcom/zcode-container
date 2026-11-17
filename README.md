# ZCode Cloudflare Tunnel + 内网双通道 —— 无敏感信息部署示例

这是 [zcode-container](https://github.com/cshdotcom/zcode-container) 的**零私密数据**部署示例分支（`deploy-example`）：
不含任何隧道凭据、私钥、真实 token / 密码。按下面步骤替换占位符即可部署你自己的实例。

## 架构

```
                     ┌── Cloudflare Tunnel（公网唯一入口，源 IP 零端口）
公网用户 ──────────→  │   zcode.* / desktop.* / preview.* / preview2.*（8 条 proxied DNS）
                     │
                     ├── zcode 容器（3030 网页端 / 7183 桌面 / 8080+8090 AI 动态服务）
                     │
                     ├── nginx 网关（80 静态预览 / 81,82 动态优先+静态兜底 / 47184 内网 HTTPS 桌面）
                     │
内网/VPN 用户 ─────→  └── 高位端口直连：43030 / 47183 / 47184 / 40881-40883 / 40808-40809
```

**预览位逻辑（动态优先、静态兜底）**：AI 在容器内起了 dev server（8080/8090）→ nginx 自动转发；
没起（502）→ 自动回落 `workspace/preview/`（或 `preview2/`）静态目录。同一入口两用。

**桌面三入口**：公网 `https://desktop.<域名>`（Cloudflare TLS）；内网 `http://<IP>:47183`；
内网 HTTPS `https://<IP>:47184`（自签证书）。

## 三步初始化（把占位符换成你自己的值）

### 第 1 步：Cloudflare 侧（API 一把梭）

```bash
EMAIL="你的CF账号邮箱"
KEY="你的Global API Key"          # dash.cloudflare.com -> My Profile -> API Tokens -> Global API Key
ZONE_NAME="你的域名.com"

# 取 zone id / account id
ZONE_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME" \
  -H "X-Auth-Email: $EMAIL" -H "X-Auth-Key: $KEY" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"][0]["id"])')
ACCT_ID=$(curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID" \
  -H "X-Auth-Email: $EMAIL" -H "X-Auth-Key: $KEY" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["account"]["id"])')

# 建隧道（本地管理模式）+ 随机 secret
SECRET=$(openssl rand -base64 32)
TUNNEL_ID=$(curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCT_ID/cfd_tunnel" \
  -H "X-Auth-Email: $EMAIL" -H "X-Auth-Key: $KEY" -H "Content-Type: application/json" \
  -d "{\"name\":\"zcode-container\",\"tunnel_secret\":\"$SECRET\",\"config_src\":\"local\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["id"])')

# 配 8 条 DNS（proxied CNAME -> <tunnel_id>.cfargovm.net）
for H in zcode desktop preview preview2; do
  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
    -H "X-Auth-Email: $EMAIL" -H "X-Auth-Key: $KEY" -H "Content-Type: application/json" \
    -d "{\"type\":\"CNAME\",\"name\":\"$H.$ZONE_NAME\",\"content\":\"$TUNNEL_ID.cfargovm.net\",\"proxied\":true}"
done
```

### 第 2 步：替换占位符

```bash
git clone -b deploy-example https://github.com/cshdotcom/zcode-container.git zcode-tunnel-kit
cd zcode-tunnel-kit

# 1) tunnel-credentials.json：填入上面的 ACCOUNT / TUNNEL_ID / SECRET
# 2) config/config.yml：tunnel: 行的 ID、8 个 hostname 换成你的域名
# 3) .env：凭据换随机值
ZCODE_WEB_TOKEN=$(openssl rand -hex 10)
DESKTOP_AUTH_USER=任意用户名
DESKTOP_AUTH_PASSWORD=$(openssl rand -hex 10)

# 4) 自签内网 HTTPS 证书（见 config/certs/README.md）
bash config/certs/README.md 里的一行 openssl 命令（按你的域名改 SAN）
```

### 第 3 步：起

```bash
cp .env.example .env      # 先把上面替换好的值放进 .env
docker compose up -d
docker compose logs -f cloudflared   # 出现 4x Registered tunnel connection 即通
```

## 内网/VPN 直连端口（全部高位，避开常用端口号）

| 宿主端口 | 容器内 | 用途 |
|---|---|---|
| 43030 | 3030 | ZCode 网页端（`http://IP:43030/?token=...`） |
| 47183 | 7183 | 远程桌面 HTTP |
| 47184 | 47184 | 远程桌面 HTTPS（自签） |
| 40881 | 80 | 纯静态预览 |
| 40882 | 81 | 动态优先(8080)+静态兜底 = preview 域名 |
| 40883 | 82 | 动态优先(8090)+静态兜底 = preview2 域名 |
| 40808 | 8080 | AI 动态服务 1 直连 |
| 40809 | 8090 | AI 动态服务 2 直连 |

`.env` 的 `EXT_BIND_ADDR` 填 VPN 网卡 IP（如 Tailscale 100.x.x.x）→ 端口仅 VPN 内可达，公网网卡零端口。

## AI 在容器内的使用约定

- 静态预览：产物写 `/workspace/preview/`（→ preview 域名 / 40882 兜底）
- 动态预览：起 dev server 监听 `0.0.0.0:8080`（→ preview 域名 / 40882 / 40808）或 `:8090`（→ preview2 域名 / 40883 / 40809）

## 安全边界

1. Cloudflare 边缘 proxied（隐藏源 IP，TLS 边缘终结）
2. ZCode URL token + 桌面 Basic Auth（公网/内网均生效）
3. 公网网卡可零端口；内网仅高位非常用端口

## 主仓库

镜像、构建、冒烟测试见 [main 分支 README](https://github.com/cshdotcom/zcode-container/blob/main/README.md)。
镜像：`docker pull ghcr.io/cshdotcom/zcode-container:1.0.0`（国内加速：华为 SWR 源，见主 README）。
