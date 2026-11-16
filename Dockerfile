# syntax=docker/dockerfile:1.7
###############################################################################
# ZCode 自托管 AI 工作容器
#
# 上游组件（全部按官方仓库方式接入，版本固定可复现）：
#   ZCode     https://github.com/zai-org/ZCode            源码构建（Node.js 24.14.0 + pnpm 10.33.2）
#   Selkies   https://github.com/selkies-project/selkies  官方 .deb（selkies session，X11/Xvfb 后端）
#   edge-mcp  https://github.com/hualang-C/edge-mcp       源码固定 commit（HTTP 模式 :7123）
#   sing-box  https://github.com/SagerNet/sing-box        官方二进制（默认不启动，无配置即直连）
#
# 构建开关（默认全部"直连不改写"）：
#   --build-arg USE_CN_MIRROR=1   国内构建加速（git 下载走镜像前缀 / npm / pip / apt / electron 镜像）
#   --build-arg GH_PROXY=https://gh-proxy.com/   GitHub 下载镜像前缀（USE_CN_MIRROR=1 时默认
#                                  https://ghfast.space/，可换 https://gh-proxy.com/ 或 https://ghproxy.net/）
#
# 加速只存在于构建阶段：多阶段构建 + 单 RUN 内还原，最终镜像内 git / pip / npm 均为直连配置。
###############################################################################

ARG ZCODE_REF="v3.18.2"
ARG ZCODE_DIST_BASE_URL="https://downloads.example.com/zcode/"
ARG SELKIES_VERSION="2.2.1"
ARG SELKIES_DEB_SHA256="4bc87969acf45951fbf6148b9d7e23717df58411e5a47d361b99b78842caaa8c"
ARG SINGBOX_VERSION="1.14.4"
ARG SINGBOX_SHA256="699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968"
ARG EDGEMCP_REF="72692af758b8955a995775cddfa2f1cf7dbd577d"
ARG NODE_VERSION="24.14.0"
ARG NODE_SHA256="41cd79bb7877c81605a9e68ec4c91547774f46a40c67a17e34d7179ef11729df"
ARG USE_CN_MIRROR=0
ARG GH_PROXY=""

###############################################################################
# Stage 1: ZCode 源码构建
# 基础镜像与 pnpm 激活方式与上游 Dockerfile.desktop-e2e 完全一致。
###############################################################################
FROM node:24.14.0-bookworm AS zcode-builder

ARG ZCODE_REF
ARG ZCODE_DIST_BASE_URL
ARG USE_CN_MIRROR
ARG GH_PROXY

