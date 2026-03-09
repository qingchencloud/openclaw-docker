#!/usr/bin/env node
/**
 * ClawPanel Agent — 容器内专属军团控制代理
 *
 * 设计原则：
 *   - 从容器内部 localhost 连接 Gateway，无需设备配对
 *   - 所有输出走 NDJSON (stdout)，一行一个 JSON
 *   - 由 ClawPanel 通过 docker exec 调用
 *
 * 用法:
 *   node /app/clawpanel-agent.js '{"cmd":"status"}'
 *   node /app/clawpanel-agent.js '{"cmd":"task.run","message":"翻译这段话"}'
 *   node /app/clawpanel-agent.js '{"cmd":"config.sync","config":{...}}'
 *   node /app/clawpanel-agent.js '{"cmd":"workspace.seed","files":{"SOUL.md":"..."}}'
 *
 * 支持命令:
 *   status         — Gateway 健康检查 + 配置/工作区状态
 *   config.sync    — 写入 openclaw.json
 *   workspace.seed — 写入工作区文件 (SOUL.md, IDENTITY.md, AGENTS.md, ...)
 *   task.run       — 通过 Gateway WS 发送聊天消息并流式返回结果
 *   gateway.restart — 重启 Gateway 进程
 */

const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const net = require('net');
const { execSync, spawn } = require('child_process');

const DATA_DIR = process.env.OPENCLAW_DATA || '/root/.openclaw';
const CONFIG_FILE = path.join(DATA_DIR, 'openclaw.json');
const GW_PORT = parseInt(process.env.GATEWAY_PORT || '18789');
const SCOPES = ['operator.admin', 'operator.approvals', 'operator.pairing', 'operator.read', 'operator.write'];

// ──────────────────────────────────────────────
// NDJSON 输出
// ──────────────────────────────────────────────

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function stripThinkingTags(text) {
  return String(text || '')
    .replace(/<\s*think(?:ing)?\s*>[\s\S]*?<\s*\/\s*think(?:ing)?\s*>/gi, '')
    .replace(/Conversation info \(untrusted metadata\):\s*```json[\s\S]*?```\s*/gi, '')
    .replace(/\[Queued messages while agent was busy\]\s*---\s*Queued #\d+\s*/gi, '')
    .trim();
}

function extractChatText(message) {
  if (!message || typeof message !== 'object') return '';
  const content = message.content;
  if (typeof content === 'string') return stripThinkingTags(content);
  if (Array.isArray(content)) {
    const texts = [];
    for (const block of content) {
      if (block?.type === 'text' && typeof block.text === 'string') {
        texts.push(block.text);
      }
    }
    return stripThinkingTags(texts.join('\n'));
  }
  if (typeof message.text === 'string') return stripThinkingTags(message.text);
  return '';
}

// ──────────────────────────────────────────────
// 配置读取
// ──────────────────────────────────────────────

function readConfig() {
  try { return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')); }
  catch { return null; }
}

function getToken() {
  const config = readConfig();
  return config?.gateway?.auth?.token || '';
}

async function connectGatewayClient() {
  const socket = await wsConnect(GW_PORT);

  const rawChallenge = await wsReadFrame(socket, 8000);
  const challenge = JSON.parse(rawChallenge);
  if (challenge.event !== 'connect.challenge') {
    throw new Error('unexpected: ' + (challenge.event || 'no event'));
  }

  wsSendFrame(socket, JSON.stringify({
    type: 'req',
    id: 'connect-1',
    method: 'connect',
    params: {
      minProtocol: 3,
      maxProtocol: 3,
      client: {
        id: 'openclaw-control-ui',
        version: '1.0.0',
        platform: 'linux',
        deviceFamily: 'desktop',
        mode: 'ui',
      },
      role: 'operator',
      scopes: SCOPES,
      caps: [],
      auth: { token: getToken() },
      locale: 'zh-CN',
      userAgent: 'ClawPanel-Agent/1.0.0',
    },
  }));

  const rawConnect = await wsReadFrame(socket, 8000);
  const connectResp = JSON.parse(rawConnect);
  if (!connectResp.ok) {
    throw new Error(connectResp.error?.message || '握手被拒绝');
  }

  return {
    socket,
    defaults: connectResp.payload?.snapshot?.sessionDefaults || {},
  };
}

async function wsWaitForResponse(socket, id, timeout = 8000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const raw = await wsReadFrame(socket, Math.max(1, deadline - Date.now()));
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      continue;
    }
    if (msg.type !== 'res' || msg.id !== id) continue;
    if (msg.ok) return msg.payload;
    const err = new Error(msg.error?.message || msg.error?.code || `${id} failed`);
    if (msg.error?.code) err.code = msg.error.code;
    throw err;
  }
  throw new Error(`response timeout: ${id}`);
}

