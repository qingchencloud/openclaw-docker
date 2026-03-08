# OpenClaw Docker 规划文档

> 最后更新: 2026-03-09

## 一、现状分析

### 仓库位置
- **GitHub**: https://github.com/qingchencloud/openclaw-docker
- **本地路径**: `C:\Data\PC\openclaw-docker`

### 当前结构
```
openclaw-docker/
├── full/
│   ├── Dockerfile        # 一体镜像（Gateway + ClawPanel Web）
│   └── entrypoint.sh     # 启动脚本（Gateway后台 + Panel前台）
├── gateway/
│   ├── Dockerfile        # 纯 Gateway 轻量镜像
│   └── entrypoint.sh
├── docker-compose.yml         # 一体部署
├── docker-compose.split.yml   # 分离部署
├── README.md
└── LICENSE
```

### 存在的问题

| # | 问题 | 影响 |
|---|------|------|
| 1 | **没有 CI 工作流** | README 写了"CI 自动双推"，但 `.github/workflows/` 目录根本不存在 |
| 2 | **镜像未预构建** | 三个仓库（GHCR/腾讯云/DockerHub）都没有可用镜像，用户拉取报错 |
| 3 | **构建时才安装** | Dockerfile 在 `docker build` 时才 `npm install -g` + `git clone`，每次构建耗时 3-5 分钟，依赖网络 |
| 4 | **缺 `.env.example`** | README 引用了但文件不存在 |
| 5 | **无版本锁定** | `latest` 随时可能变，用户升级可能翻车 |
| 6 | **无自动更新机制** | OpenClaw/ClawPanel 发版后，Docker 镜像不会自动更新 |

### 当前构建流程（有问题的）
```
用户执行 docker run ghcr.io/qingchencloud/openclaw:latest
  → 镜像不存在 ❌
  → 用户只能 clone 仓库 → docker build → 等 3-5 分钟
  → 完全不是"开箱即用"
```

---

## 二、目标

**让用户真正一条命令就能跑起来：**
```bash
docker run -d -p 1420:1420 -p 18789:18789 \
  -v openclaw-data:/root/.openclaw \
  ghcr.io/qingchencloud/openclaw:latest
```
- 镜像预构建好，用户直接 `docker pull`
- 内置汉化稳定版 OpenClaw + 最新 ClawPanel
- 多架构支持（amd64 + arm64）
- 多仓库推送（GHCR + 腾讯云 + DockerHub）
- 版本追踪，自动跟进上游更新

---

## 三、改进方案

### 3.1 创建 CI 自动构建（最关键）

**文件**: `.github/workflows/build-push.yml`

**触发条件：**
| 触发方式 | 场景 |
|---------|------|
| `push tag v*` | 发布新版本时构建 |
| `workflow_dispatch` | 手动触发（调试/紧急发布） |
| `schedule: cron '0 4 * * 1'` | 每周一自动重建 latest（跟进上游） |

**构建矩阵：**
| 镜像 | Dockerfile | 标签 |
|------|-----------|------|
| 一体版 | `full/Dockerfile` | `latest`, `v1.2.3` |
| 纯 Gateway | `gateway/Dockerfile` | `latest-gateway`, `v1.2.3-gateway` |

**推送目标：**
| 仓库 | 地址 | Secrets |
|------|------|---------|
| GHCR | `ghcr.io/qingchencloud/openclaw` | 自动（GITHUB_TOKEN） |
| 腾讯云 TCR | `ccr.ccs.tencentyun.com/qingchencloud/openclaw` | `TCR_USERNAME` + `TCR_PASSWORD` |
| Docker Hub | `qingchencloud/openclaw` | `DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN` |

### 3.2 补充缺失文件

- `.env.example` — 环境变量模板
- `.github/workflows/build-push.yml` — CI 工作流

### 3.3 版本管理策略

**核心原则：锁定指定版本，不直接跟 latest，避免上游大改动导致翻车。**

汉化版镜像标签格式：`2026.3.7-zh.2`（日期-zh.序号）

```
Dockerfile 中锁定版本：
  FROM 1186258278/openclaw-zh:2026.3.7-zh.2   # ← 指定稳定版，不用 latest

版本更新流程：
  1. 汉化版发布新版本（如 2026.3.15-zh.1）
  2. 本地拉取新版本，测试确认稳定
  3. 更新 Dockerfile 中的版本号
  4. openclaw-docker 打 tag 推送
  5. CI 自动构建并推送新镜像

openclaw-docker 标签规则：
  - latest / latest-gateway     （滚动更新，指向最新稳定构建）
  - v1.0.0 / v1.0.0-gateway     （固定版本，用户可锁定）
```

