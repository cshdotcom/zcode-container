#!/usr/bin/env bash
###############################################################################
# verify-ports.sh —— 在宿主机上对容器做逐端口 curl 验证（验收用）
# 读取项目根目录 .env 中的 EXT_* 对外端口。
###############################################################################
set -u

cd "$(dirname "$0")/.." || exit 1

if [ ! -f .env ]; then
    echo "未找到 .env，请先执行: cp .env.example .env" >&2
    exit 1
fi
set -a
# shellcheck disable=SC1091
. ./.env
set +a

ZC="${EXT_ZCODE_PORT:?}"
SK="${EXT_SELKIES_PORT:?}"
S1="${EXT_SPARE_PORT_1:?}"
S2="${EXT_SPARE_PORT_2:?}"
HOST="${EXT_BIND_ADDR:-127.0.0.1}"

fail=0
ok()  { echo "  [PASS] $*"; }
bad() { echo "  [FAIL] $*"; fail=$((fail+1)); }

echo "对外端口读取自 .env：ZCODE=$ZC SELKIES=$SK SPARE1=$S1 SPARE2=$S2（绑定 ${HOST}）"
echo ""

echo "== ① ZCode 网页端（${ZC} -> 3030）=="
body=$(curl -fsS -m 15 "http://${HOST}:${ZC}/" 2>/dev/null || true)
if [ -n "$body" ] && printf '%s' "$body" | head -c 2048 | grep -qi '<!doctype\|<html'; then
    ok "HTTP 200 且返回 HTML（网页端可打开）"
else
    bad "无有效响应（容器未启动 / 未就绪 / 穿透未配置？）"
fi

echo "== ② Selkies 远程桌面（${SK} -> 7183，需先 desktop-on）=="
if curl -fsS -m 10 -o /dev/null "http://${HOST}:${SK}/" 2>/dev/null; then
    ok "HTTP 200（远程桌面会话运行中，多人可同时连入该端口）"
else
    echo "  [INFO] connection refused —— 会话未开启属预期（容器内执行 desktop-on.sh 后再验）"
fi

echo "== ③ 空端口（${S1} -> 8080）=="
if curl -fsS -m 5 -o /dev/null "http://${HOST}:${S1}/" 2>/dev/null; then
    bad "不应有任何服务响应（空端口必须为空）"
else
    ok "connection refused（预期；端口已映射且处于可绑定状态，供容器内 AI 自主使用）"
fi

echo "== ④ 空端口（${S2} -> 8090）=="
if curl -fsS -m 5 -o /dev/null "http://${HOST}:${S2}/" 2>/dev/null; then
    bad "不应有任何服务响应（空端口必须为空）"
else
    ok "connection refused（预期；端口已映射且处于可绑定状态，供容器内 AI 自主使用）"
fi

echo ""
echo "== docker port 与宿主机监听（可映射状态证明）=="
docker port zcode-container 2>/dev/null || echo "  (容器 zcode-container 未运行)"
ss -tln 2>/dev/null | grep -E ":${ZC} |:${SK} |:${S1} |:${S2} " || echo "  (ss 无匹配)"

echo ""
if [ "$fail" -eq 0 ]; then
    echo "端口验证：全部通过"
else
    echo "端口验证：${fail} 项失败"
fi
exit "$fail"
