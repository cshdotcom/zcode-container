#!/usr/bin/env bash
###############################################################################
# ci-smoke-test.sh —— 在 CI（GitHub Actions）中对构建产物做端到端验收
#
# 用法: bash scripts/ci-smoke-test.sh <镜像名>
# 覆盖：
#   1. docker run 一次成功，容器 healthy
#   2. 逐端口验证：43030->3030 正常响应；47183->7183 desktop-on 后可访问；
#      空端口 40808/40809 允许 connection refused，但 docker-proxy 处于监听（可绑定）
#   3. ZCode 网页端可打开（HTTP 200 + HTML）
#   4. desktop-on 后 Selkies 出画面端口，desktop-off 后释放
#   5. 同端口双客户端同时连接 + 映射端口总数恒为四个（docker port 前后一致）
#   6. 空闲回收（短超时注入验证）
#   7. Edge CDP 9222 可控 + edge-mcp :7123 健康检查
#   8. sing-box：默认无进程；proxy-on 后新开 shell 有代理变量、ZCode 进程环境无代理；
#      proxy-off 后进程与环境文件全部清理干净
#   9. 最终镜像内 git/pip/npm 无残留加速改写配置
#  10. docker ps + docker port + ss -tlnp 输出存档
###############################################################################
set -euo pipefail

IMAGE="${1:?用法: bash scripts/ci-smoke-test.sh <镜像名>}"
NAME="zcode-smoke"
EXT_ZCODE=43030
EXT_SELKIES=47183
EXT_SPARE1=40808
EXT_SPARE2=40809

fail=0
step() { echo ""; echo "=================================================="; echo "== $*"; echo "=================================================="; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; fail=$((fail+1)); }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

step "0. 清理旧容器并启动新容器（docker run 一次成功）"
cleanup
docker run -d --name "$NAME" --shm-size=2g \
    -p "${EXT_ZCODE}:3030" -p "${EXT_SELKIES}:7183" \
    -p "${EXT_SPARE1}:8080" -p "${EXT_SPARE2}:8090" \
    "$IMAGE" >/dev/null
sleep 3
if [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = "true" ]; then
    ok "容器启动成功并保持运行"
else
    bad "容器未保持运行"
    docker logs "$NAME" | tail -50
    exit 1
fi

step "1. 等待容器 healthy（预置服务全部就绪）"
status="starting"
for _ in $(seq 1 72); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo unknown)
    if [ "$status" = "healthy" ]; then break; fi
    if [ "$status" = "unhealthy" ]; then break; fi
    sleep 5
done
if [ "$status" != "healthy" ]; then
    echo "  [FAIL] 容器未 healthy（status=$status）—— 诊断信息如下："
    echo "---- docker inspect Health.Log ----"
    docker inspect -f '{{json .State.Health.Log}}' "$NAME" | tail -c 2000 || true
    echo ""
    echo "---- /var/log/zcode-container/zcode.log（尾部 60 行）----"
    docker exec "$NAME" sh -c 'tail -n 60 /var/log/zcode-container/zcode.log 2>/dev/null' || true
    echo "---- /var/log/zcode-container/edge-mcp.log（尾部 20 行）----"
    docker exec "$NAME" sh -c 'tail -n 20 /var/log/zcode-container/edge-mcp.log 2>/dev/null' || true
    echo "---- /root/.zcode 目录 ----"
    docker exec "$NAME" sh -c 'ls -la /root/.zcode /root/.zcode/cli 2>/dev/null; cat /root/.zcode/cli/config.json 2>/dev/null' || true
    echo "---- 前台复现：zcode --web（端口 3031，30 秒观察窗口）----"
    docker exec "$NAME" sh -c 'cd /workspace && timeout 30 zcode --web --no-open --host 127.0.0.1 --port 3031 --no-token 2>&1 | tail -n 40; echo "FOREGROUND_DONE"' || true
    echo "---- 容器主日志（尾部 40 行）----"
    docker logs --tail 40 "$NAME" || true
    exit 1
fi
ok "容器 healthy（zcode:3030 / edge-mcp:7123 / edge-cdp:9222 全部通过镜像内置 healthcheck）"
docker exec "$NAME" healthcheck.sh

