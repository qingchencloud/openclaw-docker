#!/bin/sh
set -e

echo "╔════════════════════════════════════════╗"
echo "║   OpenClaw Full Docker Container       ║"
echo "║   Gateway + ClawPanel Web 管理面板     ║"
echo "╚════════════════════════════════════════╝"
echo ""

# ── 环境检查 ──────────────────────────────────
if ! command -v openclaw >/dev/null 2>&1; then
  echo "[ERROR] openclaw CLI not found!"
  exit 1
fi

echo "[INFO] OpenClaw : $(openclaw --version 2>/dev/null || echo 'unknown')"
echo "[INFO] Node.js  : $(node --version)"
echo "[INFO] Gateway  : :${GATEWAY_PORT:-18789}"
echo "[INFO] Panel    : :${PANEL_PORT:-1420}"
echo ""

# ── 配置初始化 ────────────────────────────────
DATA_DIR="/root/.openclaw"
CONFIG_FILE="$DATA_DIR/openclaw.json"
mkdir -p "$DATA_DIR"

FIRST_RUN=false
if [ ! -f "$CONFIG_FILE" ]; then
  FIRST_RUN=true
  echo "[INIT] 首次启动，生成默认配置..."
  openclaw init 2>/dev/null || true

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
  echo "[INIT] ✓ 配置已生成"
else
  echo "[INFO] 使用已有配置: $CONFIG_FILE"
fi

# ── 确保 Docker 友好配置 ──────────────────────
if ! grep -q '"host"' "$CONFIG_FILE" 2>/dev/null; then
  sed -i 's/"mode": "local"/"mode": "local",\n    "host": "0.0.0.0"/' "$CONFIG_FILE" 2>/dev/null || true
fi
if ! grep -q '"allowedOrigins"' "$CONFIG_FILE" 2>/dev/null; then
  sed -i 's/"controlUi": {/"controlUi": { "allowedOrigins": ["*"],/' "$CONFIG_FILE" 2>/dev/null || true
fi

# ── 环境变量注入模型配置（可选） ──────────────
# docker run -e OPENAI_API_KEY=sk-xxx ...
if [ -n "$OPENAI_API_KEY" ]; then
  echo "[INIT] 自动配置 OpenAI 模型渠道..."
  BASE_URL="${OPENAI_BASE_URL:-https://api.openai.com/v1}"
  node -e "
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
    if (!cfg.models) cfg.models = {};
    if (!cfg.models.providers) cfg.models.providers = {};
    cfg.models.providers['openai'] = {
      name: 'OpenAI', baseUrl: '$BASE_URL', apiKey: '$OPENAI_API_KEY',
      models: ['gpt-4o', 'gpt-4o-mini', 'o1', 'o1-mini', 'o3-mini']
    };
    fs.writeFileSync('$CONFIG_FILE', JSON.stringify(cfg, null, 2));
  " 2>/dev/null && echo "[INIT] ✓ OpenAI 已配置" || echo "[WARN] OpenAI 配置失败"
fi

if [ -n "$ANTHROPIC_API_KEY" ]; then
  echo "[INIT] 自动配置 Anthropic 模型渠道..."
  BASE_URL="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
  node -e "
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
    if (!cfg.models) cfg.models = {};
    if (!cfg.models.providers) cfg.models.providers = {};
    cfg.models.providers['anthropic'] = {
      name: 'Anthropic', baseUrl: '$BASE_URL', apiKey: '$ANTHROPIC_API_KEY',
      models: ['claude-sonnet-4-20250514', 'claude-3-5-haiku-20241022']
    };
    fs.writeFileSync('$CONFIG_FILE', JSON.stringify(cfg, null, 2));
  " 2>/dev/null && echo "[INIT] ✓ Anthropic 已配置" || echo "[WARN] Anthropic 配置失败"
fi

# 通用 OpenAI 兼容渠道（第三方 API / 中转站）
if [ -n "$CUSTOM_API_KEY" ] && [ -n "$CUSTOM_BASE_URL" ]; then
  CUSTOM_NAME="${CUSTOM_PROVIDER_NAME:-Custom}"
  CUSTOM_MODELS="${CUSTOM_MODEL_LIST:-gpt-4o,gpt-4o-mini}"
  echo "[INIT] 自动配置 ${CUSTOM_NAME} 渠道..."
  node -e "
    const fs = require('fs');
    const cfg = JSON.parse(fs.readFileSync('$CONFIG_FILE', 'utf8'));
    if (!cfg.models) cfg.models = {};
    if (!cfg.models.providers) cfg.models.providers = {};
    cfg.models.providers['custom'] = {
      name: '$CUSTOM_NAME', baseUrl: '$CUSTOM_BASE_URL', apiKey: '$CUSTOM_API_KEY',
      models: '$CUSTOM_MODELS'.split(',').map(s => s.trim())
    };
    fs.writeFileSync('$CONFIG_FILE', JSON.stringify(cfg, null, 2));
  " 2>/dev/null && echo "[INIT] ✓ ${CUSTOM_NAME} 已配置" || echo "[WARN] ${CUSTOM_NAME} 配置失败"
fi

# ── 启动 Gateway（后台） ─────────────────────
echo ""
echo "[START] 启动 Gateway..."
openclaw gateway start &
GATEWAY_PID=$!

echo "[WAIT] 等待 Gateway 就绪..."
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:${GATEWAY_PORT:-18789}/health >/dev/null 2>&1 || \
     curl -sf http://127.0.0.1:${GATEWAY_PORT:-18789}/ >/dev/null 2>&1; then
    echo "[OK] ✓ Gateway 已就绪"
    break
  fi
  [ "$i" = "30" ] && echo "[WARN] Gateway 未在 30 秒内就绪，Panel 仍将启动"
  sleep 1
done

# ── 启动 ClawPanel Web（前台） ────────────────
echo ""
echo "════════════════════════════════════════"
echo "  🌐 管理面板: http://0.0.0.0:${PANEL_PORT:-1420}"
echo "  🔌 Gateway:  ws://0.0.0.0:${GATEWAY_PORT:-18789}/ws"
if [ "$FIRST_RUN" = "true" ]; then
  echo ""
  echo "  📝 首次使用：打开面板 → 模型管理 → 添加 API Key"
fi
echo "════════════════════════════════════════"
echo ""

cd /app

# 优雅退出
cleanup() {
  echo ""
  echo "[STOP] 正在停止服务..."
  openclaw gateway stop 2>/dev/null || true
  kill "$GATEWAY_PID" 2>/dev/null || true
  exit 0
}
trap cleanup TERM INT QUIT

exec node scripts/serve.js
