#!/bin/sh
set -e

echo "========================================"
echo "  OpenClaw Gateway Docker Container"
echo "========================================"
echo ""

# 检查 OpenClaw CLI 是否可用
if ! command -v openclaw >/dev/null 2>&1; then
  echo "[ERROR] openclaw CLI not found!"
  exit 1
fi

# 显示版本信息
echo "[INFO] OpenClaw version: $(openclaw --version 2>/dev/null || echo 'unknown')"
echo "[INFO] Node.js version: $(node --version)"
echo "[INFO] Gateway port: ${GATEWAY_PORT:-18789}"
echo ""

# 初始化配置（如果不存在）
CONFIG_FILE="/root/.openclaw/openclaw.json"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[INIT] 首次启动，初始化 OpenClaw 配置..."
  openclaw init 2>/dev/null || true

  # 写入 Docker 友好的默认配置
  if [ -f "$CONFIG_FILE" ]; then
    echo "[INIT] 配置已初始化: $CONFIG_FILE"
  else
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
else
  echo "[INFO] 使用已有配置: $CONFIG_FILE"
fi

# 确保 Gateway 监听 0.0.0.0（容器内必须）
# 如果配置中没有 host 字段，通过 sed 注入
if grep -q '"host"' "$CONFIG_FILE" 2>/dev/null; then
  echo "[INFO] Gateway host 已配置"
else
  echo "[INFO] 设置 Gateway 监听 0.0.0.0..."
  sed -i 's/"mode": "local"/"mode": "local",\n    "host": "0.0.0.0"/' "$CONFIG_FILE" 2>/dev/null || true
fi

echo ""
echo "[START] 启动 Gateway（前台模式）..."
echo "----------------------------------------"

# 前台运行 Gateway，便于 Docker 捕获日志和信号
exec openclaw gateway start --foreground
