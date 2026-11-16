#!/usr/bin/env bash
###############################################################################
# idle-watchdog：Selkies 会话空闲看门狗（由 desktop-on 拉起）
#
# 每轮从会话进程组任一进程的环境提取 DISPLAY/XAUTHORITY，用 xprintidle 读取
# 该虚拟屏上的空闲时间；连续无输入达到 SELKIES_IDLE_TIMEOUT 秒即调用
# desktop-off 释放资源。
###############################################################################
set -u

RUNDIR=/run/zcode-container
TIMEOUT="${SELKIES_IDLE_TIMEOUT:-900}"
POLL=15

log() { echo "[$(date '+%F %T')] $*"; }

log "watchdog 启动（idle_timeout=${TIMEOUT}s，轮询 ${POLL}s）"

while :; do
    sleep "$POLL"

    PID=$(cat "$RUNDIR/desktop.pid" 2>/dev/null) || { log "无会话，退出"; exit 0; }
    kill -0 "$PID" 2>/dev/null || { log "会话已结束，退出"; exit 0; }

    # 从会话进程组（pgid = 会话 pid）中解析 DISPLAY / XAUTHORITY
    DISP=""
    XAUTH=""
    for p in "$PID" $(pgrep -g "$PID" 2>/dev/null); do
        [ -r "/proc/$p/environ" ] || continue
        e=$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null || true)
        d=$(printf '%s\n' "$e" | sed -n 's/^DISPLAY=//p' | head -n 1)
        if [ -n "$d" ]; then
            DISP="$d"
            XAUTH=$(printf '%s\n' "$e" | sed -n 's/^XAUTHORITY=//p' | head -n 1)
            break
        fi
    done

    if [ -z "$DISP" ]; then
        log "暂时无法解析会话 DISPLAY，跳过本轮"
        continue
    fi
    [ -n "$XAUTH" ] || XAUTH="/root/.Xauthority"

    idle_ms=$(DISPLAY="$DISP" XAUTHORITY="$XAUTH" timeout 5 xprintidle 2>/dev/null || echo -1)
    if [ "$idle_ms" = "-1" ]; then
        log "xprintidle 读取失败（DISPLAY=$DISP），跳过本轮"
        continue
    fi

    idle_s=$((idle_ms / 1000))
    echo "$idle_s" >"$RUNDIR/desktop.idle" 2>/dev/null || true

    if [ "$idle_s" -ge "$TIMEOUT" ]; then
        log "空闲 ${idle_s}s >= ${TIMEOUT}s，自动回收远程桌面会话"
        /usr/local/bin/desktop-off.sh || true
        log "会话已回收，看门狗退出"
        exit 0
    fi
done
