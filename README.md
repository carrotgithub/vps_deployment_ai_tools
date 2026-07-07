# HongBox（洪盒）— AI-native server deployment toolkit

> **版本**: v4.0.0
> **更新日期**: 2026-07-07
> **许可证**: MIT

HongBox 是洪哥出品的 AI 原生服务器部署工具。它把传统终端菜单改造成适合 AI agents 调用的 `plan → preflight → apply → status/doctor` 工作流：人负责在对话里确认目标和风险，AI 负责生成部署 profile、检查环境、执行明确的参数化命令。

---

## ✨ 特性

- 🤖 **AI 协作部署**：AI 通过 profile/参数驱动部署，不依赖终端菜单输入
- 🧭 **计划先行**：`plan` 只生成变更计划，`preflight` 只检查环境，确认后才 `apply`
- 🔒 **安全基线**：fail2ban、swap、日志限制、TLS 1.2+，自动 SSL 证书
- 📦 **零依赖**：纯 Bash 实现，兼容 Debian/Ubuntu，无需安装额外运行时
- 🧩 **模块化**：每个服务可独立安装，也可通过总入口一键部署
- 🐳 **Compose 优先**：CPA / New-API 默认采用 Docker Compose，CPA 保留裸机安装选项

---

## 🚀 快速开始

### AI 协作部署（推荐）

```bash
git clone https://github.com/YoungHong1992/hong-ai-box.git
cd hong-ai-box

cat > deploy.env <<'EOF'
HONGBOX_SERVICES="maintenance,nginx,docker,new-api"
HONGBOX_ACCESS_MODE="domain"
HONGBOX_NEWAPI_DOMAIN="api.example.com"
HONGBOX_DB_TYPE="postgresql"
EOF

./hongbox plan --profile deploy.env
./hongbox preflight --profile deploy.env
sudo ./hongbox apply --profile deploy.env --yes
```

> 建议由 AI agent 先和你确认服务、域名、数据库、风险项，再生成 `deploy.env`。`apply` 必须显式传入 `--yes` 或设置 `HONGBOX_CONFIRM_APPLY=yes` 才会修改系统。

### 下载完整包安装

```bash
curl -fsSLO https://github.com/YoungHong1992/hong-ai-box/releases/latest/download/hong-ai-box.tar.gz
tar xzf hong-ai-box.tar.gz
cd hong-ai-box
./hongbox plan --services new-api --domain api.example.com
```

### 远程入口

```bash
curl -fsSL https://raw.githubusercontent.com/YoungHong1992/hong-ai-box/main/install.sh | bash
```

> 无参数运行只显示帮助，不进入终端菜单。请使用 release 包或完整仓库中的 `hongbox` 执行 `plan/preflight/apply/status/doctor`。

### 单独安装某个服务

在完整仓库内，每个组件目录都保留统一命名的 `install.sh`，供 `hongbox apply` 非交互调用；组件脚本会复用仓库内 `lib/` 公共库，请不要只复制单个组件脚本运行。

```bash
cd maintenance && sudo ./install.sh        # 安装服务器维护基线
cd ../nginx && sudo ./install.sh           # 安装 Nginx
cd ../docker && sudo ./install.sh          # 安装 Docker
cd ../cliproxyapi && sudo ./install.sh     # 安装 CliproxyAPI（默认 Docker Compose）
# CPA 裸机安装：cd ../cliproxyapi && sudo HONGAIBOX_CLIPROXY_DEPLOY_MODE=bare ./install.sh
cd ../new-api && sudo ./install.sh         # 安装 New-API
cd ../pi-coding-agent && sudo ./install.sh # 安装 Pi
```

> CliproxyAPI / New-API 需要已安装 Nginx；默认 Docker Compose 部署还需要 Docker + Compose。缺少依赖时，对应脚本会提示先安装依赖后再继续。CPA 如需裸机二进制 + Systemd，可设置 `HONGAIBOX_CLIPROXY_DEPLOY_MODE=bare`。

---

## 📁 项目结构

