#!/bin/sh
set -e

echo "========================================"
echo "  OpenClaw Full Docker Container"
echo "  Gateway + ClawPanel Web 管理面板"
echo "========================================"
echo ""

# 检查 OpenClaw CLI
if ! command -v openclaw >/dev/null 2>&1; then
  echo "[ERROR] openclaw CLI not found!"
  exit 1
fi

# 显示版本信息
echo "[INFO] OpenClaw version: $(openclaw --version 2>/dev/null || echo 'unknown')"
echo "[INFO] Node.js version: $(node --version)"
echo "[INFO] Gateway port: ${GATEWAY_PORT:-18789}"
echo "[INFO] Panel port: ${PANEL_PORT:-1420}"
echo ""

# 初始化配置
CONFIG_FILE="/root/.openclaw/openclaw.json"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[INIT] 首次启动，初始化 OpenClaw 配置..."
  openclaw init 2>/dev/null || true

  if [ ! -f "$CONFIG_FILE" ]; then
    echo "[INIT] 创建默认配置..."
    mkdir -p /root/.openclaw
    cat > "$CONFIG_FILE" <<EOF
{
  "gateway": {
    "mode": "local",
    "host": "0.0.0.0",
    "port": ${GATEWAY_PORT:-18789},
    "auth": { "mode": "none" },
    "controlUi": {
      "allowedOrigins": ["*"],
      "allowInsecureAuth": true
    }
  },
  "tools": {
    "profile": "full",
    "sessions": { "visibility": "all" }
  }
}
EOF
  fi
  echo "[INIT] 配置已初始化: $CONFIG_FILE"
else
  echo "[INFO] 使用已有配置: $CONFIG_FILE"
fi

# 确保 Gateway 监听 0.0.0.0
if ! grep -q '"host"' "$CONFIG_FILE" 2>/dev/null; then
  sed -i 's/"mode": "local"/"mode": "local",\n    "host": "0.0.0.0"/' "$CONFIG_FILE" 2>/dev/null || true
fi

# 1. 后台启动 Gateway
echo "[START] 启动 Gateway..."
openclaw gateway start &
GATEWAY_PID=$!

# 等待 Gateway 就绪
echo "[WAIT] 等待 Gateway 就绪..."
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:${GATEWAY_PORT:-18789}/health >/dev/null 2>&1 || \
     curl -sf http://127.0.0.1:${GATEWAY_PORT:-18789}/ >/dev/null 2>&1; then
    echo "[OK] Gateway 已就绪"
    break
  fi
  if [ "$i" = "30" ]; then
    echo "[WARN] Gateway 未在 30 秒内就绪，Panel 仍将启动"
  fi
  sleep 1
done

# 2. 前台启动 ClawPanel Web
echo ""
echo "[START] 启动 ClawPanel Web 面板..."
echo "----------------------------------------"
echo ""
echo "  🌐 管理面板: http://0.0.0.0:${PANEL_PORT:-1420}"
echo "  🔌 Gateway:  ws://0.0.0.0:${GATEWAY_PORT:-18789}/ws"
echo ""
echo "----------------------------------------"

cd /app

# 捕获信号，优雅退出
cleanup() {
  echo ""
  echo "[STOP] 收到退出信号，正在停止服务..."
  openclaw gateway stop 2>/dev/null || true
  kill "$GATEWAY_PID" 2>/dev/null || true
  exit 0
}
trap cleanup TERM INT QUIT

# 前台启动 Panel（npm run serve 是静态服务器）
exec node scripts/serve.js
