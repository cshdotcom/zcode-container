#!/usr/bin/env bash
###############################################################################
# ZCode 自托管 AI 工作容器 - 入口（PID 1）
#
# 启动的常驻服务（全部绑定 0.0.0.0 或 127.0.0.1，端口规划见 README）：
#   Xvfb :99        常驻虚拟屏（Edge 有头模式/桌面应用兜底显示用）
#   Edge headless   主浏览器自动化（CDP 127.0.0.1:9222）
#   edge-mcp        Edge 的 MCP 服务（0.0.0.0:7123，/health 健康检查）
#   ZCode web       网页端主入口（0.0.0.0:3030）
#
# 默认不启动：Selkies 远程桌面（desktop-on / desktop-off 控制）、sing-box（proxy-on / proxy-off 控制）
###############################################################################
set -u

RUNDIR=/run/zcode-container
LOGDIR=/var/log/zcode-container

log() { echo "[entrypoint $(date '+%F %T')] $*"; }

mkdir -p "$RUNDIR" "$LOGDIR" \
    /workspace/preview /data/edge-profile /etc/sing-box \
    /data/extra1 /data/extra2 /data/extra3

# ---------------- 各服务启动函数 ----------------

start_xvfb99() {
    nohup Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp \
        >>"$LOGDIR/xvfb.log" 2>&1 &
    echo $! >"$RUNDIR/xvfb99.pid"
}

start_edge() {
    # Edge 无头模式 + CDP（edge-mcp 通过 127.0.0.1:9222 接管；用户数据目录持久化）
    nohup microsoft-edge \
        --headless \
        --remote-debugging-port=9222 \
        --remote-debugging-address=127.0.0.1 \
        --remote-allow-origins='*' \
        --user-data-dir=/data/edge-profile \
        --no-first-run --no-default-browser-check \
        --no-sandbox --disable-gpu --disable-dev-shm-usage \
        --disable-crash-reporter \
        about:blank \
        >>"$LOGDIR/edge.log" 2>&1 &
    echo $! >"$RUNDIR/edge.pid"
}

start_edge_mcp() {
    ( cd /opt/edge-mcp && \
      HOST=0.0.0.0 PORT=7123 EDGE_CDP_PORT=9222 \
      nohup node src/index.js --http \
        >>"$LOGDIR/edge-mcp.log" 2>&1 & \
      echo $! >"$RUNDIR/edge-mcp.pid" )
}

start_zcode() {
    # 令牌策略：ZCODE_WEB_TOKEN 非空 -> --token；为空 -> --no-token（安全由穿透层负责，见 README）
    local token_args=()
    if [ -n "${ZCODE_WEB_TOKEN:-}" ]; then
        token_args=(--token "$ZCODE_WEB_TOKEN")
    else
        token_args=(--no-token)
    fi
    nohup node /opt/zcode/bin/zcode.mjs --web \
        --no-open --host 0.0.0.0 --port 3030 --workspace /workspace \
        "${token_args[@]}" \
        >>"$LOGDIR/zcode.log" 2>&1 &
    echo $! >"$RUNDIR/zcode.pid"
}

# ---------------- 优雅停止 ----------------

term() {
    log "收到停止信号，正在停止全部服务..."
    local pids=""
    for svc in zcode edge-mcp edge xvfb99; do
        local f="$RUNDIR/$svc.pid"
        [ -f "$f" ] && pids="$pids $(cat "$f")"
    done
    # 一并停止远程桌面会话（若开启）
    command -v desktop-off.sh >/dev/null 2>&1 && desktop-off.sh >/dev/null 2>&1 || true
    command -v proxy-off.sh >/dev/null 2>&1 && proxy-off.sh >/dev/null 2>&1 || true
    [ -n "$pids" ] && kill $pids 2>/dev/null || true
    sleep 2
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
    log "已停止。"
    exit 0
}
trap term TERM INT

