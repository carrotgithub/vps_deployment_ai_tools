# VPS 集群部署工具

> **版本**: v3.0
> **更新日期**: 2026-02-23
> **许可证**: MIT

一套 VPS 集群自动化部署工具，用于构建 AI API 网关服务和代理节点。

---

## 目录

- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [项目结构](#项目结构)
- [组件说明](#组件说明)
- [部署架构](#部署架构)
- [常用命令](#常用命令)
- [常见问题](#常见问题)

---

## 环境要求

### 支持的操作系统

| 操作系统 | 版本 | 测试状态 |
|---------|------|---------|
| **Ubuntu** | 20.04 / 22.04 / 24.04 | ✅ 推荐 |
| **Debian** | 11 / 12 | ✅ 支持 |
| **CentOS Stream** | 9 | ✅ 支持 |

### 硬件要求

| 组件 | 最低配置 | 推荐配置 |
|------|---------|---------|
| **0.nginx** | 512MB 内存, 500MB 磁盘 | 1GB 内存, 2GB 磁盘 |
| **1.v2ray** | 512MB 内存 | 1GB 内存 |
| **2.cliproxyapi** | 256MB 内存 | 512MB 内存 |
| **3.new-api** | 1GB 内存 (Docker) | 2GB 内存 |

### 前置条件

- **Root 权限**: 所有脚本需要 root 用户执行
- **网络连接**: 需要访问 GitHub、Docker Hub 等
- **域名（可选）**: 申请 SSL 证书需要已解析的域名；也支持 IP 模式（自签名证书）和 HTTP 模式
- **端口开放**: 80 (HTTP), 443 (HTTPS)

---

## 快速开始

### 方式一：引导式部署（推荐）

```bash
cd vps_deployment_ai_tools
chmod +x deploy_cluster.sh
./deploy_cluster.sh
```

脚本按顺序引导完成各组件安装：Nginx → Docker → V2Ray → CliproxyAPI → New-API。

### 方式二：单独部署

```bash
# 仅部署 Nginx
cd 0.nginx && ./install_nginx.sh

# 仅部署 New-API（会自动安装 Docker）
cd 3.new-api && ./install_newapi_docker.sh
```

---

## 项目结构

```
vps_deployment_ai_tools/
├── deploy_cluster.sh              # 全流程部署引导脚本
├── README.md                      # 本文档
│
├── 0.nginx/                       # Nginx 基础设施（必选）
│   ├── install_nginx.sh
│   └── README.md
│
├── 01.docker/                     # Docker 容器环境（推荐）
│   ├── install_docker.sh
│   └── README.md
│
├── 1.v2ray/                       # V2Ray 代理节点
│   ├── install_v2ray.sh
│   ├── install_web.sh
│   └── README.md
│
├── 2.cliproxyapi/                 # CliproxyAPI 轻量代理
│   ├── install_cliproxyapi_v2.sh
│   └── README.md
│
├── 3.new-api/                     # New-API AI 网关
│   ├── install_newapi_docker.sh
│   ├── upgrade_newapi_docker.sh
│   ├── upgrade_newapi_alpha.sh
│   ├── uninstall_newapi_docker.sh
│   └── README.md
│
└── 8.service-monitor/             # 服务监控系统
    ├── install_monitor.sh
    ├── service_monitor.sh
    ├── send_email.sh
    └── README.md
```

---

## 组件说明

### 0.nginx - Nginx 基础设施【必选】

> **部署方式**: 源码编译

- Nginx 1.28.1 源码编译，支持 HTTP/3 (QUIC)
- 自动开启 TCP BBR，优化系统内核参数
- 构建模块化配置结构 (conf.d/)
- 编译 Stream 模块，支持四层代理

```bash
cd 0.nginx && ./install_nginx.sh
```

---

### 01.docker - Docker 容器环境【推荐】

> **部署方式**: 自动安装

- Docker Engine + Docker Compose 插件
- 自动修复 Debian/Ubuntu apt 源问题
- 官方脚本优先，失败后按发行版手动安装
- 支持直接运行和 `source` 引用两种模式

New-API 等 Docker 服务的前置依赖。

```bash
cd 01.docker && ./install_docker.sh
```

---

### 1.v2ray - V2Ray 代理节点

> **依赖**: 0.nginx | **部署方式**: 二进制 + Systemd

- WebSocket + TLS 传输，流量伪装为正常 HTTPS
- 自动生成随机 UUID 和 WebSocket 路径
- 内置静态伪装网站

```bash
cd 1.v2ray && ./install_v2ray.sh && ./install_web.sh
```

---

### 2.cliproxyapi - CliproxyAPI 轻量代理

> **依赖**: 0.nginx | **部署方式**: 二进制 + Systemd

- 轻量级 AI API 转发代理，资源占用极低（~50MB）
- 支持 OpenAI、Claude、Gemini 等主流 AI 模型 API
- 适合低配 VPS（内存 < 1GB）

```bash
cd 2.cliproxyapi && ./install_cliproxyapi_v2.sh
```

---

### 3.new-api - New-API AI 网关

> **依赖**: 0.nginx, Docker | **部署方式**: Docker Compose

- 新一代大模型网关与 AI 资产管理系统
- 支持 OpenAI、Claude、Gemini、Azure 等多种模型聚合
- 完整的用户管理、令牌分组、计费系统
- 技术栈：Docker Compose + PostgreSQL + Redis

```bash
cd 3.new-api && ./install_newapi_docker.sh
```

---

### 8.service-monitor - 服务监控系统

> **依赖**: 无 | **部署方式**: 纯 Bash

- 多维度监控：Systemd 服务、Docker 容器、HTTP 端点、系统资源
- 智能告警：状态变化检测，避免重复告警
- 邮件通知：支持 Gmail、QQ、163 等邮箱

```bash
cd 8.service-monitor && ./install_monitor.sh
```

---

## 部署架构

### 依赖关系

```
0.nginx (必选)
    ↓
01.docker (推荐)
    ↓
┌───┴───┬───────────┬───────────┐
↓       ↓           ↓           ↓
1.v2ray 2.cliproxy  3.new-api   8.monitor
```

### 访问模式

所有服务脚本均支持三种访问模式：

| 模式 | SSL 证书 | 适用场景 |
|------|----------|----------|
| **域名模式** | Let's Encrypt（自动申请） | 生产环境（推荐） |
| **IP 模式** | 自签名证书 | 测试环境/无域名场景 |
| **HTTP 模式** | 无 | 内网/开发环境 |

### 多服务域名配置

> **⚠️ 重要**：同一台服务器部署多个服务时，必须为每个服务使用不同的子域名。
>
> Nginx 配置文件路径为 `/usr/local/nginx/conf/conf.d/{域名}.conf`，相同域名会导致配置覆盖。
>
> 正确示例：`proxy.example.com`、`api.example.com`、`newapi.example.com`

---

## 常用命令

### Nginx

```bash
systemctl status nginx
/usr/local/nginx/sbin/nginx -t
systemctl reload nginx
tail -f /var/log/nginx/error.log
```

### Docker / New-API

```bash
cd /opt/docker-services/new-api
docker compose ps
docker compose logs -f new-api
docker compose restart
```

### SSL 证书

```bash
~/.acme.sh/acme.sh --list
~/.acme.sh/acme.sh --renew -d example.com --ecc --force
systemctl reload nginx
```

---

## 常见问题

### 1. 脚本执行报错 "Permission denied"

```bash
chmod +x *.sh && ./install_xxx.sh
```

### 2. Docker 服务启动失败

```bash
docker compose logs           # 查看详细日志
netstat -tlnp | grep :3000    # 检查端口占用
```

### 3. SSL 证书申请失败

- 确保域名已正确解析到服务器
- 确保 80 端口开放且未被占用

```bash
dig +short your-domain.com
netstat -tlnp | grep :80
```

### 4. 内存不足

对于低配 VPS（<1GB），建议使用 CliproxyAPI 而非 New-API。脚本会自动创建 Swap 空间。

---

## deploy_cluster.sh 说明

全流程部署引导脚本，按顺序引导安装：

```bash
./deploy_cluster.sh

# 脚本依次询问：
# 1. 安装 Nginx（必选）
# 2. 安装 Docker（推荐）
# 3. 安装 V2Ray
# 4. 安装 CliproxyAPI
# 5. 安装 New-API
```

---

**最后更新**: 2026-02-23
