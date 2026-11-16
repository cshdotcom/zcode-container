#!/usr/bin/env bash
###############################################################################
# mcp-register-edge：向 ZCode 的 MCP 配置（/root/.zcode/cli/config.json）注册
# edge-mcp HTTP 服务（http://127.0.0.1:7123/mcp）。
#
# 镜像内置了同名种子配置；当 /root/.zcode 是外部挂载且为空时，或用户想恢复
# 注册时，执行本脚本即可（JSON 合并，不破坏已有其他配置项）。
###############################################################################
set -euo pipefail

CONF="${ZCODE_CONFIG_PATH:-/root/.zcode/cli/config.json}"
URL="${EDGE_MCP_URL:-http://127.0.0.1:7123/mcp}"

mkdir -p "$(dirname "$CONF")"

node - "$CONF" "$URL" <<'EOF'
const fs = require("fs");
const [confPath, url] = process.argv.slice(2);
let conf = {};
try { conf = JSON.parse(fs.readFileSync(confPath, "utf8")); } catch { conf = {}; }
conf.mcp = conf.mcp && typeof conf.mcp === "object" ? conf.mcp : {};
conf.mcp.servers = conf.mcp.servers && typeof conf.mcp.servers === "object" ? conf.mcp.servers : {};
conf.mcp.servers.edge = { type: "http", url };
fs.writeFileSync(confPath, JSON.stringify(conf, null, 2) + "\n");
console.log(`已注册 edge-mcp -> ${url}`);
console.log(`配置文件: ${confPath}`);
EOF

echo "验证: curl -s http://127.0.0.1:7123/health"
