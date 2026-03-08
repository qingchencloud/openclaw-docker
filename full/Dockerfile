# OpenClaw Full — Gateway + ClawPanel Web 一体镜像
# 基于汉化版预构建镜像，叠加 ClawPanel Web 管理面板
#
# 构建：docker build -t qingchencloud/openclaw:latest -f full/Dockerfile .
# 运行：docker run -d -p 1420:1420 -p 18789:18789 -v openclaw-data:/root/.openclaw qingchencloud/openclaw

# ── 第一阶段：构建 ClawPanel Web ──
FROM node:22-slim AS panel-builder

ARG CLAWPANEL_REPO=https://github.com/qingchencloud/clawpanel.git
ARG CLAWPANEL_BRANCH=main
ARG NPM_REGISTRY=https://registry.npmmirror.com

WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && \
    rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${CLAWPANEL_BRANCH} ${CLAWPANEL_REPO} . && \
    NODE_ENV=development npm ci --registry "$NPM_REGISTRY" && \
    npm run build && \
    rm -rf .git node_modules src-tauri docs

# ── 第二阶段：基于汉化版镜像，叠加 Panel ──
# 版本锁定：见 VERSION 文件
ARG OPENCLAW_ZH_TAG=2026.3.7-zh.2
FROM 1186258278/openclaw-zh:${OPENCLAW_ZH_TAG}

LABEL maintainer="qingchencloud <https://github.com/qingchencloud>"
LABEL org.opencontainers.image.title="OpenClaw"
LABEL org.opencontainers.image.description="OpenClaw AI 助手平台 — Gateway + Web 管理面板，开箱即用"
LABEL org.opencontainers.image.source="https://github.com/qingchencloud/openclaw-docker"
LABEL org.opencontainers.image.url="https://github.com/qingchencloud/openclaw-docker"

# 环境变量
ENV GATEWAY_PORT=18789 \
    PANEL_PORT=1420 \
    PANEL_PASSWORD="" \
    NODE_ENV=production \
    TZ=Asia/Shanghai

# 安装运行时依赖（基础镜像可能缺少 tini、curl 等）
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl tini ca-certificates iproute2 lsof procps && \
    rm -rf /var/lib/apt/lists/* || true

# 复制 ClawPanel Web 构建产物
WORKDIR /app
COPY --from=panel-builder /build/dist ./dist
COPY --from=panel-builder /build/scripts ./scripts
COPY --from=panel-builder /build/package.json ./

# 初始化配置目录
RUN mkdir -p /root/.openclaw

# 数据卷
VOLUME ["/root/.openclaw"]

# 暴露端口
EXPOSE ${PANEL_PORT} ${GATEWAY_PORT}

# 健康检查（检查 Panel）
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -f http://127.0.0.1:${PANEL_PORT}/ 2>/dev/null || exit 1

# 入口
COPY full/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["tini", "--"]
CMD ["/entrypoint.sh"]
