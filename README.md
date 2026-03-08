# 🐳 OpenClaw Docker

开箱即用的 [OpenClaw](https://github.com/anthropics/anthropic-cookbook) AI 助手平台容器化部署方案。

一条命令启动，包含 Gateway + Web 管理面板，零配置即可使用。

## 快速启动

```bash
docker run -d \
  --name openclaw \
  --restart unless-stopped \
  -p 1420:1420 \
  -p 18789:18789 \
  -v openclaw-data:/root/.openclaw \
  ghcr.io/qingchencloud/openclaw:latest
```

打开浏览器访问 **http://localhost:1420** 即可使用。

## 镜像说明

| 镜像标签 | 内容 | 适用场景 |
|---------|------|---------|
| `latest` | Gateway + ClawPanel Web（汉化版） | 推荐，开箱即用 |
| `gateway` | 仅 Gateway（汉化版） | 已有管理面板，只需 Gateway |
| `official` | Gateway + ClawPanel Web（原版） | 使用 OpenClaw 原版 |
| `x.y.z` | 指定 OpenClaw 版本 | 固定版本部署 |

## Docker Compose 部署（推荐）

### 一体部署

```bash
# 下载配置文件
curl -fsSL https://raw.githubusercontent.com/qingchencloud/openclaw-docker/main/docker-compose.yml -o docker-compose.yml
curl -fsSL https://raw.githubusercontent.com/qingchencloud/openclaw-docker/main/.env.example -o .env

# 按需修改 .env 配置，然后启动
docker compose up -d
```

### 分离部署（Gateway + Panel 独立容器）

```bash
curl -fsSL https://raw.githubusercontent.com/qingchencloud/openclaw-docker/main/docker-compose.split.yml -o docker-compose.yml
docker compose up -d
```

适用于 Gateway 和 Panel 需要独立管理的生产环境。

## 配置

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `OPENCLAW_SOURCE` | `zh` | 版本源：`zh`=汉化版，`official`=原版 |
| `OPENCLAW_VERSION` | `latest` | OpenClaw 版本号 |
| `PANEL_PORT` | `1420` | Web 管理面板端口 |
| `GATEWAY_PORT` | `18789` | Gateway 端口 |
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm 镜像源 |
| `TZ` | `Asia/Shanghai` | 时区 |

### 数据持久化

所有数据存储在 `/root/.openclaw` 目录中，通过 Volume 持久化：

```bash
# Docker Volume（推荐）
-v openclaw-data:/root/.openclaw

# Bind Mount（方便直接查看文件）
-v ~/.openclaw:/root/.openclaw
```

| 文件/目录 | 说明 |
|-----------|------|
| `openclaw.json` | 主配置文件 |
| `mcp.json` | MCP 工具配置 |
| `logs/` | Gateway 日志 |
| `agents/` | Agent 数据 |
| `devices/` | 设备配对信息 |
| `backups/` | 配置备份 |

## 常用操作

```bash
# 查看状态
docker ps | grep openclaw

# 查看日志
docker logs -f openclaw

# 进入容器
docker exec -it openclaw sh

# 重启
docker restart openclaw

# 更新到最新版
docker pull ghcr.io/qingchencloud/openclaw:latest
docker compose up -d

# 停止并删除（数据不会丢失）
docker compose down
```

## 自定义构建

如需自定义镜像，可以 clone 本仓库：

```bash
git clone https://github.com/qingchencloud/openclaw-docker.git
cd openclaw-docker

# 构建一体镜像
docker build -t my-openclaw -f full/Dockerfile .

# 构建纯 Gateway 镜像
docker build -t my-openclaw-gateway -f gateway/Dockerfile .

# 指定版本构建
docker build -t my-openclaw \
  --build-arg OPENCLAW_VERSION=4.0.2 \
  --build-arg OPENCLAW_SOURCE=zh \
  -f full/Dockerfile .
```

## 架构

```
┌─── Docker Container ───────────────────────┐
│                                             │
│  ┌─────────────────────────────────────┐   │
│  │  ClawPanel Web (:1420)              │   │
│  │  配置管理 / 模型测试 / 日志查看      │   │
│  └──────────────┬──────────────────────┘   │
│                 │                           │
│  ┌──────────────▼──────────────────────┐   │
│  │  OpenClaw Gateway (:18789)          │   │
│  │  AI 模型代理 / 工具调用 / Agent     │   │
│  └─────────────────────────────────────┘   │
│                                             │
│  📁 /root/.openclaw  ← Volume 持久化       │
└─────────────────────────────────────────────┘
```

## Nginx 反向代理

```nginx
server {
    listen 80;
    server_name panel.yourdomain.com;

    location / {
        proxy_pass http://127.0.0.1:1420;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

> ⚠️ 必须配置 WebSocket 升级头，否则 Gateway 连接不可用。

## 常见问题

### Q: 首次打开面板是空白？

检查日志确认服务已启动：

```bash
docker logs openclaw
```

应看到 `Gateway 已就绪` 和 `启动 ClawPanel Web` 输出。

### Q: 如何更新 OpenClaw 版本？

```bash
# 方法一：重建镜像
docker compose build --no-cache && docker compose up -d

# 方法二：容器内更新
docker exec -it openclaw npm install -g @qingchencloud/openclaw-zh@latest
docker restart openclaw
```

### Q: 数据会丢失吗？

只要配置了 Volume 挂载，容器删除重建不会丢失数据。

### Q: 支持 ARM 架构吗？

支持。CI 自动构建 `linux/amd64` 和 `linux/arm64` 双架构镜像，适配 Apple Silicon Mac 和 ARM 服务器。

## 相关项目

- [ClawPanel](https://github.com/qingchencloud/clawpanel) — OpenClaw 可视化管理面板（桌面版 + Web 版）
- [OpenClaw 汉化版](https://www.npmjs.com/package/@qingchencloud/openclaw-zh) — 中文本地化

## License

MIT
