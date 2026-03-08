#!/bin/sh
set -e

echo "╔════════════════════════════════════════╗"
echo "║   OpenClaw Gateway Docker Container    ║"
echo "╚════════════════════════════════════════╝"
echo ""

# ── 环境检查 ──────────────────────────────────
if ! command -v openclaw >/dev/null 2>&1; then
  echo "[ERROR] openclaw CLI not found!"
  exit 1
fi

echo "[INFO] OpenClaw : $(openclaw --version 2>/dev/null || echo 'unknown')"
echo "[INFO] Node.js  : $(node --version)"
echo "[INFO] Port     : ${GATEWAY_PORT:-18789}"
echo ""

# ── 配置初始化 ────────────────────────────────
DATA_DIR="/root/.openclaw"
CONFIG_FILE="$DATA_DIR/openclaw.json"
mkdir -p "$DATA_DIR"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "[INIT] 首次启动，生成默认配置..."

  # 先尝试 openclaw init（可能生成更完整的配置）
  openclaw init 2>/dev/null || true

  # 如果 openclaw init 没有生成配置，手动创建
  if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<'DEFAULTEOF'
{
  "$schema": "https://openclaw.ai/schema/config.json",
  "meta": { "lastTouchedVersion": "2026.1.1" },
  "models": { "providers": {} },
  "gateway": {
    "mode": "local",
    "host": "0.0.0.0",
    "port": 18789,
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
DEFAULTEOF
  fi
  echo "[INIT] ✓ 配置已生成: $CONFIG_FILE"
else
  echo "[INFO] 使用已有配置: $CONFIG_FILE"
fi

# ── 确保 Docker 友好配置 ──────────────────────
# 容器内必须监听 0.0.0.0，否则外部无法访问
if ! grep -q '"host"' "$CONFIG_FILE" 2>/dev/null; then
  echo "[INIT] 设置 Gateway 监听 0.0.0.0..."
  sed -i 's/"mode": "local"/"mode": "local",\n    "host": "0.0.0.0"/' "$CONFIG_FILE" 2>/dev/null || true
fi

# 确保 allowedOrigins 为 ["*"]（Docker 场景下不限制 origin）
if ! grep -q '"allowedOrigins"' "$CONFIG_FILE" 2>/dev/null; then
  echo "[INIT] 设置 allowedOrigins: [\"*\"]..."
  sed -i 's/"controlUi": {/"controlUi": { "allowedOrigins": ["*"],/' "$CONFIG_FILE" 2>/dev/null || true
fi

# ── 环境变量注入模型配置（可选） ──────────────
# 使用 process.env 读取，避免 shell 插值导致特殊字符问题
INJECT_SCRIPT=$(cat <<'INJECT_EOF'
const fs = require('fs');
const p = process.env.CONFIG_FILE;
const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
if (!cfg.models) cfg.models = {};
if (!cfg.models.providers) cfg.models.providers = {};

if (process.env.OPENAI_API_KEY) {
  cfg.models.providers['openai'] = {
    name: 'OpenAI',
    baseUrl: process.env.OPENAI_BASE_URL || 'https://api.openai.com/v1',
    apiKey: process.env.OPENAI_API_KEY,
    models: ['gpt-4o', 'gpt-4o-mini', 'o1', 'o1-mini', 'o3-mini']
  };
}
if (process.env.ANTHROPIC_API_KEY) {
  cfg.models.providers['anthropic'] = {
    name: 'Anthropic',
    baseUrl: process.env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com',
    apiKey: process.env.ANTHROPIC_API_KEY,
    models: ['claude-sonnet-4-20250514', 'claude-3-5-haiku-20241022']
  };
}
if (process.env.CUSTOM_API_KEY && process.env.CUSTOM_BASE_URL) {
  const models = (process.env.CUSTOM_MODEL_LIST || 'gpt-4o,gpt-4o-mini').split(',').map(s => s.trim());
  cfg.models.providers['custom'] = {
    name: process.env.CUSTOM_PROVIDER_NAME || 'Custom',
    baseUrl: process.env.CUSTOM_BASE_URL,
    apiKey: process.env.CUSTOM_API_KEY,
    models
  };
}

fs.writeFileSync(p, JSON.stringify(cfg, null, 2));
INJECT_EOF
)

if [ -n "$OPENAI_API_KEY" ] || [ -n "$ANTHROPIC_API_KEY" ] || { [ -n "$CUSTOM_API_KEY" ] && [ -n "$CUSTOM_BASE_URL" ]; }; then
  echo "[INIT] 注入模型渠道配置..."
  CONFIG_FILE="$CONFIG_FILE" node -e "$INJECT_SCRIPT" 2>/dev/null \
    && echo "[INIT] ✓ 模型渠道已配置" \
    || echo "[WARN] 模型渠道配置失败"
fi

# ── 启动 Gateway ──────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo "  🚀 启动 Gateway（前台模式）"
echo "  🔌 ws://0.0.0.0:${GATEWAY_PORT:-18789}/ws"
echo "────────────────────────────────────────"
echo ""

# openclaw gateway 直接运行（前台模式），Docker 管理进程生命周期
exec openclaw gateway
