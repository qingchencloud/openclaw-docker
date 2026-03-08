# OpenClaw Full — Gateway + ClawPanel Web 一体镜像
# 包含 OpenClaw Gateway 和 ClawPanel Web 管理面板
#
# 构建：docker build -t qingchencloud/openclaw:latest -f full/Dockerfile .
# 运行：docker run -d -p 1420:1420 -p 18789:18789 -v openclaw-data:/root/.openclaw qingchencloud/openclaw

FROM node:22-slim

LABEL maintainer="qingchencloud <https://github.com/qingchencloud>"
LABEL org.opencontainers.image.title="OpenClaw"
LABEL org.opencontainers.image.description="OpenClaw AI 助手平台 — Gateway + Web 管理面板，开箱即用"
LABEL org.opencontainers.image.source="https://github.com/qingchencloud/openclaw-docker"
LABEL org.opencontainers.image.url="https://github.com/qingchencloud/openclaw-docker"

# 构建参数
ARG OPENCLAW_SOURCE=zh
ARG OPENCLAW_VERSION=latest
ARG NPM_REGISTRY=https://registry.npmmirror.com
ARG CLAWPANEL_REPO=https://github.com/qingchencloud/clawpanel.git
ARG CLAWPANEL_BRANCH=main

# 环境变量
ENV OPENCLAW_SOURCE=${OPENCLAW_SOURCE} \
    OPENCLAW_VERSION=${OPENCLAW_VERSION} \
    NPM_REGISTRY=${NPM_REGISTRY} \
    GATEWAY_PORT=18789 \
    PANEL_PORT=1420 \
    PANEL_PASSWORD="" \
    NODE_ENV=production \
    TZ=Asia/Shanghai

# 安装基础工具（ss 用于服务状态检测，lsof 做 fallback）
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git tini ca-certificates iproute2 lsof procps && \
    rm -rf /var/lib/apt/lists/*

# 安装 OpenClaw
RUN if [ "$OPENCLAW_SOURCE" = "zh" ]; then \
      PKG="@qingchencloud/openclaw-zh"; \
    else \
      PKG="openclaw"; \
    fi && \
    if [ "$OPENCLAW_VERSION" = "latest" ]; then \
      npm install -g "$PKG" --registry "$NPM_REGISTRY"; \
    else \
      npm install -g "${PKG}@${OPENCLAW_VERSION}" --registry "$NPM_REGISTRY"; \
    fi && \
    npm cache clean --force

# 安装 ClawPanel Web
WORKDIR /app
RUN git clone --depth 1 --branch ${CLAWPANEL_BRANCH} ${CLAWPANEL_REPO} . && \
    npm ci --registry "$NPM_REGISTRY" && \
    npm run build && \
    # serve.js + dev-api.js 只依赖 Node.js 内置模块，运行时不需要 node_modules
    rm -rf .git node_modules src-tauri docs

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
