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

# ── 面板访问密码（可选） ──────────────────────
PANEL_CONFIG="$DATA_DIR/clawpanel.json"
if [ -n "$PANEL_PASSWORD" ]; then
  echo "[INIT] 设置面板访问密码..."
  node -e "
    const fs = require('fs');
    const p = '$PANEL_CONFIG';
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(p, 'utf8')); } catch {}
    cfg.accessPassword = process.env.PANEL_PASSWORD;
    fs.writeFileSync(p, JSON.stringify(cfg, null, 2));
  " && echo "[INIT] ✓ 面板密码已设置" || echo "[WARN] 面板密码设置失败"
fi

# ── 环境变量注入模型配置（可选） ──────────────
# docker run -e OPENAI_API_KEY=sk-xxx ...
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

# ── 启动 Gateway（后台） ─────────────────────
echo ""
echo "[START] 启动 Gateway..."
# openclaw gateway 直接运行 gateway 进程（不是 start 子命令）
openclaw gateway &
GATEWAY_PID=$!

echo "[WAIT] 等待 Gateway 就绪 (PID: $GATEWAY_PID)..."
READY=false
for i in $(seq 1 30); do
  # 先检查进程还活着
  if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
    echo "[ERROR] Gateway 进程已退出，请检查配置"
    echo "[ERROR] 日志: cat /root/.openclaw/logs/gateway.log"
    break
  fi
  if curl -sf http://127.0.0.1:${GATEWAY_PORT:-18789}/health >/dev/null 2>&1 || \
     curl -sf http://127.0.0.1:${GATEWAY_PORT:-18789}/ >/dev/null 2>&1; then
    echo "[OK] ✓ Gateway 已就绪"
    READY=true
    break
  fi
  sleep 1
done
[ "$READY" = "false" ] && echo "[WARN] Gateway 未在 30 秒内就绪，Panel 仍将启动"

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
