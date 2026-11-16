# zcode-container —— 自托管 AI 工作容器

[![build](https://github.com/cshdotcom/zcode-container/actions/workflows/build.yml/badge.svg)](https://github.com/cshdotcom/zcode-container/actions/workflows/build.yml)

一个开箱即用的自托管 AI 工作容器：**ZCode 网页版（源码构建）+ Selkies 远程桌面 + Edge 浏览器自动化 + 办公/编程环境**。用户在外网通过内网穿透访问，全部 Web 交互走浏览器。

上游组件全部按官方仓库方式接入（禁止闭门造车）：

| 组件 | 上游 | 接入方式 |
| --- | --- | --- |
| ZCode | https://github.com/zai-org/ZCode | `git clone`（固定 tag `v3.18.2`）→ Node.js 24.14.0 + pnpm 10.33.2（与上游 `mise.toml`/`Dockerfile.desktop-e2e` 一致）→ `pnpm install`（上游 e2e 容器同款 frozen-lockfile）→ `pnpm bootstrap` → `pnpm build:sea:prepare`（上游脚本报错信息指定的 SEA 前置）→ `pnpm build:zcode`，解包运行 `zcode --web` |
| Selkies | https://github.com/selkies-project/selkies | 官方 `.deb`（`2.2.1`，sha256 校验），`selkies session` 接入，参数与官方 coder 插件一致 |
| edge-mcp | https://github.com/hualang-C/edge-mcp | 源码固定 commit + `npm install`，HTTP 模式常驻 `:7123` |
| sing-box | https://github.com/SagerNet/sing-box | 官方二进制 `1.14.4`（sha256 校验）→ `/usr/local/bin/sing-box`，默认不启动 |

不预装任何未要求的周边服务：没有白板（Excalidraw/drawio）、没有 code-server、没有 Jupyter、没有任何协作 Web 应用。多人协作用容器内自带的 `tmux` 共享会话。

---

## 一、端口规划（四个端口，1:1 落实）

| 端口 | 容器内 | 对外映射默认值 | 用途 | 状态 |
| --- | --- | --- | --- | --- |
| ① | `3030` | `EXT_ZCODE_PORT=43030` | 网页端主入口：ZCode 网页版 | 预置服务（常驻） |
| ② | `7183` | `EXT_SELKIES_PORT=47183` | 远程控制：Selkies 远程桌面（同时远程模式，多人同端口连入） | 预置服务（默认关闭，`desktop-on`/`desktop-off` 按需启停） |
| ③ | `8080` | `EXT_SPARE_PORT_1=40808` | 空端口，纯备用 | 不跑任何服务 |
| ④ | `8090` | `EXT_SPARE_PORT_2=40809` | 空端口，纯备用 | 不跑任何服务 |

**对外映射规则**：上表左侧为容器内部端口（不变）；映射到宿主机/外网的对外端口一律避开常用端口号（80 / 443 / 3000 / 8080 / 8888 等常被扫描的），统一用不常见的高位端口，**集中定义在 `.env`**，可自行修改。所有端口在容器层完整开放：Dockerfile `EXPOSE` + `docker run -p`/compose 显式映射 + 内网防火墙放行（见「内网穿透」章节的 `ufw` 示例）。

容器内部还有两个**仅容器内使用、不对外映射**的端口：Edge CDP `127.0.0.1:9222`（浏览器自动化）与 edge-mcp `0.0.0.0:7123`（ZCode 通过 MCP 结构化调用操控浏览器）。端口映射总数恒为四个。

**关于 ③④ 空端口的明确说明**：

- 空端口就是空端口：不绑定、不预装、不安排任何具体服务，也不承担“静态预览/应用直连”之类的用途；
- 但必须完整开放：`EXPOSE`、`-p` 映射、内网放行一样不少——这是用户外网访问扩展服务的唯一通道；
- **此端口为 AI 自主使用预留，随时可能被容器内 AI 起服务占用，属正常现象。**

**Selkies 多用户同时远程**：不开新端口。`desktop-on` 开启会话后，多个用户同时连入同一端口 7183 即可同时远程——利用 Selkies 原生多观众能力。所有人看同一个桌面、都能操作（输入共享，会互相抢鼠标），适合演示、协作、AI 干活时多人在旁边看。

---

## 二、快速开始

```bash
git clone https://github.com/cshdotcom/zcode-container.git
cd zcode-container

# 1. 准备环境变量（对外端口集中在 .env 定义）
cp .env.example .env

# 2. 启动（首次会从 GHCR 拉取 CI 构建好的镜像）
docker compose up -d

# 3. 查看状态 / 日志
docker compose ps
docker compose logs -f zcode

# 4. 逐端口验证（宿主机上）
bash scripts/verify-ports.sh
```

启动后访问 `http://<宿主机IP>:43030` 打开 ZCode 网页端（可对话）。

开启远程桌面（默认关闭）：

```bash
docker exec -it zcode-container desktop-on     # 开启 Selkies 会话
docker exec -it zcode-container desktop-status # 查看状态 / 空闲秒数
docker exec -it zcode-container desktop-off    # 停止并释放
```

开启后访问 `http://<宿主机IP>:47183` 即可看到远程桌面。**多人同时远程**：让其他人用浏览器打开同一地址即可，所有人在同一桌面、输入共享。

> 容器内的服务管理脚本统一安装在 `/usr/local/bin/`：`desktop-on` / `desktop-off` / `desktop-status` / `proxy-on` / `proxy-off` / `mcp-register-edge` / `healthcheck`。

---

## 三、目录与持久化（挂载卷）

| 路径 | 用途 |
| --- | --- |
| `/workspace/` | 工作区（含 `preview/` 子目录：AI 静态产出） |
| `/root/.zcode/` | ZCode 配置 + 插件数据 + MCP 配置（`cli/config.json`，**必须持久化，重启不丢**） |
| `/data/edge-profile/` | Edge 浏览器 Profile（用户数据目录） |
| `/etc/sing-box/` | sing-box 代理配置（**用户自备，默认空 = 直连**） |
| `/data/extra1` ~ `/data/extra3` | 通用预留挂载点：想持久化任何自定义路径就挂这里，容器不限制 |

compose 中已声明以上卷；`docker run` 用户请按 `docker-compose.yml` 中的 `volumes` 自行 `-v` 挂载。

---

## 四、CI 编译流水线与 GHCR 拉取

`.github/workflows/build.yml` 支持三种触发：**push 到 main、打 tag（`v*`）、手动触发（workflow_dispatch）**。

- CI 跑**默认直连路径**（`USE_CN_MIRROR=0`，境外网络本来就直连）；国内加速路径不进 CI，只在本文「构建加速开关」章节说明本地用法。
- 构建成功后推送 GHCR：`ghcr.io/cshdotcom/zcode-container`，tag 策略为 `latest`（main）+ 版本号（tag）。
- 除镜像外，workflow 同时构建并上传 **ZCode 源码构建产物**（CLI 发行包 `zcode-<version>.tar.gz`、`sha256.txt`、`latest.json`、`install.sh`）为 Artifact，不拉镜像也能直接取用。
- 任一步骤失败 workflow 显式变红（冒烟测试失败则不推送镜像）。

手动从 GHCR 拉取镜像：

```bash
# 公共镜像直接拉取
docker pull ghcr.io/cshdotcom/zcode-container:latest
docker pull ghcr.io/cshdotcom/zcode-container:1.0.0

# 若包为私有（首次推送默认可能为私有），先登录：
echo <你的GitHub PAT> | docker login ghcr.io -u <你的用户名> --password-stdin
docker pull ghcr.io/cshdotcom/zcode-container:latest
```

CLI 发行包（Artifact）用法：

```bash
# 从 Actions 页面下载 zcode-cli-dist 后：
tar -xzf zcode-<version>.tar.gz
node zcode/bin/zcode.mjs --web --workspace "$PWD" --port 3030 --no-open
```

---

## 五、本地构建与构建加速开关（国内 / 境外两用）

默认构建（境外 CI / 直连网络，**不改写任何源**）：

```bash
docker build -t zcode-container:local .
```

国内本地构建加速（可选，默认关闭）：

```bash
docker build --build-arg USE_CN_MIRROR=1 -t zcode-container:local .
```

`USE_CN_MIRROR=1` 时启用（全部只存在于**构建阶段**）：

- GitHub 下载走镜像前缀（ZCode clone / selkies .deb / sing-box / edge-mcp），默认 `https://ghfast.space/`
- npm registry → `registry.npmmirror.com`；Electron 下载 → `npmmirror.com/mirrors/electron/`
- pip → 清华 TUNA 源；apt → aliyun 源；Node 发行包 → `npmmirror.com/mirrors/node`

**加速源不绑定单一 ghfast.space，失败可替换**：

```bash
# 换成 gh-proxy.com 或 ghproxy.net：
docker build --build-arg USE_CN_MIRROR=1 \
    --build-arg GH_PROXY=https://gh-proxy.com/ \
    -t zcode-container:local .
# 加速源挂了不影响默认直连路径：不传 USE_CN_MIRROR 时所有下载走官方源。
```

**环境兼容保证**：

- 构建机自身可能走全局代理（如 sing-box TUN 模式），直连 GitHub 本来就通——所以默认值是“不改写”，镜像改写反而多余甚至有害；
- 加速只允许存在于构建阶段：多阶段构建 + 单 RUN 内还原（apt 源用后即还原、registry 用 CLI 参数不落盘、edge-mcp 的 git remote 还原为官方地址）；
- 最终镜像内的 git / pip / npm 必须是直连配置——CI 冒烟测试里有专门断言：`git config --global -l` 为空、`npm config get registry` 为官方源、`pip3 config list` 为空。容器内 AI 以后自己 clone 仓库不会被构建期的加速源劫持。

---

## 六、Selkies 远程桌面：用法与排查

接入方式与官方仓库一致（`selkies session --port=7183 --enable-basic-auth=false --enable-https=false --session=openbox`），`SELKIES_ENABLE_HTTPS=false`（加密由用户穿透层负责）。

- **启停**：`desktop-on` / `desktop-off` / `desktop-status`，默认关闭；
- **多人同时远程**：所有浏览器连入同一对外端口（默认 47183）——同屏同桌面、输入共享；不开任何多余端口；
- **空闲自动回收**：会话 15 分钟（`SELKIES_IDLE_TIMEOUT=900`，可改）无操作自动 `desktop-off` 释放资源；置 0 关闭；
- **白名单清理**：`desktop-off` 只清理自己拉起的会话进程组（Xvfb / Selkies / openbox 都在该进程组内），不误杀常驻 Xvfb :99 与其他系统服务。

### WebRTC(UDP) 与防火墙排查

当前 Selkies 默认以 **WebSockets（TCP）** 传输，穿透/公网环境最稳；WebRTC 为可选传输（内网 / VPN 环境体验最佳）。两种模式：

- 默认 `SELKIES_MODE=websockets` + `SELKIES_ENABLE_DUAL_MODE=true`（官方默认组合）；
- 追求 WebRTC 低延迟时在 `.env` 设 `SELKIES_MODE=webrtc`。

**公网防火墙掐 UDP 导致黑屏的排查路径**：

1. 确认网页端本身可达（HTTP 200）而画面黑屏 → 大概率是 WebRTC 的 UDP 媒体通道被掐；
2. `docker exec -it zcode-container desktop-status` 查看会话健康与 `/api/health`；
3. 换回 `SELKIES_MODE=websockets`（走 TCP，穿透友好）验证画面恢复 → 即可确认是 UDP 问题；
4. 必须走 WebRTC 时配置 TURN 中继（容器已预装 coturn 组件与相关配置项）：

```bash
# .env 中设置（指向自建 TURN 或云 TURN 服务）
SELKIES_TURN_HOST=turn.example.com
SELKIES_TURN_PORT=3478
SELKIES_TURN_USERNAME=<用户名>
SELKIES_TURN_PASSWORD=<密码>
# 或共享密钥方式（REST 认证）
# SELKIES_TURN_SHARED_SECRET=<secret>
```

> 内网 / VPN 环境 WebRTC 体验最佳；公网链路优先用默认 WebSockets 模式。

---

## 七、sing-box 代理与 proxy-on / proxy-off

- sing-box 二进制位于 `/usr/local/bin/sing-box`（官方 1.14.4），配置目录 **`/etc/sing-box`（挂 Volume，用户自备，默认无配置 = 直连，进程默认不启动）**；
- `proxy-on`：启动 sing-box，并把代理环境变量（`HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`；`NO_PROXY` 覆盖内网地址与国内常用域名）**只写入 `/etc/profile.d/proxy-env.sh`**，仅对之后新开的用户 shell 生效；
- `proxy-off`：停进程 + 删环境文件 + 清理 bashrc 守卫块，清理干净。

```bash
# 1) 先放置自己的 sing-box 配置（示例：本机 2080 混合入站 + direct 出站）
docker exec -it zcode-container sh -c 'cat > /etc/sing-box/config.json <<EOF
{
  "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": 2080}],
  "outbounds": [{"type": "direct"}]
}
EOF'

# 2) 开启代理（无配置时 proxy-on 会拒绝启动并提示，默认即直连）
docker exec -it zcode-container proxy-on

# 3) 新开的用户 shell 走代理（注意：对已有 shell 无效）
docker exec -it zcode-container bash -l -c 'env | grep -i proxy'
curl -x http://127.0.0.1:2080 https://example.com

# 4) 关闭并彻底清理
docker exec -it zcode-container proxy-off
```

完整配置示例（分流/订阅节点等）参考 sing-box 官方文档：https://sing-box.sagernet.org/ 。sing-box 监听端口不是 2080 时，用 `SINGBOX_PROXY_ADDR` 覆盖代理地址。

### 代理与环境隔离（硬性要求）

容器内任何环境修改（代理、git 配置、环境变量等）都**不得影响 ZCode 自身**：

- 开了 sing-box 代理，`ZCode 自己的流量绝不走代理`：ZCode 进程由入口脚本在 `proxy-on` 之前启动，其进程环境永远不含代理变量；
- `proxy-on` 写入的 `/etc/profile.d/proxy-env.sh` 只影响**之后新开的用户 shell**，对已运行进程零影响；
- 隔离验证（两条都要测）：

```bash
# ① 新开 shell 有代理变量
docker exec -it zcode-container bash -l -c 'env | grep -i proxy'
# ② ZCode 进程环境无任何代理变量（输出应为空）
docker exec -it zcode-container sh -c \
  'tr "\0" "\n" < /proc/$(pgrep -f "zcode.mjs --web" | head -1)/environ | grep -i proxy'
```

> 另请避免在宿主机/穿透层对容器流量做全局 TUN 劫持；若必须使用 TUN 模式，请在 sing-box 配置中将 ZCode 相关流量（容器网段）排除。

---

## 八、Edge 浏览器自动化

- 预装 **Microsoft Edge**（官方 apt 仓库），常驻**无头模式**：`--headless --remote-debugging-port=9222`（CDP 控制，绑定 `127.0.0.1`）；
- **edge-mcp** 部署于 `:7123`（源码固定 commit，HTTP 常驻模式），ZCode 通过 MCP 结构化调用操控浏览器（16 个工具：navigate/click/type/screenshot 等）；
- 虚拟屏：**Xvfb :99 常驻**，供 Edge 有头模式 / 桌面应用兜底显示用（`DISPLAY=:99`）；
- Edge 用户数据目录持久化于 `/data/edge-profile`；
- ZCode 侧 MCP 注册：镜像内置种子配置 `/root/.zcode/cli/config.json`（指向 `http://127.0.0.1:7123/mcp`）；若挂载卷为空目录覆盖了种子，执行一次：

```bash
docker exec -it zcode-container mcp-register-edge
```

验证：

```bash
docker exec -it zcode-container curl -s http://127.0.0.1:9222/json/version  # CDP 可控
docker exec -it zcode-container curl -s http://127.0.0.1:7123/health        # {"ok":true,...}
```

---

## 九、办公与编程环境

- **办公**：LibreOffice（Writer/Calc/Impress，含中文界面包）+ pandoc + Python 办公库（`openpyxl` / `python-docx` / `pypdf`）；
- **编程**：Python 3 + Node.js 24.14.0（pnpm 10.33.2 经 corepack 可用）+ git + 常用编译链（build-essential）；
- **多人协作**：`tmux` 共享会话（不预装任何协作 Web 应用）：

```bash
# 会话创建者
docker exec -it zcode-container tmux new -s pair
# 其他用户接入同一会话（同屏协作）
docker exec -it zcode-container tmux attach -t pair
```

容器内还预置了 `jq` / `curl` / `zip` / `unzip` / 中文字体（Noto CJK）等常用工具与字体。

---

## 十、内网穿透配置示例

**ZCode 网页端（3030）的界面可以执行任意命令：禁止裸暴露公网**。请走内网穿透 / SSH 隧道访问，安全由穿透层负责（认证/加密在穿透层完成，容器内 `SELKIES_ENABLE_HTTPS=false`、ZCode 默认无令牌也基于此假设）。可选双保险：`.env` 设置 `ZCODE_WEB_TOKEN=<长随机串>` 后，访问形式为 `http://<host>:43030/?token=<令牌>`。

内网防火墙放行（ufw 示例，四个对外端口一个都不能少）：

```bash
sudo ufw allow 43030/tcp   # ZCode 网页端（仅对内网/穿透服务器网段开放更佳）
sudo ufw allow 47183/tcp   # Selkies 远程桌面
sudo ufw allow 40808/tcp   # 备用 1
sudo ufw allow 40809/tcp   # 备用 2
```

**方案 A：SSH 隧道（最简单，天然加密与认证）**

```bash
# 在外网机器上执行，把容器四端口经 SSH 转发到本机
ssh -N \
  -L 43030:127.0.0.1:43030 \
  -L 47183:127.0.0.1:47183 \
  -L 40808:127.0.0.1:40808 \
  -L 40809:127.0.0.1:40809 \
  user@<内网宿主机>
# 之后访问 http://127.0.0.1:43030 / http://127.0.0.1:47183
```

**方案 B：frp（有公网 VPS 时）**

```ini
# frpc.toml（容器外，宿主机上运行）
[[proxies]]
name = "zcode-web"
type = "tcp"
localPort = 43030
remotePort = 43030

[[proxies]]
name = "zcode-selkies"
type = "tcp"
localPort = 47183
remotePort = 47183

[[proxies]]
name = "zcode-spare1"
type = "tcp"
localPort = 40808
remotePort = 40808

[[proxies]]
name = "zcode-spare2"
type = "tcp"
localPort = 40809
remotePort = 40809
```

> 访问 `http://<VPS公网IP>:43030`。frp 服务端同样需要放行这四个高位端口。Tailscale/WireGuard 组网同理：把宿主机入网后直接访问其 43030/47183。

---

## 十一、安全

- ZCode 网页端（3030）的界面可以执行任意命令：**禁止裸暴露公网**；用户走内网穿透 / SSH 隧道访问，安全由穿透层负责（上节示例均已内置认证/加密）；
- 容器内服务一律绑定 `0.0.0.0`（供映射），不额外开公网；容器内服务之间的内部端口（9222/7123）不对宿主机映射；
- 建议穿透层再加一层：frp 的 `stcp`（带密钥）/ Tailscale 私网 / Cloudflare Tunnel（Access 认证）。

---

## 十二、验收清单与验证记录

CI（GitHub Actions）每次构建都会自动跑 `scripts/ci-smoke-test.sh`，覆盖以下自动化项（任一失败即不推送镜像，workflow 变红）：

1. `docker run -d` 一次成功，容器进入 `healthy`；
2. 逐端口 curl（通过对外映射端口）：`43030->3030` 正常响应（HTTP 200 + HTML）；`47183->7183` 在 `desktop-on` 后可访问；空端口 `40808/40809->8080/8090` 允许 connection refused，但 docker-proxy 处于监听（可绑定状态）；
3. ZCode 网页端可打开（HTTP 200 + HTML；浏览器内对话由用户完成）；
4. `desktop-on` 后 Selkies 网页端口出画面、`desktop-off` 后释放；
5. 同端口双客户端连接 + `docker port` 前后一致（映射端口总数恒为四个）；
6. 空闲回收生效（注入 25 秒短超时验证自动 desktop-off）；
7. Edge 无头模式启动且 CDP 9222 可控；edge-mcp `:7123` 健康检查通过；
8. sing-box：默认无进程；`proxy-on` 后新开用户 shell 有代理变量、ZCode 自身流量不走代理（隔离验证，二者都测）；`proxy-off` 后进程与环境文件全部清理干净；
9. 最终镜像内 git/pip/npm 无残留加速改写配置（`git config --global -l` 为空或无 insteadOf）；
10. 输出 `docker ps` + 容器内 `ss -tlnp` + 宿主机 `ss -tlnp` + `docker port`（全部存档在 Actions 日志中）。

**需要真实浏览器完成的两项人工验收**（无法在 CI 中模拟真实交互）：

- **同时远程验证**：两个浏览器同时连入 `47183`，均能看到画面并可操作（共享输入，会互相抢鼠标）；`docker exec zcode-container ss -tlnp` 确认未为此新增任何监听端口（端口总数恒为四个）；
- **ZCode 网页对话**：在浏览器中打开 `http://<host>:43030` 并完成一次对话。

宿主机上的逐端口验证：

```bash
bash scripts/verify-ports.sh
docker ps
sudo ss -tlnp | grep -E '43030|47183|40808|40809'
docker port zcode-container
```

---

## 十三、上游项目与许可证致谢

- [ZCode](https://github.com/zai-org/ZCode)（Apache-2.0）——本容器按其官方文档流程从源码构建；
- [Selkies](https://github.com/selkies-project/selkies)（MPL-2.0）——远程桌面按官方发行包接入，文档见 https://docs.selkies.io/ ；
- [edge-mcp](https://github.com/hualang-C/edge-mcp)（MIT）——Edge 浏览器 MCP 服务；
- [sing-box](https://github.com/SagerNet/sing-box)——代理工具（本容器唯一指定代理，未使用其他代理）；
- 本仓库自身脚本与编排文件以 MIT 发布（见 LICENSE）；容器内还包含 LibreOffice（MPL/LGPL，经 Ubuntu 官方仓库分发）与 Microsoft Edge（微软许可条款，经微软官方仓库分发）。
