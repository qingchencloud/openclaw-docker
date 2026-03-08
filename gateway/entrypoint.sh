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
# 支持通过 ENV 预配置模型，用户无需手动编辑
# 用法：docker run -e OPENAI_API_KEY=sk-xxx -e OPENAI_BASE_URL=https://api.openai.com/v1 ...
if [ -n "$OPENAI_API_KEY" ]; then
  echo "[INIT] 检测到 OPENAI_API_KEY，自动配置 OpenAI 模型渠道..."
  BASE_URL="${OPENAI_BASE_URL:-https://api.openai.com/v1}"
  # 使用 node 操作 JSON（比 sed 可靠）
  node -e "
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
    if (!cfg.models) cfg.models = {};
    if (!cfg.models.providers) cfg.models.providers = {};
    cfg.models.providers['openai'] = {
      name: 'OpenAI',
      baseUrl: '$BASE_URL',
      apiKey: '$OPENAI_API_KEY',
      models: ['gpt-4o', 'gpt-4o-mini', 'o1', 'o1-mini', 'o3-mini']
    };
    fs.writeFileSync('$CONFIG_FILE', JSON.stringify(cfg, null, 2));
  " 2>/dev/null && echo "[INIT] ✓ OpenAI 渠道已配置" || echo "[WARN] OpenAI 渠道配置失败，请通过面板手动配置"
fi

if [ -n "$ANTHROPIC_API_KEY" ]; then
  echo "[INIT] 检测到 ANTHROPIC_API_KEY，自动配置 Anthropic 模型渠道..."
  BASE_URL="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
  node -e "
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
    if (!cfg.models) cfg.models = {};
    if (!cfg.models.providers) cfg.models.providers = {};
    cfg.models.providers['anthropic'] = {
      name: 'Anthropic',
      baseUrl: '$BASE_URL',
      apiKey: '$ANTHROPIC_API_KEY',
      models: ['claude-sonnet-4-20250514', 'claude-3-5-haiku-20241022']
    };
    fs.writeFileSync('$CONFIG_FILE', JSON.stringify(cfg, null, 2));
  " 2>/dev/null && echo "[INIT] ✓ Anthropic 渠道已配置" || echo "[WARN] Anthropic 渠道配置失败，请通过面板手动配置"
fi

# 通用 OpenAI 兼容渠道（适用于各种第三方 API）
if [ -n "$CUSTOM_API_KEY" ] && [ -n "$CUSTOM_BASE_URL" ]; then
  CUSTOM_NAME="${CUSTOM_PROVIDER_NAME:-Custom}"
  CUSTOM_MODELS="${CUSTOM_MODEL_LIST:-gpt-4o,gpt-4o-mini}"
  echo "[INIT] 检测到 CUSTOM_API_KEY，自动配置 ${CUSTOM_NAME} 渠道..."
  node -e "
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
    if (!cfg.models) cfg.models = {};
    if (!cfg.models.providers) cfg.models.providers = {};
    cfg.models.providers['custom'] = {
      name: '$CUSTOM_NAME',
      baseUrl: '$CUSTOM_BASE_URL',
      apiKey: '$CUSTOM_API_KEY',
      models: '$CUSTOM_MODELS'.split(',').map(s => s.trim())
    };
    fs.writeFileSync('$CONFIG_FILE', JSON.stringify(cfg, null, 2));
  " 2>/dev/null && echo "[INIT] ✓ ${CUSTOM_NAME} 渠道已配置" || echo "[WARN] ${CUSTOM_NAME} 渠道配置失败"
fi

# ── 启动 Gateway ──────────────────────────────
echo ""
echo "────────────────────────────────────────"
echo "  🚀 启动 Gateway（前台模式）"
echo "  🔌 ws://0.0.0.0:${GATEWAY_PORT:-18789}/ws"
echo "────────────────────────────────────────"
echo ""

exec openclaw gateway start --foreground