# 与上游 CI 容器环境一致：HUSKY=0 跳过 git hooks，CI=1 使 pnpm install 走 frozen-lockfile
ENV CI=1 \
    HUSKY=0 \
    PNPM_HOME=/pnpm \
    PATH="/pnpm:${PATH}"

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git g++ make pkg-config python3 xz-utils; \
    rm -rf /var/lib/apt/lists/*

# 官方流程：git clone -> corepack 激活 pnpm 10.33.2 -> pnpm bootstrap -> pnpm build:zcode
# https://github.com/zai-org/ZCode README「初始化 / ZCode 命令行版」
RUN set -eux; \
    if [ "$USE_CN_MIRROR" = "1" ]; then \
        GH_PROXY="${GH_PROXY:-https://ghfast.space/}"; \
        export ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/"; \
        export COREPACK_NPM_REGISTRY="https://registry.npmmirror.com"; \
    fi; \
    git clone --depth 1 --branch "${ZCODE_REF}" \
        "${GH_PROXY}https://github.com/zai-org/ZCode.git" /opt/zcode-src; \
    cd /opt/zcode-src; \
    if [ "$USE_CN_MIRROR" = "1" ]; then \
        # 仅构建期替换 registry 加速依赖下载；构建产物与最终镜像均不含该配置
        sed -i 's|^registry=.*|registry=https://registry.npmmirror.com|' .npmrc; \
    fi; \
    corepack enable; \
    corepack prepare pnpm@10.33.2 --activate; \
    pnpm config set --global store-dir /pnpm/store; \
    pnpm bootstrap; \
    pnpm build:zcode --base-url "${ZCODE_DIST_BASE_URL}"; \
    # 校验产物齐全（上游 build-zcode.mjs 自身的断言之外再加一道）
    ls dist/zcode/releases/*/zcode-*.tar.gz; \
    test -f dist/zcode/latest.json; \
    # 解出运行包并保留构建产物，其余构建树在同一 RUN 内删除（不进入镜像层）
    mkdir -p /opt/zcode-dist /artifacts; \
    tar -xzf dist/zcode/releases/*/zcode-*.tar.gz -C /opt/zcode-dist; \
    test -x /opt/zcode-dist/zcode/bin/zcode.mjs; \
    cp -a dist/zcode/. /artifacts/; \
    rm -rf /opt/zcode-src /pnpm/store /root/.cache /root/.npm

# 供 CI 导出 ZCode 源码构建产物（CLI 发行包）
FROM scratch AS zcode-artifacts
COPY --from=zcode-builder /artifacts/ /

###############################################################################
# Stage 2: 运行时（Ubuntu 24.04 + 全部办公/编程/远程桌面环境）
###############################################################################
FROM ubuntu:24.04 AS runtime

ARG SELKIES_VERSION
ARG SELKIES_DEB_SHA256
ARG SINGBOX_VERSION
ARG SINGBOX_SHA256
ARG EDGEMCP_REF
ARG NODE_VERSION
ARG NODE_SHA256
ARG USE_CN_MIRROR
ARG GH_PROXY

LABEL org.opencontainers.image.title="zcode-container" \
      org.opencontainers.image.description="自托管 AI 工作容器：ZCode 网页版 + Selkies 远程桌面 + Edge 浏览器自动化 + 办公/编程环境" \
      org.opencontainers.image.source="https://github.com/cshdotcom/zcode-container" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=zh_CN.UTF-8 \
    LC_ALL=zh_CN.UTF-8 \
    TZ=Asia/Shanghai \
    DISPLAY=":99" \
    EDGE_CDP_PORT=9222

# apt 网络重试（参考 Selkies 官方 base 镜像）
RUN printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
        > /etc/apt/apt.conf.d/80-retries

# ---------- 系统工具 + 办公 + 编程 + Selkies 会话依赖（X11/Xvfb 后端） ----------
# X11 客户端库与 xvfb/xauth/xdotool/xclip 等清单来自 Selkies 官方 addons/base Dockerfile
RUN set -eux; \
    if [ "$USE_CN_MIRROR" = "1" ]; then \
        cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak; \
        sed -i 's|http://archive.ubuntu.com|https://mirrors.aliyun.com|g; s|http://security.ubuntu.com|https://mirrors.aliyun.com|g' \
            /etc/apt/sources.list.d/ubuntu.sources; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        apt-utils ca-certificates curl gnupg git tmux jq file less nano vim-tiny \
        iproute2 procps xprintidle lsb-release \
        locales tzdata \
        build-essential pkg-config python3 python3-pip \
        zip unzip xz-utils \
        pandoc libreoffice-writer libreoffice-calc libreoffice-impress \
        libreoffice-l10n-zh-cn \
        xvfb xauth x11-xserver-utils x11-utils x11-xkb-utils wmctrl dbus-x11 \
        xdotool xclip xsettingsd \
        openbox pulseaudio coturn \
        libx11-xcb1 libxcb1 libxcb-shm0 libxcb-xfixes0 libxcb-randr0 libxcb-dri3-0 \
        libxkbcommon0 libxdamage1 libxfixes3 libxtst6 libxext6 \
        fonts-dejavu-core fonts-liberation fonts-noto-core fonts-noto-cjk \
        fonts-noto-color-emoji fonts-ubuntu fonts-opensymbol; \
    if [ "$USE_CN_MIRROR" = "1" ]; then \
        mv /etc/apt/sources.list.d/ubuntu.sources.bak /etc/apt/sources.list.d/ubuntu.sources; \
    fi; \
    sed -i 's/^# *\(zh_CN.UTF-8 UTF-8\)/\1/; s/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/cache/debconf/* /tmp/* /var/tmp/*

# ---------- Microsoft Edge（官方 apt 仓库方式安装） ----------
RUN set -eux; \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor --yes \
        -o /usr/share/keyrings/microsoft-edge.gpg; \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-edge.gpg] https://packages.microsoft.com/repos/edge stable main" \
        > /etc/apt/sources.list.d/microsoft-edge.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends microsoft-edge-stable; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    microsoft-edge --version

# ---------- Selkies 官方 .deb（版本与 sha256 固定） ----------
RUN set -eux; \
    GP=""; \
    if [ "$USE_CN_MIRROR" = "1" ]; then GP="${GH_PROXY:-https://ghfast.space/}"; fi; \
    curl -fsSL -o /tmp/selkies.deb \
        "${GP}https://github.com/selkies-project/selkies/releases/download/${SELKIES_VERSION}/selkies-${SELKIES_VERSION}-ubuntu24.04-amd64.deb"; \
    echo "${SELKIES_DEB_SHA256}  /tmp/selkies.deb" | sha256sum -c -; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/selkies.deb; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/selkies.deb; \
    # 官方 coder 插件同款校验：必须提供 `selkies session` 子命令（2.1.0+）
    selkies --version; \
    selkies session --help 2>&1 | grep -qi 'usage: selkies session'

# ---------- sing-box 官方二进制 -> /usr/local/bin（默认不启动，无配置即直连） ----------
RUN set -eux; \
    GP=""; \
    if [ "$USE_CN_MIRROR" = "1" ]; then GP="${GH_PROXY:-https://ghfast.space/}"; fi; \
    curl -fsSL -o /tmp/sing-box.tar.gz \
        "${GP}https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-amd64.tar.gz"; \
    echo "${SINGBOX_SHA256}  /tmp/sing-box.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/sing-box.tar.gz -C /tmp; \
    install -m 0755 "/tmp/sing-box-${SINGBOX_VERSION}-linux-amd64/sing-box" /usr/local/bin/sing-box; \
    rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${SINGBOX_VERSION}-linux-amd64"; \
    sing-box version

# ---------- Node.js 24.14.0（官方发行 tarball，版本与 ZCode 要求一致） ----------
RUN set -eux; \
    NB="https://nodejs.org/dist"; \
    if [ "$USE_CN_MIRROR" = "1" ]; then NB="https://npmmirror.com/mirrors/node"; fi; \
    curl -fsSL -o /tmp/node.tar.xz \
        "${NB}/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1; \
    rm -f /tmp/node.tar.xz; \
    node --version; \
    if [ "$USE_CN_MIRROR" = "1" ]; then \
        COREPACK_NPM_REGISTRY="https://registry.npmmirror.com" corepack prepare pnpm@10.33.2 --activate; \
    else \
        corepack prepare pnpm@10.33.2 --activate; \
    fi; \
    corepack enable; \
    pnpm --version

# ---------- edge-mcp（源码固定 commit，npm install 仅生产依赖） ----------
RUN set -eux; \
    GP=""; \
    if [ "$USE_CN_MIRROR" = "1" ]; then GP="${GH_PROXY:-https://ghfast.space/}"; fi; \
    git clone "${GP}https://github.com/hualang-C/edge-mcp.git" /opt/edge-mcp; \
    cd /opt/edge-mcp; \
    git checkout --detach "${EDGEMCP_REF}"; \
    # 还原官方 remote（镜像前缀只允许存在于构建期）
    git remote set-url origin https://github.com/hualang-C/edge-mcp.git; \
    if [ "$USE_CN_MIRROR" = "1" ]; then \
        npm install --omit=dev --registry=https://registry.npmmirror.com; \
    else \
        npm install --omit=dev; \
    fi; \
    node --check src/index.js; \
    node --check src/http.js

# ---------- Python 办公库（openpyxl / python-docx / pypdf） ----------
RUN set -eux; \
    if [ "$USE_CN_MIRROR" = "1" ]; then \
        pip3 install --no-cache-dir --break-system-packages \
            --index-url https://pypi.tuna.tsinghua.edu.cn/simple \
            openpyxl python-docx pypdf; \
    else \
        pip3 install --no-cache-dir --break-system-packages \
            openpyxl python-docx pypdf; \
    fi; \
    python3 -c "import openpyxl, docx, pypdf; print('python office libs ok')"

# ---------- ZCode 运行包（来自 Stage 1 的源码构建产物） ----------
COPY --from=zcode-builder /opt/zcode-dist/zcode /opt/zcode
RUN set -eux; \
    printf '#!/bin/sh\nexec node /opt/zcode/bin/zcode.mjs "$@"\n' > /usr/local/bin/zcode; \
    chmod 0755 /usr/local/bin/zcode; \
    zcode --help; \
    ls /opt/zcode/bin/zcode.mjs

# ---------- 容器脚本与默认配置 ----------
COPY app/entrypoint.sh app/healthcheck.sh app/desktop-on.sh app/desktop-off.sh \
     app/desktop-status.sh app/idle-watchdog.sh app/proxy-on.sh app/proxy-off.sh \
     app/mcp-register-edge.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh \
        /usr/local/bin/desktop-on.sh /usr/local/bin/desktop-off.sh \
        /usr/local/bin/desktop-status.sh /usr/local/bin/idle-watchdog.sh \
        /usr/local/bin/proxy-on.sh /usr/local/bin/proxy-off.sh \
        /usr/local/bin/mcp-register-edge.sh

# ZCode 的 MCP 配置种子（edge-mcp HTTP 端点）；/root/.zcode 为持久化卷，首次挂载时自动带入
COPY app/zcode-default-config/config.json /root/.zcode/cli/config.json

RUN mkdir -p /workspace/preview /data/edge-profile /etc/sing-box \
        /data/extra1 /data/extra2 /data/extra3 \
        /var/log/zcode-container /run/zcode-container

VOLUME ["/workspace", "/root/.zcode", "/data/edge-profile", "/etc/sing-box", \
        "/data/extra1", "/data/extra2", "/data/extra3"]

# 四个容器内端口（对外映射端口在 .env 中集中定义，一律避开常用端口号）
EXPOSE 3030 7183 8080 8090

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