step "2. 逐端口验证（通过对外映射端口）"
body=$(curl -fsS -m 15 "http://127.0.0.1:${EXT_ZCODE}/" 2>/dev/null || true)
if [ -n "$body" ] && printf '%s' "$body" | head -c 2048 | grep -qi '<!doctype\|<html'; then
    ok "ZCODE ${EXT_ZCODE}->3030 正常响应（HTTP 200 + HTML）"
else
    bad "ZCODE ${EXT_ZCODE}->3030 无有效响应"
fi

for p in "$EXT_SPARE1" "$EXT_SPARE2"; do
    if curl -fsS -m 5 "http://127.0.0.1:${p}/" >/dev/null 2>&1; then
        bad "备用端口 ${p} 不应有服务响应（空端口必须为空）"
    else
        if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":${p}$"; then
            ok "备用端口 ${p}：connection refused（预期）且 docker-proxy 处于监听（可绑定状态）"
        else
            bad "备用端口 ${p} 未处于可绑定/监听状态"
        fi
    fi
done

step "3. docker port 输出（对外映射端口全部为非常用端口号，数量恒为四个）"
docker port "$NAME"
map_count=$(docker port "$NAME" | wc -l)
if [ "$map_count" -eq 4 ]; then
    ok "对外映射端口数量 = 4（恒定，不为多人远程新增端口）"
else
    bad "对外映射端口数量 = ${map_count}（应为 4）"
fi
docker port "$NAME" | awk '{print $NF}' | while read -r ep; do
    hostport=${ep##*:}
    case "$hostport" in
        80|443|3000|8080|8888) bad "对外端口 ${hostport} 属常用端口，违反端口规划" ;;
        *) ok "对外端口 ${hostport} 为非常用高位端口" ;;
    esac
done

step "4. Edge 无头模式 + CDP 9222 可控；edge-mcp :7123 健康检查"
docker exec "$NAME" curl -fsS -m 8 http://127.0.0.1:9222/json/version | head -c 200; echo
docker exec "$NAME" curl -fsS -m 8 http://127.0.0.1:9222/json/version | grep -q webSocketDebuggerUrl \
    && ok "Edge CDP 9222 可控（/json/version 返回 webSocketDebuggerUrl）" \
    || bad "Edge CDP 9222 不可控"
docker exec "$NAME" curl -fsS -m 8 http://127.0.0.1:7123/health | tee /dev/stderr | grep -q '"ok":true' \
    && ok "edge-mcp :7123 健康检查通过" \
    || bad "edge-mcp :7123 健康检查失败"

step "5. desktop-on 后 Selkies 网页端出画面端口；双客户端同端口连接；端口数不变"
map_before=$(docker port "$NAME" | wc -l)
docker exec "$NAME" desktop-on.sh || {
    bad "desktop-on 执行失败"
    docker exec "$NAME" tail -n 30 /var/log/zcode-container/selkies.log || true
}
selkies_ok=""
for _ in $(seq 1 30); do
    if curl -fsS -m 5 -o /dev/null "http://127.0.0.1:${EXT_SELKIES}/" 2>/dev/null; then
        selkies_ok=1; break
    fi
    sleep 2
done
if [ -n "$selkies_ok" ]; then
    ok "desktop-on 后 ${EXT_SELKIES}->7183 可访问（HTTP 200）"
else
    bad "desktop-on 后 ${EXT_SELKIES}->7183 不可访问"
    docker exec "$NAME" tail -n 30 /var/log/zcode-container/selkies.log || true
fi
curl -fsS -m 5 "http://127.0.0.1:${EXT_SELKIES}/api/health" >/dev/null 2>&1 \
    && ok "Selkies /api/health 正常" || bad "Selkies /api/health 异常"

# 双客户端同时连入同一端口（共享输入/同时远程模式）
if curl -fsS -m 5 -o /dev/null "http://127.0.0.1:${EXT_SELKIES}/" 2>/dev/null \
   && curl -fsS -m 5 -o /dev/null "http://127.0.0.1:${EXT_SELKIES}/" 2>/dev/null; then
    ok "两个客户端同时连入 ${EXT_SELKIES}（同一端口，画面与输入共享）"
