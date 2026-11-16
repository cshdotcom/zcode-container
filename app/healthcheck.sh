#!/usr/bin/env bash
###############################################################################
# 容器健康检查（Dockerfile HEALTHCHECK 调用）
# 检查全部预置服务；Selkies 会话默认关闭，仅在开启时才要求其健康。
###############################################################################
set -u

fail=0

if curl -fsS -m 8 -o /dev/null http://127.0.0.1:3030/ 2>/dev/null; then
    echo "zcode(3030): ok"
else
    echo "zcode(3030): FAIL"
    fail=1
fi

if curl -fsS -m 8 http://127.0.0.1:7123/health >/dev/null 2>&1; then
    echo "edge-mcp(7123): ok"
else
    echo "edge-mcp(7123): FAIL"
    fail=1
fi

if curl -fsS -m 8 http://127.0.0.1:9222/json/version >/dev/null 2>&1; then
    echo "edge-cdp(9222): ok"
else
    echo "edge-cdp(9222): FAIL"
    fail=1
fi

if [ -f /run/zcode-container/desktop.pid ] \
   && kill -0 "$(cat /run/zcode-container/desktop.pid 2>/dev/null)" 2>/dev/null; then
    if curl -fsS -m 8 http://127.0.0.1:7183/api/health >/dev/null 2>&1; then
        echo "selkies(7183): ok (会话运行中)"
    else
        echo "selkies(7183): FAIL (会话运行中但端口不健康)"
        fail=1
    fi
else
    echo "selkies(7183): 未启动 (默认关闭，属正常)"
fi

exit $fail
