# VPS 集群部署工具

> **版本**: v2.0
> **更新日期**: 2026-01-16
> **许可证**: MIT

一套完整的 VPS 集群自动化部署工具，用于构建 AI API 网关服务、代理节点和负载均衡基础设施。

---

## 目录

- [项目简介](#项目简介)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [项目结构](#项目结构)
- [组件说明](#组件说明)
- [部署架构](#部署架构)
- [常用命令](#常用命令)
- [常见问题](#常见问题)

---

## 项目简介

本项目提供一套生产级 VPS 集群部署脚本，主要用于：

- **AI API 网关**: 聚合多个 AI 服务商 (OpenAI, Claude, Gemini 等) 的 API
- **代理服务**: 部署 V2Ray 代理节点用于科学上网
- **网络优化**: 通过 CN2 反向代理优化国内用户访问速度
- **高可用架构**: DNS 轮询和 Nginx 负载均衡方案

### 核心特性

| 特性 | 说明 |
|------|------|
| **一键部署** | 交互式引导脚本，自动处理依赖关系 |
| **模块化设计** | 各组件独立部署，按需选择 |
| **生产就绪** | 包含 SSL 证书、系统优化、服务管理 |
| **低配适配** | 支持 512MB 内存的低配 VPS |

---

## 环境要求

### 支持的操作系统

| 操作系统 | 版本 | 测试状态 |
|---------|------|---------|
| **Ubuntu** | 20.04 / 22.04 / 24.04 | ✅ 推荐 |
| **Debian** | 11 / 12 | ✅ 支持 |
| **CentOS** | 7 / 8 / Stream 9 | ✅ 支持 |
| **RHEL** | 8 / 9 | ✅ 支持 |
| **Rocky Linux** | 8 / 9 | ✅ 支持 |
| **AlmaLinux** | 8 / 9 | ✅ 支持 |

### 硬件要求

| 组件 | 最低配置 | 推荐配置 |
|------|---------|---------|
| **0.nginx** | 512MB 内存, 500MB 磁盘 | 1GB 内存, 2GB 磁盘 |
| **1.v2ray** | 512MB 内存 | 1GB 内存 |
| **2.cliproxyapi** | 256MB 内存 | 512MB 内存 |
| **3.new-api** | 1GB 内存 (Docker) | 2GB 内存 |
| **4.litellm** | 1GB 内存 (Docker) | 2GB 内存 |

注：在要求配置以下也可以运行，但是会增加不稳定性

### 前置条件

- **Root 权限**: 所有脚本需要 root 用户执行
- **网络连接**: 需要访问 GitHub、Docker Hub 等
- **域名（可选）**: 申请 SSL 证书需要已解析的域名
- **端口开放**: 80 (HTTP), 443 (HTTPS)

### 内核要求

- **BBR 支持**: 内核版本 ≥ 4.9（脚本自动开启）
- **推荐内核**: 5.4+ 以获得最佳性能

---

## 快速开始

### 方式一：引导式部署（推荐）

使用根目录的 `deploy_cluster.sh` 进行完整引导：

```bash
# 1. 克隆或下载项目
git clone https://github.com/your-repo/vps_deployment_ai_tools.git
cd vps_deployment_ai_tools

# 2. 运行部署引导脚本
chmod +x deploy_cluster.sh
./deploy_cluster.sh
```

脚本将按顺序引导你完成各组件的安装，自动处理依赖关系。

### 方式二：单独部署

如果只需要部署特定组件：

```bash
# 示例：仅部署 Nginx
cd 0.nginx
chmod +x install_nginx.sh
./install_nginx.sh

# 示例：部署 New-API
cd 3.new-api
chmod +x install_newapi_docker.sh
./install_newapi_docker.sh
```

---

## 项目结构

```
vps_deployment_ai_tools/
├── deploy_cluster.sh              # 全流程部署引导脚本
├── README.md                      # 本文档
├── CLAUDE.md                      # AI 开发助手配置
├── LICENSE                        # MIT 许可证
│
├── 0.nginx/                       # Nginx 基础设施（必选）
│   ├── install_nginx.sh           # 安装脚本
│   └── README.md                  # 部署文档
│
├── 1.v2ray/                       # V2Ray 代理节点
│   ├── install_v2ray.sh           # V2Ray 安装
│   ├── install_web.sh             # 伪装网站
│   └── README.md                  # 部署文档
│
├── 2.cliproxyapi/                 # CliproxyAPI 轻量代理
│   ├── install_cliproxyapi_v2.sh  # 安装脚本
│   └── README.md                  # 部署文档
│
├── 3.new-api/                     # New-API AI 网关
│   ├── install_newapi_docker.sh   # Docker 安装
│   ├── upgrade_newapi_docker.sh   # 升级脚本
│   ├── uninstall_newapi_docker.sh # 卸载脚本
│   └── README.md                  # 部署文档
│
├── 4.litellm/                     # LiteLLM 统一代理
│   ├── install_litellm_docker.sh  # Docker 安装
│   ├── upgrade_litellm_docker.sh  # 升级脚本
│   └── README.md                  # 部署文档
│
├── 5.cn2-proxy/                   # CN2 反向代理
│   ├── apply_ssl_cn2.sh           # SSL 证书申请
│   ├── nginx_newapi_proxy.conf    # Nginx 配置模板
│   └── README.md                  # 部署文档
│
├── 6.dns-loadbalance/             # DNS 轮询负载均衡
│   ├── health_check.sh            # 健康检查脚本
│   └── README.md                  # 部署文档
│
├── 7.nginx-loadbalance/           # Nginx Stream 负载均衡
│   ├── newapi_lb.conf             # 负载均衡配置
│   ├── nginx_healthcheck.sh       # 健康检查脚本
│   └── README.md                  # 部署文档
│
└── 8.service-monitor/             # 服务监控系统
    ├── install_monitor.sh         # 安装脚本
    ├── service_monitor.sh         # 监控主脚本
    ├── send_email.sh              # 邮件告警
    └── README.md                  # 部署文档
```

---

## 组件说明

### 0.nginx - Nginx 基础设施【必选】

> **依赖**: 无
> **部署方式**: 源码编译

**功能**:
- Nginx 1.28.1 源码编译安装，支持 HTTP/3 (QUIC) 协议
- 自动开启 TCP BBR 拥塞控制算法，提升网络性能 20-30%
- 优化系统内核参数，提升文件描述符限制
- 构建模块化配置结构 (conf.d/)，方便后续服务扩展
- 编译 Stream 模块，支持四层 TCP/UDP 负载均衡

**适用场景**: 所有需要 Web 服务或反向代理的场景

```bash
cd 0.nginx && ./install_nginx.sh
```

---

### 1.v2ray - V2Ray 代理节点

> **依赖**: 0.nginx
> **部署方式**: 二进制 + Systemd

**功能**:
- V2Ray 代理服务，用于科学上网
- WebSocket + TLS 传输，流量伪装为正常 HTTPS 请求
- 自动生成随机 UUID 和 WebSocket 路径，增强安全性
- 内置静态伪装网站，访问域名显示"系统维护"页面
- 支持 Let's Encrypt 证书自动申请

**适用场景**: 需要代理节点用于科学上网

**前置要求**:
- 已解析到服务器的域名
- 80/443 端口开放

```bash
cd 1.v2ray
./install_v2ray.sh  # 输入域名
./install_web.sh    # 部署伪装网站
```

---

### 2.cliproxyapi - CliproxyAPI 轻量代理

> **依赖**: 0.nginx
> **部署方式**: 二进制 + Systemd

**功能**:
- 轻量级 AI API 转发代理服务
- 支持 OpenAI、Claude、Gemini 等主流 AI 模型 API 转发
- 提供统一的 API 端点，简化客户端配置
- 二进制部署，资源占用极低（适合低配 VPS）
- 支持多密钥管理，通过 Web 界面进行配置

**适用场景**:
- 需要简单的 AI API 转发功能
- 服务器资源有限（内存 < 1GB）
- 不需要复杂的用户管理和计费功能

**对比**:
| 方案 | 特点 | 资源占用 |
|------|------|---------|
| CliproxyAPI | 轻量、简单、二进制 | 极低 (~50MB) |
| New-API | 功能丰富、用户管理、计费 | 中等 (~500MB) |
| LiteLLM | 100+ 模型、负载均衡 | 中等 (~400MB) |

```bash
cd 2.cliproxyapi && ./install_cliproxyapi_v2.sh
```

---

### 3.new-api - New-API AI 网关

> **依赖**: 0.nginx, Docker
> **部署方式**: Docker Compose

**功能**:
- 新一代大模型网关与 AI 资产管理系统
- 支持 OpenAI、Claude、Gemini、Azure 等多种模型聚合
- 提供完整的用户管理、令牌分组、权限控制功能
- 内置计费系统，支持按次数/按量收费和在线充值
- 可视化数据看板，实时统计 API 调用情况
- 支持 Discord、Telegram、OIDC 等多种授权登录

**技术栈**:
- Docker Compose 部署
- PostgreSQL 数据库
- Redis 缓存

**适用场景**:
- 需要完整的 AI API 管理平台
- 需要用户管理和计费功能
- 对外提供 AI API 服务

**默认账号**: `root` / `123456` (首次登录后请立即修改)

```bash
cd 3.new-api && ./install_newapi_docker.sh
```

---

### 4.litellm - LiteLLM 统一代理

> **依赖**: 0.nginx, Docker
> **部署方式**: Docker Compose

**功能**:
- 统一的 LLM API 代理服务器
- 支持 100+ AI 模型（OpenAI, Claude, Gemini, Azure, AWS Bedrock 等）
- 提供 OpenAI 兼容的统一接口，简化客户端集成
- 内置负载均衡，支持多密钥轮询和故障转移
- 虚拟密钥管理，可为每个密钥设置预算限额
- Redis 缓存加速，减少重复请求费用
- Prometheus 监控指标，支持成本追踪

**与 New-API 的区别**:
| 方案 | 定位 | 特点 |
|------|------|------|
| New-API | 面向运营 | 完整的用户系统和计费 |
| LiteLLM | 面向开发者 | 统一接口和负载均衡 |

两者可以配合使用：New-API 作为前端，LiteLLM 作为后端。

```bash
cd 4.litellm && ./install_litellm_docker.sh
```

---

### 5.cn2-proxy - CN2 反向代理

> **依赖**: 0.nginx, 后端服务 (2/3/4 之一)
> **部署位置**: CN2 VPS（不是性能服务器）

**功能**:
- CN2 反向代理用于优化国内用户访问海外 API 服务的速度
- 利用 CN2 线路（中国电信精品网络）降低延迟
- 在 CN2 VPS 上部署 Nginx 反向代理，转发请求到性能服务器
- 支持 SSL 证书自动申请和配置
- 针对 SSE 流式传输进行优化

**架构说明**:
```
用户（国内）
    ↓ 访问 CN2 域名
CN2 VPS (反向代理)
newapi.example.com
    ↓ CN2 优质线路
性能服务器（海外）
api.example.com
    ↓
AI 服务 (New-API / LiteLLM)
```

**前置要求**:
- 一台 CN2 线路的 VPS（国内访问快）
- 后端服务已部署并可访问
- 两个域名：CN2 入口域名 和 后端服务域名

```bash
cd 5.cn2-proxy
./apply_ssl_cn2.sh -d newapi.example.com
# 然后编辑 Nginx 配置，设置后端地址
```

---

### 6.dns-loadbalance - DNS 轮询负载均衡

> **依赖**: 5.cn2-proxy (多台)
> **复杂度**: 低

**功能**:
- 通过 DNS 轮询实现多 CN2 节点负载均衡
- 在 DNS 中为同一域名添加多条 A 记录
- DNS 服务器自动轮询返回不同 IP

**优缺点**:
| 优点 | 缺点 |
|------|------|
| 配置简单 | 无健康检查 |
| 零成本 | 故障切换慢（5-60分钟）|
| 自动分散流量 | 分布不均 |

**可用性**: ~95%

```bash
# 只需在 DNS 添加多条 A 记录：
# newapi.example.com → 1.2.3.4 (CN2-1)
# newapi.example.com → 5.6.7.8 (CN2-2)
```

---

### 7.nginx-loadbalance - Nginx Stream 负载均衡

> **依赖**: 5.cn2-proxy (多台)
> **复杂度**: 中等

**功能**:
- 使用 Nginx Stream 模块进行四层代理
- 主动健康检查，秒级故障切换
- 支持权重分配和会话保持
- 完全可控的流量分发

**架构**:
```
用户
  ↓
负载均衡器 VPS (Nginx Stream)
lb.example.com
  ↓ 健康检查 + 加权路由
CN2-1 / CN2-2 / CN2-3
  ↓
性能服务器
```

**对比 DNS 轮询**:
| 特性 | DNS 轮询 | Nginx Stream |
|------|---------|--------------|
| 成本 | $0 | +$10/月 (LB VPS) |
| 健康检查 | 无 | 自动 |
| 故障切换 | 5-60分钟 | <5秒 |
| 会话保持 | 否 | 支持 |
| 可用性 | ~95% | ~99.5% |

---

### 8.service-monitor - 服务监控系统

> **依赖**: 无
> **部署方式**: 纯 Bash

**功能**:
- 多维度监控：Systemd 服务、Docker 容器、HTTP 端点、系统资源
- 智能告警：状态变化检测，避免重复告警
- 邮件通知：支持 Gmail、QQ、163 等邮箱
- 轻量级：纯 Bash 实现，资源占用极低
- 模块化设计：配置文件驱动，易于扩展

```bash
cd 8.service-monitor && ./install_monitor.sh
```

---

## 部署架构

### 典型部署拓扑

```
                              ┌─────────────────────────┐
                              │       最终用户           │
                              └───────────┬─────────────┘
                                          │
              ┌───────────────────────────┼───────────────────────────┐
              │                           │                           │
              ▼                           ▼                           ▼
      ┌───────────────┐          ┌───────────────┐          ┌───────────────┐
      │  CN2 VPS-1    │          │  CN2 VPS-2    │          │  CN2 VPS-3    │
      │  反向代理      │          │  反向代理      │          │  反向代理      │
      └───────┬───────┘          └───────┬───────┘          └───────┬───────┘
              │                           │                           │
              └───────────────────────────┼───────────────────────────┘
                                          │
                                          ▼
                              ┌─────────────────────────┐
                              │      性能服务器          │
                              │                         │
                              │  ┌─────────────────┐   │
                              │  │     Nginx       │   │
                              │  │  (HTTP/3 支持)   │   │
                              │  └────────┬────────┘   │
                              │           │            │
                              │  ┌────────┼────────┐   │
                              │  ▼        ▼        ▼   │
                              │ New-API LiteLLM Cliproxy│
                              │ (3000)  (4000)  (8317) │
                              └─────────────────────────┘
                                          │
                                          ▼
                              ┌─────────────────────────┐
                              │    AI 服务提供商         │
                              │ OpenAI / Claude / Gemini │
                              └─────────────────────────┘
```

### 流量路径

**API 请求流程**:
```
用户 → CN2 VPS (HTTPS) → 性能服务器 (Nginx) → New-API/LiteLLM → AI 服务商
```

**V2Ray 代理流程**:
```
客户端 → Nginx (443/WSS) → V2Ray (10000) → 自由出站
```

---

## 常用命令

### Nginx 管理

```bash
# 服务控制
systemctl status nginx
systemctl reload nginx
systemctl restart nginx

# 配置测试
/usr/local/nginx/sbin/nginx -t

# 查看日志
tail -f /var/log/nginx/access.log
tail -f /var/log/nginx/error.log
```

### Docker 服务管理

```bash
# New-API
cd /opt/docker-services/new-api
docker compose ps
docker compose logs -f new-api
docker compose restart

# LiteLLM
cd /opt/docker-services/litellm
docker compose ps
docker compose logs -f litellm
```

### SSL 证书管理

```bash
# 查看证书列表
~/.acme.sh/acme.sh --list

# 手动续期
~/.acme.sh/acme.sh --renew -d example.com --ecc --force
systemctl reload nginx
```

---

## 常见问题

### 1. 脚本执行报错 "Permission denied"

```bash
chmod +x *.sh
./install_xxx.sh
```

### 2. BBR 开启失败

内核版本低于 4.9，需要升级内核：

```bash
# Ubuntu/Debian
apt update && apt install linux-generic-hwe-20.04
reboot
```

### 3. Docker 服务启动失败

```bash
# 查看详细日志
docker compose logs

# 检查端口占用
netstat -tlnp | grep :3000
```

### 4. SSL 证书申请失败

- 确保域名已正确解析到服务器
- 确保 80 端口开放且未被占用
- 检查防火墙设置

```bash
# 验证 DNS
dig +short your-domain.com

# 检查端口
netstat -tlnp | grep :80
```

### 5. 内存不足

对于低配 VPS（<1GB），建议：
- 使用 CliproxyAPI 而非 New-API/LiteLLM
- 脚本会自动创建 Swap 空间

---

## deploy_cluster.sh 说明

`deploy_cluster.sh` 是全流程部署引导脚本，提供：

### 功能特性

1. **依赖检查**: 自动检测组件依赖关系，按正确顺序部署
2. **交互式引导**: 每个组件都有详细的功能说明，帮助用户决策
3. **跳过机制**: 可以跳过不需要的可选组件
4. **进度跟踪**: 显示已安装的服务列表

### 依赖关系

```
0.nginx (必选)
    ↓
┌───┴───┬───────┬───────┐
↓       ↓       ↓       ↓
1.v2ray 2.cliproxy 3.new-api 4.litellm
                ↓       ↓       ↓
                └───┬───┴───────┘
                    ↓
                5.cn2-proxy
                    ↓
              ┌─────┴─────┐
              ↓           ↓
       6.dns-lb    7.nginx-lb
```

### 使用方式

```bash
# 交互式部署
./deploy_cluster.sh

# 脚本会依次询问：
# 1. 是否安装 Nginx（必选）
# 2. 是否安装 V2Ray
# 3. 是否安装 CliproxyAPI
# 4. 是否安装 New-API
# 5. 是否安装 LiteLLM
# 6. 是否配置 CN2 反向代理（需要后端服务）
# 7. 是否了解多 CN2 协同方案
```

---

## 许可证

本项目采用 [MIT 许可证](LICENSE)。

---

**最后更新**: 2026-01-16
