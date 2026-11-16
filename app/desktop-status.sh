#!/usr/bin/env bash
###############################################################################
# desktop-status：查看 Selkies 远程桌面会话状态
###############################################################################
set -u

RUNDIR=/run/zcode-container
PORT="${SELKIES_PORT:-7183}"
PID=$(cat "$RUNDIR/desktop.pid" 2>/dev/null || true)

if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    STARTED=$(ps -o lstart= -p "$PID" 2>/dev/null | sed 's/^ *//' || echo "?")
    IDLE=$(cat "$RUNDIR/desktop.idle" 2>/dev/null || echo "?")
    echo "状态   : 运行中 (pid $PID，启动于 ${STARTED})"
    echo "空闲   : ${IDLE} 秒（${SELKIES_IDLE_TIMEOUT:-900} 秒无操作自动回收，0 = 关闭）"
    echo "健康   :"
    if curl -fsS -m 5 "http://127.0.0.1:${PORT}/api/health" 2>/dev/null | jq . 2>/dev/null; then
        :
    else
        echo "  (http://127.0.0.1:${PORT}/api/health 不可达)"
    fi
    echo "监听   :"
    ss -tlnp 2>/dev/null | grep ":${PORT} " || echo "  (无)"
    echo "提示   : 多人同时远程 = 所有浏览器连入同一对外端口（默认 ${EXT_SELKIES_PORT:-47183}）"
else
    echo "状态   : 未运行（默认关闭；执行 desktop-on.sh 启动）"
    echo "监听   :"
    ss -tlnp 2>/dev/null | grep ":${PORT} " || echo "  (无)"
fi
