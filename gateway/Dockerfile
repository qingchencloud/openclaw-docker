# OpenClaw Gateway — 轻量级 AI 助手网关
# 基于汉化版预构建镜像，仅包含 Gateway 服务
#
# 构建：docker build -t qingchencloud/openclaw:latest-gateway -f gateway/Dockerfile .
# 运行：docker run -d -p 18789:18789 -v openclaw-data:/root/.openclaw qingchencloud/openclaw:latest-gateway

# 版本锁定：见 VERSION 文件
ARG OPENCLAW_ZH_TAG=2026.3.7-zh.2
FROM 1186258278/openclaw-zh:${OPENCLAW_ZH_TAG}

LABEL maintainer="qingchencloud <https://github.com/qingchencloud>"
LABEL org.opencontainers.image.title="OpenClaw Gateway"
LABEL org.opencontainers.image.description="OpenClaw AI Gateway — 轻量级容器化部署（汉化版）"
LABEL org.opencontainers.image.source="https://github.com/qingchencloud/openclaw-docker"
LABEL org.opencontainers.image.url="https://github.com/qingchencloud/openclaw-docker"

# 环境变量
ENV GATEWAY_PORT=18789 \
    NODE_ENV=production \
    TZ=Asia/Shanghai

# 安装运行时依赖（基础镜像可能缺少 tini、curl）
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl tini ca-certificates && \
    rm -rf /var/lib/apt/lists/* || true

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