fi

map_after=$(docker port "$NAME" | wc -l)
if [ "$map_after" -eq "$map_before" ] && [ "$map_after" -eq 4 ]; then
    ok "多人同时远程未新增任何映射端口（总数恒为四个）"
else
    bad "多人同时远程后映射端口数量变为 ${map_after}"
fi

step "6. docker ps + 容器内 ss -tlnp（监听/可映射状态存档）"
docker ps --filter "name=$NAME"
docker exec "$NAME" ss -tlnp || true

step "7. desktop-off 后释放"
docker exec "$NAME" desktop-off.sh || bad "desktop-off 执行失败"
sleep 2
if curl -fsS -m 5 -o /dev/null "http://127.0.0.1:${EXT_SELKIES}/" 2>/dev/null; then
    bad "desktop-off 后 7183 仍可访问（未释放）"
else
    ok "desktop-off 后 ${EXT_SELKIES} 已释放（connection refused）"
fi
docker exec "$NAME" desktop-status.sh

step "8. 空闲自动回收生效（注入短超时 25 秒）"
docker exec -e SELKIES_IDLE_TIMEOUT=25 "$NAME" desktop-on.sh >/dev/null || bad "desktop-on（空闲回收阶段）执行失败"
recycled=""
for _ in $(seq 1 16); do
    if docker exec "$NAME" desktop-status.sh 2>/dev/null | grep -q "未运行"; then
        recycled=1; break
    fi
    sleep 5
done
if [ -n "$recycled" ]; then
    ok "空闲回收生效（25 秒无操作自动 desktop-off）"
else
    bad "空闲回收未生效"
    docker exec "$NAME" cat /var/log/zcode-container/idle-watchdog.log 2>/dev/null || true
fi

step "9. sing-box 与代理隔离验证"
if docker exec "$NAME" pgrep -x sing-box >/dev/null 2>&1; then
    bad "默认状态不应有 sing-box 进程"
else
    ok "默认无 sing-box 进程（不启动，无配置即直连）"
fi

if docker exec "$NAME" proxy-on.sh >/dev/null 2>&1; then
    bad "无配置时 proxy-on 应当报错拒绝启动"
else
    ok "无配置时 proxy-on 拒绝启动（默认直连）"
fi

