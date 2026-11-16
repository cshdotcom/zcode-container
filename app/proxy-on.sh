#!/usr/bin/env bash
###############################################################################
# proxy-on：启动 sing-box，并把代理环境变量写入 /etc/profile.d/proxy-env.sh
#
# 隔离硬性要求：代理变量只写入 profile.d（并加 bashrc 守卫块），
# 仅对之后新开的用户 shell 生效；已运行的服务（ZCode / Edge / edge-mcp）
# 与入口进程的环境不受任何影响 —— ZCode 自身流量绝不走代理。
#
# 配置目录 /etc/sing-box 挂卷持久化；默认无配置即直连，本脚本拒绝启动。
###############################################################################
set -euo pipefail

RUNDIR=/run/zcode-container
LOGDIR=/var/log/zcode-container
CONF="/etc/sing-box/config.json"
ENV_FILE="/etc/profile.d/proxy-env.sh"
BASHRC="/etc/bash.bashrc"
MARK_BEGIN="# >>> zcode-container proxy-env >>>"
MARK_END="# <<< zcode-container proxy-env <<<"

PROXY_ADDR="${SINGBOX_PROXY_ADDR:-http://127.0.0.1:2080}"
NO_PROXY_VAL="${NO_PROXY_OVERRIDE:-localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,.local,.internal,.lan,.z.ai,.bigmodel.cn,.zhipuai.cn,.aliyun.com,.aliyuncs.com,.taobao.com,.tmall.com,.jd.com,.qq.com,.weixin.qq.com,.baidu.com,.bilibili.com,.douyin.com,.feishu.cn,.npmmirror.com,.tuna.tsinghua.edu.cn,.ustc.edu.cn,.pku.edu.cn,.163.com,.126.com}"

[ "$(id -u)" = 0 ] || { echo "错误：需要 root" >&2; exit 1; }

# 已在运行则直接返回
if [ -f "$RUNDIR/singbox.pid" ] && kill -0 "$(cat "$RUNDIR/singbox.pid")" 2>/dev/null; then
    echo "sing-box 已在运行 (pid $(cat "$RUNDIR/singbox.pid"))。"
    exit 0
fi

# 默认无配置即直连：不启动
if [ ! -f "$CONF" ]; then
    echo "未找到 $CONF —— 默认直连模式，不启动代理。" >&2
    echo "请先放置 sing-box 配置（README「sing-box 代理」章节有最小示例与说明），再执行 proxy-on。" >&2
    exit 1
fi

mkdir -p "$RUNDIR" "$LOGDIR"
setsid nohup sing-box run -c "$CONF" >>"$LOGDIR/sing-box.log" 2>&1 &
SBPID=$!
echo "$SBPID" >"$RUNDIR/singbox.pid"

sleep 2
if ! kill -0 "$SBPID" 2>/dev/null; then
    echo "错误：sing-box 启动失败，最近日志：" >&2
    tail -n 20 "$LOGDIR/sing-box.log" >&2 || true
    rm -f "$RUNDIR/singbox.pid"
    exit 1
fi

# 代理变量：只写入 profile.d + bashrc 守卫块，仅影响之后新开的用户 shell
cat >"$ENV_FILE" <<EOF
# 由 proxy-on 生成，proxy-off 删除。
# 仅对之后新开的用户 shell 生效；不影响已运行服务（ZCode / Edge / edge-mcp）。
export HTTP_PROXY="$PROXY_ADDR"
export HTTPS_PROXY="$PROXY_ADDR"
export http_proxy="$PROXY_ADDR"
export https_proxy="$PROXY_ADDR"
export NO_PROXY="$NO_PROXY_VAL"
export no_proxy="$NO_PROXY_VAL"
EOF
chmod 0644 "$ENV_FILE"

if [ -f "$BASHRC" ] && ! grep -qF "$MARK_BEGIN" "$BASHRC" 2>/dev/null; then
    printf '\n%s\nif [ -f %s ]; then . %s; fi\n%s\n' \
        "$MARK_BEGIN" "$ENV_FILE" "$ENV_FILE" "$MARK_END" >>"$BASHRC"
fi

echo "sing-box 已启动 (pid $SBPID)，日志：$LOGDIR/sing-box.log"
echo "代理环境变量已写入 $ENV_FILE（仅对之后新开的用户 shell 生效）。"
echo "  生效验证 : docker exec -it <容器> bash -l -c 'env | grep -i proxy'"
echo "  隔离验证 : ZCode 进程环境无任何代理变量（README「代理与环境隔离」）"
echo "  代理地址 : $PROXY_ADDR（如 sing-box 监听其他端口，用 SINGBOX_PROXY_ADDR 覆盖）"
echo "  关闭     : proxy-off"