```
hong-ai-box/
├── hongbox                     # AI-friendly CLI wrapper
├── install.sh                  # 🎯 总入口：部署常用 AI 组件
├── lib/                        # 公共 Bash 工具库（凭据写入等）
├── maintenance/                # 服务器维护基线 (fail2ban / swap / 日志限制)
├── nginx/                      # Nginx (HTTP/3 + BBR)
├── docker/                     # Docker Engine + Compose
├── cliproxyapi/                # 轻量 AI API 转发代理
├── new-api/                    # AI 模型网关
├── pi-coding-agent/            # 终端 AI 编程助手
├── codex-skills/               # Codex Skill：AI 协作部署封装
├── docs/                       # 辅助文档
├── tests/                      # 静态检查、凭据与集成测试脚本
└── README.md
```

---

## 📦 组件说明

| 组件 | 描述 | 资源需求 |
|------|------|----------|
| **Maintenance** | fail2ban、swap、journald 限制、Docker 日志轮转 | 基础维护 |
| **Nginx** | HTTP/3 (QUIC) + BBR 优化，所有服务的基础设施 | 512MB 内存 |
| **Docker** | Docker Engine + Compose 插件 | 无额外需求 |
| **CliproxyAPI** | 轻量 AI API 转发代理，默认 Docker Compose，可选裸机 | 256MB 内存 |
| **New-API** | AI 模型网关与资产管理系统，Docker Compose | ≥ 1GB 内存 |
| **Pi** | 终端 AI 编程助手 | 500MB 磁盘 |

---

## 🛠 AI 工作流

```
1. 问询 → AI 和用户确认目标服务、域名、数据库、部署方式
2. Profile → AI 生成 deploy.env 或等价 CLI 参数
3. Plan → ./hongbox plan 输出将安装什么、依赖顺序和系统改动
4. Preflight → ./hongbox preflight 检查 OS、权限、DNS、端口、脚本完整性
5. Apply → 用户确认后 sudo ./hongbox apply --yes 非交互执行
6. Status/Doctor → ./hongbox status / doctor 检查部署状态并辅助排障
```

> 同时部署 CliproxyAPI 与 New-API 时，请为每个 Web 服务准备独立域名，避免多个服务争用同一个 Nginx `server_name` 和 `/` 路由。

### CLI 命令

```bash
./hongbox plan --services new-api --domain api.example.com
./hongbox preflight --profile deploy.env
sudo ./hongbox apply --profile deploy.env --yes
./hongbox status
./hongbox doctor --profile deploy.env
```

### Codex Skill

仓库内置 `codex-skills/hongbox-deploy`，用于让 Codex 按 HongBox 的安全流程部署服务。它不会绕过确认机制：agent 应先运行 `plan` 和 `preflight`，在你确认后才执行 `apply --yes`。

Profile 支持的常用变量：

```bash
HONGBOX_SERVICES="maintenance,nginx,docker,cliproxyapi,new-api,pi"
HONGBOX_ACCESS_MODE="domain"       # domain | ip | http
HONGBOX_DOMAIN="api.example.com"   # 单个 Web 服务时可用
HONGBOX_CLIPROXY_DOMAIN="cpa.example.com"
HONGBOX_NEWAPI_DOMAIN="api.example.com"
HONGBOX_CLIPROXY_MODE="docker"     # docker | bare
HONGBOX_DB_TYPE="postgresql"       # postgresql | mysql
HONGBOX_CONFIRM_APPLY="yes"        # 等价于 apply --yes
```

---

## 🔒 安全说明

- 所有密码和密钥使用加密安全随机数生成
- SSL/TLS 最低版本: TLSv1.2
- 安装日志自动记录到 `/var/log/vps-deploy/`
- fail2ban 默认启用 SSH 防暴力破解
- swap 自动按内存配置，降低小内存 VPS OOM 风险
- journald / Docker 日志轮转限制磁盘占用
- Nginx 配置先备份再覆盖
- 支持域名（Let's Encrypt）和 IP（自签名）两种证书模式

---

## 🧪 开发

### 本地测试

```bash
# 安装 shellcheck
apt-get install -y shellcheck

# 静态检查 + 仓库测试
./tests/run.sh

# 真实安装幂等测试（会修改当前机器维护基线，建议只在 CI/临时机执行）
sudo ./tests/test-maintenance-idempotency.sh
```

---

**最后更新**: 2026-07-07
