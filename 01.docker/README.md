# Docker 自动安装指南

> **版本**: v1.0
> **更新日期**: 2026-02-23
> **适用场景**: VPS 集群 Docker 服务基础环境

---

## 目录

- [项目简介](#项目简介)
- [快速开始](#快速开始)
- [详细安装流程](#详细安装流程)
- [使用方式](#使用方式)
- [服务管理](#服务管理)
- [常见问题](#常见问题)

---

## 项目简介

本脚本为 VPS 集群项目的 **Docker 环境组件**，为 New-API 等容器化服务提供运行环境。

### 核心功能

- **自动检测**: 已安装则跳过，仅确保服务运行
- **apt 源修复**: 自动修复 Debian/Ubuntu 常见源问题
- **双重安装策略**: 官方脚本优先，失败后按发行版手动安装
- **Compose 插件**: 自动安装 Docker Compose 插件
- **可复用设计**: 支持直接运行和 `source` 引用两种模式

### 为什么需要 Docker？

```
┌──────────────────────────────────────────┐
│         01.docker（容器运行环境）          │
│       【Docker 服务的前置依赖 - 推荐安装】  │
└────────────────────┬─────────────────────┘
                     │
         ┌───────────┴───────────┐
         ▼                       ▼
   ┌──────────┐          ┌──────────────┐
   │ New-API  │          │  其他 Docker  │
   │ AI 网关  │          │    服务       │
   └──────────┘          └──────────────┘
```

以下服务依赖 Docker 环境：
- **3.new-api**: Docker Compose 部署（PostgreSQL + Redis + New-API）

---

## 快速开始

### 系统要求

| 项目 | 最低配置 | 推荐配置 |
|------|---------|---------|
| **操作系统** | Ubuntu 20.04 / Debian 11 / CentOS Stream 9 | Ubuntu 22.04+ |
| **内存** | 512MB | 1GB+ |
| **磁盘** | 2GB 可用空间 | 10GB+ |
| **权限** | root | root |

### 一键安装

```bash
cd 01.docker
chmod +x install_docker.sh
./install_docker.sh
```

### 验证安装

```bash
# 检查 Docker 版本
docker --version

# 检查 Compose 版本
docker compose version

# 检查服务状态
systemctl status docker

# 运行测试容器
docker run --rm hello-world
```

---

## 详细安装流程

```
Docker 已安装？
  ├─ 是 → 检查版本 → 确保服务运行 → 完成
  └─ 否 → 开始自动安装
           ├─ 1. 修复 apt 源（Debian/Ubuntu）
           ├─ 2. 安装依赖包
           ├─ 3. 尝试官方脚本 (get.docker.com)
           │     ├─ 成功 → 启动服务 → 完成
           │     └─ 失败 → 进入备用方案
           ├─ 4. 按发行版手动安装
           │     ├─ debian/ubuntu → apt + Docker 官方仓库
           │     ├─ centos/rhel/rocky → yum + Docker 仓库
           │     └─ 其他 → 报错退出
           └─ 5. 启动服务 + 验证安装
```

---

## 使用方式

### 方式一：直接运行

```bash
./install_docker.sh
```

适用于独立安装 Docker 环境。

### 方式二：被其他脚本引用

```bash
# 在其他安装脚本中
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_INSTALLER="$SCRIPT_DIR/../01.docker/install_docker.sh"

source "$DOCKER_INSTALLER"
ensure_docker
```

提供 `ensure_docker` 函数供调用，已安装则直接返回成功。

### 方式三：通过 deploy_cluster.sh

```bash
./deploy_cluster.sh
# 在 Nginx 安装后会自动引导安装 Docker
```

---

## 服务管理

### Docker 服务命令

```bash
# 查看状态
systemctl status docker

# 启动/停止/重启
systemctl start docker
systemctl stop docker
systemctl restart docker

# 查看是否开机自启
systemctl is-enabled docker
```

### 常用 Docker 命令

```bash
# 查看运行中的容器
docker ps

# 查看所有容器
docker ps -a

# 查看镜像列表
docker images

# 清理未使用的资源
docker system prune -f

# 查看磁盘使用
docker system df
```

---

## 常见问题

### 1. 官方脚本下载失败

**症状**: `curl: (7) Failed to connect to get.docker.com`

**解决方案**: 脚本会自动切换到手动安装方式，无需干预。如仍失败，检查网络连通性。

### 2. apt 源报错

**症状**: `E: The repository ... does not have a Release file`

**解决方案**: 脚本内置 `fix_apt_sources` 函数自动修复常见源问题（Debian 10/11 安全源路径变更等）。

### 3. Docker 服务启动失败

**排查步骤**:
```bash
# 查看详细错误
journalctl -xe -u docker

# 检查存储驱动
docker info 2>&1 | grep "Storage Driver"

# 检查磁盘空间
df -h /var/lib/docker
```

### 4. docker compose 命令不可用

**解决方案**:
```bash
# 安装 Compose 插件
apt-get install docker-compose-plugin

# 或使用独立版本
curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
```

---

**文档维护**: Claude Code
**最后更新**: 2026-02-23