**版本锁定文件**（新增 `VERSION` 文件，方便追踪）：
```
# VERSION
OPENCLAW_ZH_IMAGE=1186258278/openclaw-zh
OPENCLAW_ZH_TAG=2026.3.7-zh.2
CLAWPANEL_BRANCH=main
```

### 3.4 利用汉化版已有 Docker 镜像

**关键发现：** 汉化版仓库 https://github.com/1186258278/OpenClawChineseTranslation
已经有预构建的 Docker 镜像：

| 镜像 | 说明 |
|------|------|
| `1186258278/openclaw-zh:latest` (Docker Hub) | 纯 OpenClaw 汉化版 Gateway |
| `ghcr.io/1186258278/openclaw-zh:latest` (GHCR) | 同上 |

**改进方案：用汉化版镜像做基础，叠加 ClawPanel Web**

```dockerfile
# 之前（从头构建，慢）
FROM node:22-slim
RUN npm install -g @qingchencloud/openclaw-zh  # 慢，网络依赖
RUN git clone clawpanel && npm ci && npm run build  # 又慢

# 改进后（基于已有镜像，快）
FROM 1186258278/openclaw-zh:latest
# OpenClaw 已内置 ✓
# 只需要加 ClawPanel Web
COPY --from=builder /app/dist /app/dist
COPY scripts/serve.js /app/
```

**优势：**
| 对比项 | 当前（从头构建） | 改进后（基于汉化版镜像） |
|-------|------------------|----------------------|
| 构建时间 | 3-5 分钟 | < 30 秒 |
| 网络依赖 | npm + GitHub | 只拉基础镜像 |
| OpenClaw 版本 | 不确定 | 汉化版已测试的稳定版 |
| 一致性 | 每次构建可能不同 | 基于固定基础镜像 |
| 多架构 | 需自己交叉编译 | 汉化版已提供 amd64 + arm64 |

---

## 四、需要你配置的平台账号

### 4.1 Docker Hub
1. 访问 https://hub.docker.com/
2. 创建组织 `qingchencloud`（或用个人账号）
3. 创建仓库 `openclaw`（Public）
4. 生成 Access Token：Account Settings → Security → New Access Token
5. 在 `openclaw-docker` GitHub 仓库 Settings → Secrets 添加：
   - `DOCKERHUB_USERNAME` = 你的 Docker Hub 用户名
   - `DOCKERHUB_TOKEN` = 刚生成的 Token

### 4.2 腾讯云 TCR
1. 登录腾讯云控制台 → 容器镜像服务
2. 确认命名空间 `qingchencloud` 和仓库 `openclaw` 已创建
3. 获取访问凭证（用户名 + 密码）
4. 在 GitHub 仓库 Secrets 添加：
   - `TCR_USERNAME` = 腾讯云容器镜像用户名
   - `TCR_PASSWORD` = 密码

### 4.3 GHCR（GitHub Container Registry）
- 无需额外配置，CI 使用 `GITHUB_TOKEN` 自动推送
- 确保仓库 Settings → Actions → Workflow permissions 设为 **Read and write**

---

## 五、发版工作流

### 日常更新流程
```
1. OpenClaw 汉化版发布新版本（npm）
   或 ClawPanel 推送新代码（git）

2. 在 openclaw-docker 本地：
   - 更新 Dockerfile 中的版本号（如有需要）
   - 测试构建：docker build -t test -f full/Dockerfile .
   - 测试运行：docker run -p 1420:1420 -p 18789:18789 test

3. 确认无误后打 tag 推送：
   git tag v1.0.1
   git push origin v1.0.1

4. CI 自动：
   - 构建 amd64 + arm64 镜像
   - 推送到 GHCR + 腾讯云 + DockerHub
   - 更新 latest 标签
```

### 紧急修复
```
GitHub Actions → 手动触发 workflow_dispatch
  → 可选择性重建指定镜像
```

---

## 六、后续优化（可选）

| 优化项 | 说明 | 优先级 |
|-------|------|--------|
| Webhook 自动触发 | ClawPanel/OpenClaw-zh 发版时自动触发 Docker 重建 | 中 |
| 镜像瘦身 | 多阶段构建，去掉 git/build 工具，减小镜像体积 | 低 |
| 安全扫描 | CI 中加 Trivy/Snyk 扫描镜像漏洞 | 低 |
| 签名验证 | cosign 签名，用户可验证镜像来源 | 低 |

---

## 七、立即行动项

- [ ] 配置 Docker Hub 账号和仓库
- [ ] 配置腾讯云 TCR 凭证
- [ ] 在 GitHub 仓库添加 Secrets
- [ ] 创建 `.github/workflows/build-push.yml`
- [ ] 创建 `.env.example`
- [ ] 本地测试构建一次，确认镜像可用
- [ ] 打 tag v1.0.0，触发首次 CI 构建
- [ ] 验证三个仓库都有镜像可拉取
