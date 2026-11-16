#!/usr/bin/env bash
###############################################################################
# proxy-off：停止 sing-box 并删除代理环境文件，清理干净
#   - 停止 proxy-on 拉起的 sing-box 进程组
#   - 删除 /etc/profile.d/proxy-env.sh
#   - 移除 /etc/bash.bashrc 中的守卫块
###############################################################################
set -u

RUNDIR=/run/zcode-container
ENV_FILE="/etc/profile.d/proxy-env.sh"
BASHRC="/etc/bash.bashrc"
MARK_BEGIN="# >>> zcode-container proxy-env >>>"
MARK_END="# <<< zcode-container proxy-env <<<"

PID=$(cat "$RUNDIR/singbox.pid" 2>/dev/null || true)

if [ -n "$PID" ]; then
    kill -TERM -- "-$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null || true
    for _ in $(seq 1 10); do
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.5
    done
    kill -KILL -- "-$PID" 2>/dev/null || true
    rm -f "$RUNDIR/singbox.pid"
fi

rm -f "$ENV_FILE"

if [ -f "$BASHRC" ] && grep -qF "$MARK_BEGIN" "$BASHRC" 2>/dev/null; then
    sed -i "/${MARK_BEGIN//\//\\/}/,/${MARK_END//\//\\/}/d" "$BASHRC"
    # 兜底：按字面标记再删一次（防止转义差异导致残留）
    grep -qF "$MARK_BEGIN" "$BASHRC" && sed -i '/zcode-container proxy-env/d' "$BASHRC" || true
fi

echo "清理结果："
if pgrep -x sing-box >/dev/null 2>&1; then
    echo "  WARN: 仍有 sing-box 进程在运行（非 proxy-on 拉起或手动启动的）："
    pgrep -a -x sing-box || true
else
    echo "  sing-box 进程 : 无"
fi
if [ -f "$ENV_FILE" ]; then
    echo "  WARN: $ENV_FILE 仍存在"
else
    echo "  环境文件      : 已删除（/etc/profile.d/proxy-env.sh）"
fi
if grep -qF "$MARK_BEGIN" "$BASHRC" 2>/dev/null; then
    echo "  WARN: bashrc 守卫块残留"
else
    echo "  bashrc 守卫块 : 已移除"
fi
echo "proxy-off 完成：新开的用户 shell 将不再携带代理变量，已运行服务不受影响。"