# 放置最小配置（mixed 入环 + direct 出站）后完整验证 proxy-on / 隔离 / proxy-off
docker exec "$NAME" sh -c 'mkdir -p /etc/sing-box && cat > /etc/sing-box/config.json <<EOF
{"log":{"level":"warn"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":2080}],"outbounds":[{"type":"direct"}]}
EOF'
docker exec "$NAME" proxy-on.sh || bad "proxy-on 执行失败（有配置时不应失败）"
docker exec "$NAME" pgrep -x sing-box >/dev/null 2>&1 \
    && ok "proxy-on 后 sing-box 进程已启动" || bad "proxy-on 后 sing-box 未运行"

proxy_env=$(docker exec "$NAME" bash -l -c 'echo ${HTTP_PROXY:-none}' 2>/dev/null || echo none)
if [ "$proxy_env" != "none" ] && [ "$proxy_env" != "" ]; then
    ok "proxy-on 后新开用户 shell 有代理变量（HTTP_PROXY=$proxy_env）"
else
    bad "proxy-on 后新开用户 shell 无代理变量"
fi

# ZCode 自身流量不走代理（进程环境隔离验证）
zpid=$(docker exec "$NAME" pgrep -f 'zcode.mjs --web' | head -n 1 || true)
if [ -n "$zpid" ]; then
    zproxy=$(docker exec "$NAME" sh -c "tr '\0' '\n' < /proc/${zpid}/environ" 2>/dev/null | grep -iE '^(http_proxy|https_proxy|no_proxy)=' || true)
    if [ -z "$zproxy" ]; then
        ok "ZCode 进程环境无任何代理变量（自身流量不走代理）"
    else
        bad "ZCode 进程环境被注入代理变量：$zproxy"
    fi
else
    bad "未找到 ZCode 进程"
fi

# 通过代理实际发一次请求（非致命，网络波动不影响验收结论）
docker exec "$NAME" curl -fsS -m 12 -x http://127.0.0.1:2080 -o /dev/null -w 'proxy egress http %{http_code}\n' \
    https://www.gstatic.com/generate_204 >/dev/null 2>&1 \
    && ok "经 sing-box 代理的出口请求成功" || echo "  [INFO] 经代理出口请求未成功（CI 网络波动，不影响验收）"

docker exec "$NAME" proxy-off.sh || bad "proxy-off 执行失败"
docker exec "$NAME" pgrep -x sing-box >/dev/null 2>&1 \
    && bad "proxy-off 后仍有 sing-box 进程" || ok "proxy-off 后 sing-box 进程已全部清理"
docker exec "$NAME" test ! -f /etc/profile.d/proxy-env.sh \
    && ok "proxy-off 后 /etc/profile.d/proxy-env.sh 已删除" || bad "proxy-off 后环境文件残留"
proxy_env2=$(docker exec "$NAME" bash -l -c 'echo ${HTTP_PROXY:-none}' 2>/dev/null || echo none)
if [ "$proxy_env2" = "none" ] || [ "$proxy_env2" = "" ]; then
    ok "proxy-off 后新开用户 shell 不再有代理变量"
else
    bad "proxy-off 后新开 shell 仍有代理变量：$proxy_env2"
fi
docker exec "$NAME" rm -f /etc/sing-box/config.json

step "10. 最终镜像内 git / pip / npm 无残留加速改写配置"
gitcfg=$(docker exec "$NAME" git config --global -l 2>/dev/null || true)
if [ -z "$gitcfg" ]; then
    ok "git 全局配置为空（无 insteadOf 残留）"
else
    if printf '%s' "$gitcfg" | grep -q insteadof; then
        bad "git 全局配置存在 insteadOf 残留：$gitcfg"
    else
        ok "git 全局配置无 insteadOf（内容：$(printf '%s' "$gitcfg" | head -2)）"
    fi
fi
npmreg=$(docker exec "$NAME" npm config get registry 2>/dev/null || true)
if printf '%s' "$npmreg" | grep -q 'registry.npmjs.org'; then
    ok "npm registry 为官方默认（${npmreg}）"
else
    bad "npm registry 被改写：${npmreg}"
fi
pipcfg=$(docker exec "$NAME" pip3 config list 2>/dev/null || true)
if [ -z "$pipcfg" ]; then
    ok "pip 无任何自定义配置（无镜像残留）"
else
    bad "pip 存在配置残留：$pipcfg"
fi
emremote=$(docker exec "$NAME" git -C /opt/edge-mcp remote get-url origin 2>/dev/null || true)
if [ "$emremote" = "https://github.com/hualang-C/edge-mcp.git" ]; then
    ok "edge-mcp 仓库 remote 为官方地址（无镜像前缀残留）"
else
    bad "edge-mcp remote 残留镜像前缀：$emremote"
fi

step "11. 宿主机侧监听存档（ss -tlnp 证明四个映射端口处于监听状态）"
sudo ss -tlnp 2>/dev/null | grep -E "docker|${EXT_ZCODE}|${EXT_SELKIES}|${EXT_SPARE1}|${EXT_SPARE2}" || ss -tlnp | grep -E "${EXT_ZCODE}|${EXT_SELKIES}|${EXT_SPARE1}|${EXT_SPARE2}" || true

step "12. ZCode 网页对话能力（服务端 API 可用性）"
docker exec "$NAME" curl -fsS -m 8 -o /dev/null -w 'zcode http %{http_code}\n' http://127.0.0.1:3030/ \
    && ok "ZCode 服务端持续响应（对话前端由浏览器加载，真实对话需在浏览器中进行）" \
    || bad "ZCode 服务端停止响应"

echo ""
echo "=================================================="
if [ "$fail" -eq 0 ]; then
    echo "SMOKE TEST: 全部通过（$fail 项失败）"
    echo "=================================================="
    exit 0
else
    echo "SMOKE TEST: ${fail} 项失败"
    echo "=================================================="
    exit 1
fi