async function gatewayRequest(method, params, timeout = 8000) {
  const requestId = `${method}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const { socket } = await connectGatewayClient();
  try {
    wsSendFrame(socket, JSON.stringify({
      type: 'req',
      id: requestId,
      method,
      params,
    }));
    return await wsWaitForResponse(socket, requestId, timeout);
  } finally {
    try { socket.destroy(); } catch {}
  }
}

function findLatestAssistantText(messages, startedAtMs = 0) {
  if (!Array.isArray(messages)) return '';
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const candidate = messages[i];
    if (!candidate || typeof candidate !== 'object') continue;
    if (candidate.role !== 'assistant') continue;
    const timestamp = Number(candidate.timestamp);
    if (Number.isFinite(timestamp) && startedAtMs > 0 && timestamp + 2000 < startedAtMs) continue;
    const text = extractChatText(candidate);
    if (text) return text;
  }
  return '';
}

async function waitForAssistantText(sessionKey, startedAtMs, timeoutMs) {
  const deadline = Date.now() + Math.max(1000, timeoutMs);
  while (Date.now() < deadline) {
    const remaining = deadline - Date.now();
    try {
      const history = await gatewayRequest('chat.history', {
        sessionKey,
        limit: 50,
      }, Math.min(10000, remaining + 1000));
      const text = findLatestAssistantText(history?.messages, startedAtMs);
      if (text) return text;
    } catch {}
    if (remaining <= 0) break;
    await new Promise(resolve => setTimeout(resolve, Math.min(300, remaining)));
  }
  return '';
}

async function waitForRunStatus(runId, timeoutMs) {
  if (!runId) return { status: '' };
  const safeTimeout = Math.max(1000, Math.floor(timeoutMs));
  try {
    const response = await gatewayRequest('agent.wait', {
      runId,
      timeoutMs: safeTimeout,
    }, safeTimeout + 5000);
    return response && typeof response === 'object' ? response : { status: '' };
  } catch (e) {
    return { status: 'error', error: e.message || String(e) };
  }
}

// ──────────────────────────────────────────────
// TCP 健康检查
// ──────────────────────────────────────────────

function tcpCheck(port, timeout = 3000) {
  return new Promise((resolve, reject) => {
    const sock = net.connect({ host: '127.0.0.1', port, timeout });
    sock.on('connect', () => { sock.destroy(); resolve(true); });
    sock.on('timeout', () => { sock.destroy(); reject(new Error('timeout')); });
    sock.on('error', (e) => reject(e));
  });
}

// ──────────────────────────────────────────────
// Raw WebSocket 工具（支持 Origin header）
// ──────────────────────────────────────────────

function wsConnect(port) {
  return new Promise((resolve, reject) => {
    const key = crypto.randomBytes(16).toString('base64');
    const req = http.request({
      hostname: '127.0.0.1', port, path: '/ws', method: 'GET',
      headers: {
        'Connection': 'Upgrade', 'Upgrade': 'websocket',
        'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': key,
        'Origin': 'http://127.0.0.1',
      },
    });
    req.on('upgrade', (_, socket) => resolve(socket));
    req.on('response', (res) => {
      let d = ''; res.on('data', c => d += c);
      res.on('end', () => reject(new Error(`HTTP ${res.statusCode}: ${d.slice(0, 200)}`)));
    });
    req.on('error', reject);
    req.setTimeout(5000, () => { req.destroy(); reject(new Error('ws connect timeout')); });
    req.end();
  });
}

function wsReadFrame(socket, timeout = 8000) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const cleanup = () => {
      clearTimeout(t);
      socket.removeListener('data', onData);
      socket.removeListener('error', onError);
      socket.removeListener('close', onClose);
    };
    const finish = (fn) => (value) => {
      if (settled) return;
      settled = true;
      cleanup();
      fn(value);
    };
    const t = setTimeout(finish(reject), timeout, new Error('ws read timeout'));
    let buf = Buffer.alloc(0);
    const onData = (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      if (buf.length < 2) return;
      let len = buf[1] & 0x7f, off = 2;
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
      if (buf.length < off + len) return;
      finish(resolve)(buf.slice(off, off + len).toString('utf8'));
    };
    const onError = finish(reject);
    const onClose = finish(reject);
    socket.on('data', onData);
    socket.on('error', onError);
    socket.on('close', () => onClose(new Error('ws closed')));
  });
}

function wsSendFrame(socket, text) {
  const p = Buffer.from(text, 'utf8'), mask = crypto.randomBytes(4);
  let h;
  if (p.length < 126) { h = Buffer.alloc(2); h[0] = 0x81; h[1] = 0x80 | p.length; }
  else { h = Buffer.alloc(4); h[0] = 0x81; h[1] = 0x80 | 126; h.writeUInt16BE(p.length, 2); }
  const m = Buffer.alloc(p.length);
  for (let i = 0; i < p.length; i++) m[i] = p[i] ^ mask[i % 4];
  socket.write(Buffer.concat([h, mask, m]));
}

function wsReadLoop(socket, onMessage, timeoutMs = 120000) {
  let buf = Buffer.alloc(0), done = false;
  const timer = setTimeout(() => { done = true; socket.destroy(); }, timeoutMs);
  const cancel = () => { done = true; clearTimeout(timer); try { socket.destroy(); } catch {} };
  socket.on('data', (chunk) => {
    if (done) return;
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 2) {
      const opcode = buf[0] & 0x0f;
      let len = buf[1] & 0x7f, off = 2;
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
      if (buf.length < off + len) return;
      const payload = buf.slice(off, off + len);
      buf = buf.slice(off + len);
      if (opcode === 0x08) { done = true; clearTimeout(timer); socket.destroy(); return; }
      if (opcode === 0x09) { // ping → pong
        const pmask = crypto.randomBytes(4);
        const ph = Buffer.alloc(2); ph[0] = 0x8A; ph[1] = 0x80 | payload.length;
        const pm = Buffer.alloc(payload.length);
        for (let i = 0; i < payload.length; i++) pm[i] = payload[i] ^ pmask[i % 4];
        try { socket.write(Buffer.concat([ph, pmask, pm])); } catch {}
        continue;
      }
      if (opcode === 0x01) onMessage(payload.toString('utf8'));
    }
  });
  socket.on('error', () => { done = true; clearTimeout(timer); });
  socket.on('close', () => { done = true; clearTimeout(timer); });
  return cancel;
}

// ──────────────────────────────────────────────
// 命令: status
// ──────────────────────────────────────────────

async function handleStatus() {
  const config = readConfig();
  const gwOk = await tcpCheck(GW_PORT).then(() => true).catch(() => false);
  const hasModels = config?.models && Object.keys(config.models).length > 0;

  const wsDir = path.join(DATA_DIR, 'workspace');
  const wsFiles = {};
  for (const f of ['SOUL.md', 'IDENTITY.md', 'AGENTS.md']) {
    wsFiles[f] = fs.existsSync(path.join(wsDir, f));
  }

  // 读取容器 hostname 作为标识
  let hostname = '';
  try { hostname = fs.readFileSync('/etc/hostname', 'utf8').trim(); } catch {}

  emit({
    type: 'result', ok: true,
    data: {
      hostname,
      gateway: { running: gwOk, port: GW_PORT },
      config: { exists: !!config, hasModels, hasAuth: !!config?.gateway?.auth?.token },
      workspace: wsFiles,
      agent: { version: '1.0.0' },
    },
  });
}

// ──────────────────────────────────────────────
// 命令: config.sync
// ──────────────────────────────────────────────

async function handleConfigSync(cmd) {
  const config = cmd.config;
  if (!config) { emit({ type: 'error', message: 'config is required' }); return; }

  fs.mkdirSync(DATA_DIR, { recursive: true });
  fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));

  emit({ type: 'result', ok: true, data: { synced: true } });
}

// ──────────────────────────────────────────────
// 命令: workspace.seed
// ──────────────────────────────────────────────

async function handleWorkspaceSeed(cmd) {
  const files = cmd.files;
  if (!files || typeof files !== 'object') { emit({ type: 'error', message: 'files object required' }); return; }

  const wsDir = path.join(DATA_DIR, 'workspace');
  fs.mkdirSync(wsDir, { recursive: true });

  const written = [];
  for (const [name, content] of Object.entries(files)) {
    // 安全检查：只允许写工作区内的文件
    const safeName = path.basename(name);
    fs.writeFileSync(path.join(wsDir, safeName), content);
    written.push(safeName);
  }

  emit({ type: 'result', ok: true, data: { written } });
}

// ──────────────────────────────────────────────
// 命令: gateway.restart
// ──────────────────────────────────────────────

async function handleGatewayRestart() {
  try {
    // 杀掉旧进程
    try { execSync('pkill -f "openclaw gateway" 2>/dev/null; pkill -f openclaw-gateway 2>/dev/null', { timeout: 3000 }); } catch {}
    await new Promise(r => setTimeout(r, 1000));

    // 启动新的 Gateway（后台运行，不依赖当前 exec 会话）
    fs.mkdirSync(path.join(DATA_DIR, 'logs'), { recursive: true });
    const gw = spawn('sh', ['-c', 'exec openclaw gateway >> /root/.openclaw/logs/gateway.log 2>&1'], {
      detached: true, stdio: 'ignore',
    });
    gw.unref();

    // 等待 Gateway 启动
    let ready = false;
    for (let i = 0; i < 10; i++) {
      await new Promise(r => setTimeout(r, 1000));
      try { await tcpCheck(GW_PORT, 2000); ready = true; break; } catch {}
    }

    emit({ type: 'result', ok: ready, data: { restarted: true, ready } });
  } catch (e) {
    emit({ type: 'error', message: `Gateway 重启失败: ${e.message}` });
  }
}

// ──────────────────────────────────────────────
// 命令: task.run — 核心：通过 Gateway WS 执行任务
// ──────────────────────────────────────────────

async function handleTaskRun(cmd) {
  const { message, sessionKey: reqSessionKey, timeout = 120000 } = cmd;
  if (!message) { emit({ type: 'error', message: 'message is required' }); return; }
  const startedAtMs = Date.now();
  const runTimeoutMs = Math.max(1000, Math.min(timeout, 60000));

  // 1. 检查 Gateway
  try { await tcpCheck(GW_PORT); }
  catch {
    emit({ type: 'error', code: 'GATEWAY_DOWN', message: 'Gateway 未运行' });
    return;
  }

  // 2. 连接 WebSocket（localhost，含重试）
  let socket;
  let defaults = {};
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const connected = await connectGatewayClient();
      socket = connected.socket;
      defaults = connected.defaults || {};
      break;
    } catch (e) {
      if (attempt === 3) {
        emit({ type: 'error', code: 'WS_CONNECT_FAIL', message: `WS 连接失败: ${e.message}` });
        return;
      }
      await new Promise(r => setTimeout(r, attempt * 1000));
    }
  }

  // 获取 sessionKey
  const sessionKey = reqSessionKey || defaults?.mainSessionKey || `agent:${defaults?.defaultAgentId || 'main'}:task`;

  emit({ type: 'connected', sessionKey });

  // 3. 发起 agent 运行，拿到 runId 后走 agent.wait + chat.history 回拉正文
  const chatId = `task-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  let runId = chatId;
  try {
    wsSendFrame(socket, JSON.stringify({
      type: 'req',
      id: chatId,
      method: 'agent',
      params: {
        sessionKey,
        message,
        deliver: false,
        idempotencyKey: chatId,
        timeout: Math.max(1, Math.ceil(runTimeoutMs / 1000)),
      },
    }));
    const sendResp = await wsWaitForResponse(socket, chatId, Math.min(runTimeoutMs, 15000));
    if (typeof sendResp?.runId === 'string' && sendResp.runId.trim()) {
      runId = sendResp.runId.trim();
    }
    emit({ type: 'ack', runId });
  } catch (e) {
    try { socket.destroy(); } catch {}
    const errMsg = e.message || '任务发送失败';
    const code = (errMsg.includes('model') || errMsg.includes('no model')) ? 'NO_MODEL' : 'SEND_FAIL';
    emit({ type: 'error', code, message: errMsg });
    return;
  }

  try { socket.destroy(); } catch {}

  const waitBudgetMs = Math.max(1000, Math.min(runTimeoutMs + 5000, 65000));
  const waitState = await waitForRunStatus(runId, waitBudgetMs);

  const elapsedMs = Date.now() - startedAtMs;
  const remainingMs = Math.max(2000, runTimeoutMs - elapsedMs);
  const historyBudgetMs = Math.min(25000, remainingMs);
  const finalText = await waitForAssistantText(sessionKey, startedAtMs, historyBudgetMs);
  if (finalText) {
    emit({ type: 'final', text: finalText });
    return;
  }

  if (waitState?.status === 'error') {
    emit({
      type: 'error',
      code: 'AI_ERROR',
      message: waitState.error || '任务执行失败',
    });
    return;
  }

  if (waitState?.status === 'timeout') {
    try {
      await gatewayRequest('chat.abort', {
        sessionKey,
        runId,
      }, 10000);
    } catch {}
    emit({
      type: 'error',
      code: 'WAIT_TIMEOUT',
      message: '模型请求超时，任务已中止',
    });
    return;
  }

  emit({
    type: 'error',
    code: 'EMPTY_RESULT',
    message: '任务已结束，但未获取到回复文本',
  });
}

// ──────────────────────────────────────────────
// 主入口
// ──────────────────────────────────────────────

async function main() {
  const input = process.argv[2];
  if (!input) {
    emit({ type: 'error', message: 'usage: node clawpanel-agent.js \'{"cmd":"status"}\'' });
    process.exit(1);
  }

  let cmd;
  try { cmd = JSON.parse(input); }
  catch { emit({ type: 'error', message: 'invalid JSON input' }); process.exit(1); }

  try {
    switch (cmd.cmd) {
      case 'status':          await handleStatus(); break;
      case 'config.sync':     await handleConfigSync(cmd); break;
      case 'workspace.seed':  await handleWorkspaceSeed(cmd); break;
      case 'gateway.restart': await handleGatewayRestart(); break;
      case 'task.run':        await handleTaskRun(cmd); break;
      default:
        emit({ type: 'error', message: `unknown command: ${cmd.cmd}` });
        process.exit(1);
    }
  } catch (e) {
    emit({ type: 'error', message: e.message || String(e) });
    process.exit(1);
  }
}

main();
