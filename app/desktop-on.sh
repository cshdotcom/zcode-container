#!/usr/bin/env bash
###############################################################################
# desktop-on：启动 Selkies 远程桌面会话（默认关闭，按需启停）
#
# 接入方式与官方仓库一致：
#   selkies session --port=<P> --enable-basic-auth=false --enable-https=false --session=openbox
#   （参考 selkies-project/selkies addons/coder/run.sh.tftpl 与 docs.selkies.io/platforms）
#
# 多人同时远程（同时远程模式）：所有浏览器连入同一端口 7183 即可，
# 共享同一画面与输入（会互相抢鼠标），适合演示、协作、AI 干活时多人围观。
# 不为此开放任何多余端口，端口总数恒为四个。
#
# 空闲自动回收：SELKIES_IDLE_TIMEOUT 秒无操作自动 desktop-off（默认 900 秒，0 = 关闭）。
###############################################################################
set -euo pipefail

RUNDIR=/run/zcode-container
LOGDIR=/var/log/zcode-container
PORT="${SELKIES_PORT:-7183}"
IDLE_TIMEOUT="${SELKIES_IDLE_TIMEOUT:-900}"

command -v selkies >/dev/null 2>&1 || { echo "错误：selkies 未安装" >&2; exit 1; }

if [ -f "$RUNDIR/desktop.pid" ] && kill -0 "$(cat "$RUNDIR/desktop.pid")" 2>/dev/null; then
    echo "远程桌面会话已在运行 (pid $(cat "$RUNDIR/desktop.pid"))，无需重复启动。"
    echo "多人同连：所有浏览器访问同一对外端口即可（默认 ${EXT_SELKIES_PORT:-47183}）。"
    exit 0
fi

mkdir -p "$RUNDIR" "$LOGDIR"

# 与官方 docker-compose 相同的环境默认值（WebSockets 为主传输，WebRTC 可选）
export SELKIES_ENABLE_HTTPS="${SELKIES_ENABLE_HTTPS:-false}"
export SELKIES_MODE="${SELKIES_MODE:-websockets}"
export SELKIES_ENABLE_DUAL_MODE="${SELKIES_ENABLE_DUAL_MODE:-true}"

# 新会话进程组：Xvfb / Selkies / openbox 均在其内，desktop-off 只清理该进程组
setsid nohup selkies session \
    --port="$PORT" \
    --enable-basic-auth="${SELKIES_ENABLE_BASIC_AUTH:-false}" \
    --enable-https="$SELKIES_ENABLE_HTTPS" \
    --session="${SELKIES_SESSION:-openbox}" \
    >>"$LOGDIR/selkies.log" 2>&1 &
SESSION_PID=$!
echo "$SESSION_PID" >"$RUNDIR/desktop.pid"
echo "$SESSION_PID" >"$RUNDIR/desktop.pgid"

# 等待会话健康（官方健康端点 /api/health）
ready=""
for _ in $(seq 1 60); do
    if curl -fsS -m 3 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
        ready=1
        break
    fi
    kill -0 "$SESSION_PID" 2>/dev/null || break
    sleep 2
done

if [ -z "$ready" ]; then
    echo "错误：Selkies 会话未能在 120 秒内就绪，最近日志如下：" >&2
    tail -n 30 "$LOGDIR/selkies.log" >&2 || true
    kill -TERM -- "-$SESSION_PID" 2>/dev/null || kill -TERM "$SESSION_PID" 2>/dev/null || true
    rm -f "$RUNDIR/desktop.pid" "$RUNDIR/desktop.pgid"
    exit 1
fi

# 空闲回收看门狗
if [ "$IDLE_TIMEOUT" != "0" ]; then
    SELKIES_IDLE_TIMEOUT="$IDLE_TIMEOUT" setsid nohup /usr/local/bin/idle-watchdog.sh \
        >>"$LOGDIR/idle-watchdog.log" 2>&1 &
    echo $! >"$RUNDIR/idle-watchdog.pid"
fi

echo "Selkies 远程桌面已启动："
echo "  容器内端口 : $PORT"
echo "  对外访问   : http://<宿主机>:${EXT_SELKIES_PORT:-47183}（映射端口见 .env）"
echo "  多人同时远程: 所有浏览器连入同一端口，画面与输入共享（同时远程模式）"
echo "  空闲回收   : ${IDLE_TIMEOUT} 秒无操作自动关闭（0 = 关闭该功能）"
echo "  停止       : desktop-off.sh    状态: desktop-status.sh"
echo "  日志       : $LOGDIR/selkies.log"