# ---------------- ZCode 无头服务端凭据密钥 ----------------
# 上游 systemCredentialCipher 要求：Secret Service / ZCODE_CREDENTIAL_SECRET /
# ZCODE_CREDENTIAL_SECRET_FILE（0600、32–4096 字节）三选一，且不得并用。
# 无 Secret Service 的容器内采用默认文件位置 /root/.zcode/v2/credential-secret，
# 首次启动生成，持久化于 /root/.zcode 卷（加密数据依赖原密钥，重启不丢）。
if [ -z "${ZCODE_CREDENTIAL_SECRET:-}" ] && [ -z "${ZCODE_CREDENTIAL_SECRET_FILE:-}" ]; then
    ZCODE_SECRET_FILE=/root/.zcode/v2/credential-secret
    mkdir -p /root/.zcode/v2
    if [ ! -f "$ZCODE_SECRET_FILE" ]; then
        ( umask 077; head -c 48 /dev/urandom | base64 -w0 >"$ZCODE_SECRET_FILE" )
        chmod 0600 "$ZCODE_SECRET_FILE"
        log "已生成 ZCode 凭据密钥：$ZCODE_SECRET_FILE（0600，持久卷内）"
    fi
    export ZCODE_CREDENTIAL_SECRET_FILE="$ZCODE_SECRET_FILE"
fi

# ---------------- 启动 ----------------

log "启动常驻服务：Xvfb:99 / Edge(headless,CDP:9222) / edge-mcp(:7123) / ZCode web(:3030)"
start_xvfb99
start_edge
start_edge_mcp
start_zcode

log "等待服务就绪（最长 120 秒）..."
ready=""
for _ in $(seq 1 60); do
    if curl -fsS -m 3 -o /dev/null http://127.0.0.1:3030/ 2>/dev/null \
       && curl -fsS -m 3 -o /dev/null http://127.0.0.1:7123/health 2>/dev/null \
       && curl -fsS -m 3 -o /dev/null http://127.0.0.1:9222/json/version 2>/dev/null; then
        ready=1
        break
    fi
    sleep 2
done

# ZCode 就绪后再写入 MCP 配置（仅当用户未自带配置时；不覆盖已有 /root/.zcode 数据）
if [ -n "$ready" ] && [ ! -f /root/.zcode/cli/config.json ]; then
    mcp-register-edge.sh >>"$LOGDIR/mcp-register.log" 2>&1 \
        && log "已为 ZCode 注册 edge-mcp（/root/.zcode/cli/config.json）" \
        || log "WARN: edge-mcp 注册失败，可稍后手动执行 mcp-register-edge"
fi

if [ -n "$ready" ]; then
    log "全部常驻服务已就绪。"
else
    log "WARN: 部分服务 120 秒内未就绪（详见 $LOGDIR/ 各日志；守护循环会继续自动重启）"
fi

log "容器就绪："
log "  ZCode 网页端   : 容器内 3030（对外映射端口见 .env，默认 43030）"
log "  Selkies 远程桌面: 默认关闭，执行 desktop-on.sh 启动（容器内 7183，对外默认 47183）"
log "  远程桌面多人同连: 所有浏览器连入同一对外端口即可，画面与输入共享"
log "  代理           : 默认直连；放置 /etc/sing-box/config.json 后执行 proxy-on.sh"
log "  各服务日志     : $LOGDIR/"

# ---------------- 守护循环：子进程退出自动重启（60 秒窗口内最多 5 次） ----------------

declare -A FAILS LASTFAIL

while :; do
    for svc in xvfb99 edge edge-mcp zcode; do
        pidfile="$RUNDIR/$svc.pid"
        [ -f "$pidfile" ] || continue
        pid=$(cat "$pidfile" 2>/dev/null) || continue
        if ! kill -0 "$pid" 2>/dev/null; then
            now=$(date +%s)
            last=${LASTFAIL[$svc]:-0}
            if [ $((now - last)) -gt 60 ]; then FAILS[$svc]=0; fi
            if [ "${FAILS[$svc]:-0}" -ge 5 ]; then
                [ $((now - last)) -gt 300 ] || { log "ERROR: 服务 $svc 反复退出，暂停重启（容器保持运行以便 docker exec 排查）"; continue; }
                FAILS[$svc]=0
            fi
            FAILS[$svc]=$(( ${FAILS[$svc]:-0} + 1 ))
            LASTFAIL[$svc]=$now
            log "WARN: 服务 $svc (pid $pid) 已退出，3 秒后重启（窗口内第 ${FAILS[$svc]} 次）"
            sleep 3
            "start_${svc//-/_}" 2>/dev/null || "start_$svc" 2>/dev/null || true
        fi
    done
    # 阻塞等待任一子进程退出（同时回收僵尸进程）
    wait -n 2>/dev/null || true
    sleep 1
done
