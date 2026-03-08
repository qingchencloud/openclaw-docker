# OpenClaw Gateway — 轻量级 AI 助手网关
# 仅包含 Gateway 服务，适合与外部 Panel 搭配使用
#
# 构建：docker build -t qingchencloud/openclaw:gateway -f gateway/Dockerfile .
# 运行：docker run -d -p 18789:18789 -v openclaw-data:/root/.openclaw qingchencloud/openclaw:gateway

FROM node:22-slim

LABEL maintainer="qingchencloud <https://github.com/qingchencloud>"
LABEL org.opencontainers.image.title="OpenClaw Gateway"
LABEL org.opencontainers.image.description="OpenClaw AI Gateway — 轻量级容器化部署"
LABEL org.opencontainers.image.source="https://github.com/qingchencloud/openclaw-docker"
LABEL org.opencontainers.image.url="https://github.com/qingchencloud/openclaw-docker"

# 构建参数
ARG OPENCLAW_SOURCE=zh
ARG OPENCLAW_VERSION=latest
ARG NPM_REGISTRY=https://registry.npmmirror.com

# 环境变量
ENV OPENCLAW_SOURCE=${OPENCLAW_SOURCE} \
    OPENCLAW_VERSION=${OPENCLAW_VERSION} \
    NPM_REGISTRY=${NPM_REGISTRY} \
    GATEWAY_PORT=18789 \
    NODE_ENV=production \
    TZ=Asia/Shanghai

# 安装基础工具
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git tini ca-certificates && \
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

# 初始化配置目录
RUN mkdir -p /root/.openclaw

# 数据卷
VOLUME ["/root/.openclaw"]

# 暴露端口
EXPOSE ${GATEWAY_PORT}

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://127.0.0.1:${GATEWAY_PORT}/health 2>/dev/null || \
      curl -f http://127.0.0.1:${GATEWAY_PORT}/ 2>/dev/null || exit 1

# 入口
COPY gateway/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["tini", "--"]
CMD ["/entrypoint.sh"]
