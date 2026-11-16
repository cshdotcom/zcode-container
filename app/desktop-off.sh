#!/usr/bin/env bash
###############################################################################
# desktop-off：停止 Selkies 远程桌面会话并释放资源
#
# 白名单清理：只清理 desktop-on 自己拉起的会话进程组（Xvfb / Selkies / openbox
# 全部在该进程组内），绝不触碰常驻 Xvfb :99 与其他系统服务。
###############################################################################
set -u

RUNDIR=/run/zcode-container
PORT="${SELKIES_PORT:-7183}"

PID=$(cat "$RUNDIR/desktop.pid" 2>/dev/null || true)

if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
    echo "远程桌面会话未在运行（默认即关闭）。"
    rm -f "$RUNDIR/desktop.pid" "$RUNDIR/desktop.pgid" "$RUNDIR/desktop.idle" \
          "$RUNDIR/idle-watchdog.pid"
    exit 0
fi

echo "停止 Selkies 远程桌面会话（进程组 pgid=$PID）..."

# 先停看门狗，避免回收期间误判
WPID=$(cat "$RUNDIR/idle-watchdog.pid" 2>/dev/null || true)
if [ -n "$WPID" ]; then
    kill -TERM "$WPID" 2>/dev/null || true
    rm -f "$RUNDIR/idle-watchdog.pid"
fi

# 只清理本会话进程组（Xvfb / Selkies / openbox），不误杀其他进程
kill -TERM -- "-$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null || true
for _ in $(seq 1 20); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.5
done
kill -KILL -- "-$PID" 2>/dev/null || true

rm -f "$RUNDIR/desktop.pid" "$RUNDIR/desktop.pgid" "$RUNDIR/desktop.idle"

sleep 1
if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":${PORT}$"; then
    echo "WARN: 端口 ${PORT} 仍被占用，残留监听进程："
    ss -tlnp 2>/dev/null | grep ":${PORT} " || true
    exit 1
else
    echo "已释放：会话进程组清理完毕，端口 ${PORT} 不再监听。"
fi
