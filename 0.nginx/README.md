# Nginx 1.28.1 部署指南（支持 HTTP/3）

> **版本**: v4.0
> **更新日期**: 2026-01-16
> **Nginx 版本**: 1.28.1（支持 HTTP/3 QUIC 协议）
> **适用场景**: VPS 集群基础设施部署

---

## 目录

- [项目简介](#项目简介)
- [快速开始](#快速开始)
- [详细部署步骤](#详细部署步骤)
- [系统优化说明](#系统优化说明)
- [Nginx 模块说明](#nginx-模块说明)
- [服务管理](#服务管理)
- [目录结构](#目录结构)
- [常见问题](#常见问题)
- [后续服务部署](#后续服务部署)

---

## 项目简介

本脚本是 VPS 集群项目的**基础设施组件**，为后续所有服务提供 Web 服务器和反向代理能力。

### 核心功能

- **Nginx 1.28.1 源码编译安装**: 支持最新的 HTTP/3 (QUIC) 协议
- **系统内核优化**: 自动开启 BBR 拥塞控制，优化 TCP 连接参数
- **模块化配置结构**: 构建 `conf.d` 目录结构，方便后续服务扩展
- **低内存适配**: 自动为低内存服务器（<1GB）创建 Swap 空间

### 技术特性

| 特性 | 说明 |
|------|------|
| **HTTP/3 (QUIC)** | 基于 UDP 的新一代 HTTP 协议，减少连接延迟 |
| **HTTP/2** | 多路复用，头部压缩，服务器推送 |
| **TCP BBR** | Google 拥塞控制算法，提升网络吞吐量 |
| **Stream 模块** | 支持四层 TCP/UDP 代理（用于负载均衡） |
| **RealIP 模块** | 支持 Cloudflare 等 CDN 的真实 IP 还原 |

### 为什么需要先部署此脚本？

```
                    ┌─────────────────────────────────────────┐
                    │      0.nginx部署（1.28.1 HTTP3）         │
                    │          【基础设施层 - 必须先部署】        │
                    └────────────────────┬────────────────────┘
                                         │
        ┌────────────────┬───────────────┼───────────────┬────────────────┐
        ▼                ▼               ▼               ▼                ▼
   ┌─────────┐    ┌───────────┐   ┌──────────┐   ┌──────────┐    ┌─────────────┐
   │ V2Ray   │    │CliproxyAPI│   │ New-API  │   │ LiteLLM  │    │ CN2反向代理  │
   │ 节点    │    │  API转发   │   │ AI网关   │   │ LLM代理  │    │   优化      │
   └─────────┘    └───────────┘   └──────────┘   └──────────┘    └─────────────┘
```

所有后续服务都依赖本脚本提供的：
- Nginx 主程序和配置结构
- SSL 证书存储目录
- 模块化虚拟主机配置目录
- 系统优化（BBR、文件描述符提升）

---

## 快速开始

### 系统要求

| 项目 | 最低配置 | 推荐配置 |
|------|---------|---------|
| **操作系统** | Ubuntu 20.04 / Debian 11 / CentOS 7 | Ubuntu 22.04+ |
| **内存** | 512MB | 1GB+ |
| **磁盘** | 500MB 可用空间 | 2GB+ |
| **内核版本** | 4.9+（BBR 支持） | 5.4+ |
| **权限** | root | root |

### 一键部署

```bash
cd "0.nginx部署（1.28.1 HTTP3）"
chmod +x install_nginx.sh
./install_nginx.sh
```

**部署时间**: 约 5-10 分钟（取决于服务器性能和网络速度）

### 验证安装

```bash
# 检查 Nginx 版本
/usr/local/nginx/sbin/nginx -V

# 验证 HTTP/3 模块
/usr/local/nginx/sbin/nginx -V 2>&1 | grep http_v3

# 检查服务状态
systemctl status nginx

# 验证 BBR 开启
sysctl net.ipv4.tcp_congestion_control
# 应输出: net.ipv4.tcp_congestion_control = bbr
```

---

## 详细部署步骤

### 脚本执行流程

```
[1/4] 系统环境检查与优化
      ├─ 检查 Root 权限
      ├─ 检测内存，低于 1GB 自动创建 Swap
      ├─ 配置内核参数（BBR、TCP 优化）
      └─ 提升文件描述符限制

[2/4] 安装依赖库
      ├─ Ubuntu/Debian: build-essential, libssl-dev, libpcre3-dev...
      └─ CentOS/RHEL: Development Tools, openssl-devel...

[3/4] 编译安装 Nginx 1.28.1
      ├─ 下载官方源码
      ├─ 配置编译参数（24+ 模块）
      ├─ 编译并安装到 /usr/local/nginx
      └─ 创建目录结构

[4/4] 配置 Nginx 结构
      ├─ 生成主配置文件（nginx.conf）
      ├─ 创建 Systemd 服务
      └─ 启动并启用开机自启
```

### 输出结果

部署完成后，脚本显示：

```
==============================================
   Nginx 安装与系统优化完成 (v4.0)
==============================================
Nginx 版本:   1.28.1 (支持 HTTP/3)
Nginx 路径:   /usr/local/nginx
配置文件:     /usr/local/nginx/conf/nginx.conf
扩展配置:     /usr/local/nginx/conf/conf.d/*.conf
优化状态:     BBR 已开启, Limit 已提升
HTTP/3 支持:  ✓ 已编译 (--with-http_v3_module)
==============================================
```

---

## 系统优化说明

### BBR 拥塞控制

脚本自动开启 Google BBR 拥塞控制算法：

```bash
# 配置文件: /etc/sysctl.d/99-vps-optimize.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

**BBR 优势**：
- 提升网络吞吐量 20-30%
- 减少网络延迟
- 改善高延迟/高丢包网络环境的性能

### TCP 连接优化

```bash
net.ipv4.tcp_tw_reuse = 1         # TIME-WAIT 复用
net.ipv4.tcp_fin_timeout = 30     # FIN 超时
net.ipv4.tcp_fastopen = 3         # TCP 快速打开
net.core.somaxconn = 32768        # 连接队列大小
```

### 文件描述符提升

```bash
# /etc/security/limits.conf
* soft nofile 65535
* hard nofile 65535
```

支持 Nginx 的 `worker_connections 10240` 配置。

### 自动 Swap 创建

当检测到内存低于 1GB 时，自动创建 1.5GB Swap：

```bash
# 创建位置
/swapfile_install

# 自动持久化到 /etc/fstab
```

---

## Nginx 模块说明

### 已编译模块列表

| 模块 | 编译参数 | 用途 |
|------|---------|------|
| **SSL** | `--with-http_ssl_module` | HTTPS 支持 |
| **HTTP/2** | `--with-http_v2_module` | HTTP/2 协议 |
| **HTTP/3** | `--with-http_v3_module` | HTTP/3 QUIC 协议 |
| **RealIP** | `--with-http_realip_module` | 获取真实客户端 IP（CDN 场景） |
| **Status** | `--with-http_stub_status_module` | Nginx 状态监控 |
| **Gzip Static** | `--with-http_gzip_static_module` | 预压缩静态文件 |
| **Gunzip** | `--with-http_gunzip_module` | 解压缩模块 |
| **Sub** | `--with-http_sub_module` | 内容替换（伪装） |
| **FLV** | `--with-http_flv_module` | FLV 流媒体 |
| **MP4** | `--with-http_mp4_module` | MP4 伪流媒体 |
| **DAV** | `--with-http_dav_module` | WebDAV 支持 |
| **Stream** | `--with-stream` | TCP/UDP 四层代理 |
| **Stream SSL** | `--with-stream_ssl_module` | Stream SSL 支持 |
| **Stream SSL Preread** | `--with-stream_ssl_preread_module` | SNI 路由 |
| **Stream RealIP** | `--with-stream_realip_module` | Stream 真实 IP |

### 关键模块用途

**Stream 模块系列**（用于 7.多cn2协同-nginx负载均衡）：
```nginx
stream {
    upstream cn2_backends {
        server 1.2.3.4:443;
        server 5.6.7.8:443;
    }
    server {
        listen 443;
        proxy_pass cn2_backends;
        ssl_preread on;  # 需要 stream_ssl_preread_module
    }
}
```

**RealIP 模块**（Cloudflare 真实 IP 还原）：
```nginx
set_real_ip_from 173.245.48.0/20;
# ... 更多 Cloudflare IP 段
real_ip_header CF-Connecting-IP;
```

---

## 服务管理

### Nginx 服务命令

```bash
# 查看状态
systemctl status nginx

# 启动/停止/重启
systemctl start nginx
systemctl stop nginx
systemctl restart nginx

# 重载配置（不中断服务）
systemctl reload nginx

# 查看是否开机自启
systemctl is-enabled nginx
```

### 配置管理

```bash
# 测试配置语法
/usr/local/nginx/sbin/nginx -t

# 重载配置
/usr/local/nginx/sbin/nginx -s reload

# 查看当前配置
cat /usr/local/nginx/conf/nginx.conf

# 查看扩展配置
ls /usr/local/nginx/conf/conf.d/
```

### 日志管理

```bash
# 访问日志
tail -f /var/log/nginx/access.log

# 错误日志
tail -f /var/log/nginx/error.log

# 日志轮转（系统自动）
cat /etc/logrotate.d/nginx
```

---

## 目录结构

### 安装目录

```
/usr/local/nginx/
├── sbin/
│   └── nginx              # 可执行文件
├── conf/
│   ├── nginx.conf         # 主配置文件
│   ├── mime.types         # MIME 类型
│   ├── conf.d/            # 【扩展配置目录】- 后续服务配置存放位置
│   │   ├── api.example.com.conf
│   │   ├── litellm.example.com.conf
│   │   └── ...
│   └── ssl/               # 【SSL 证书目录】
│       ├── api.example.com/
│       │   ├── key.pem
│       │   └── fullchain.pem
│       └── ...
├── logs/
│   └── nginx.pid
└── html/                  # 默认网站根目录
```

### 日志目录

```
/var/log/nginx/
├── access.log             # 访问日志
└── error.log              # 错误日志
```

### 系统优化配置

```
/etc/sysctl.d/99-vps-optimize.conf    # 内核参数
/etc/security/limits.conf              # 文件描述符限制
/etc/systemd/system/nginx.service      # Systemd 服务
```

---

## 常见问题

### 1. BBR 开启失败

**症状**: 提示"BBR 开启失败，请检查内核版本"

**原因**: 内核版本低于 4.9

**解决方案**:
```bash
# 查看当前内核版本
uname -r

# Ubuntu/Debian 升级内核
apt update && apt install linux-generic-hwe-20.04

# CentOS 7 升级内核
rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
yum install https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm
yum --enablerepo=elrepo-kernel install kernel-ml
reboot
```

### 2. 编译失败

**症状**: `configure: error: SSL modules require the OpenSSL library`

**解决方案**:
```bash
# Ubuntu/Debian
apt-get install -y libssl-dev libpcre3-dev zlib1g-dev

# CentOS/RHEL
yum install -y openssl-devel pcre-devel zlib-devel
```

### 3. 服务启动失败

**症状**: `Job for nginx.service failed`

**排查步骤**:
```bash
# 1. 测试配置语法
/usr/local/nginx/sbin/nginx -t

# 2. 查看详细错误
journalctl -xe -u nginx

# 3. 检查端口占用
netstat -tlnp | grep :80
netstat -tlnp | grep :443

# 4. 检查日志
cat /var/log/nginx/error.log
```

### 4. 如何添加新站点？

在 `/usr/local/nginx/conf/conf.d/` 创建新配置文件：

```bash
# 示例: 添加 api.example.com
cat > /usr/local/nginx/conf/conf.d/api.example.com.conf << 'EOF'
server {
    listen 443 ssl http2;
    server_name api.example.com;

    ssl_certificate /usr/local/nginx/conf/ssl/api.example.com/fullchain.pem;
    ssl_certificate_key /usr/local/nginx/conf/ssl/api.example.com/key.pem;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
EOF

# 测试并重载
/usr/local/nginx/sbin/nginx -t && systemctl reload nginx
```

---

## 后续服务部署

Nginx 部署完成后，可以继续部署以下服务：

| 序号 | 服务 | 用途 | 部署命令 |
|------|------|------|---------|
| 1 | V2Ray 节点 | 代理服务 | `cd ../1.v2ray节点部署 && ./install_v2ray.sh` |
| 2 | CliproxyAPI | AI API 转发 | `cd ../2.cliproxyapi && ./install_cliproxyapi_v2.sh` |
| 3 | New-API | AI 模型网关 | `cd ../3.new-api && ./install_newapi_docker.sh` |
| 4 | LiteLLM | LLM 统一代理 | `cd ../4.litellm && ./install_litellm_docker.sh` |
| 5 | CN2 反向代理 | 网络优化 | `cd ../5.cn2-vps反向代理 && ./apply_ssl_cn2.sh` |

**完整部署流程**: 请参考根目录的 `deploy_cluster.sh` 脚本进行引导式部署。

---

## 技术规格

### 编译参数

```bash
./configure \
  --prefix=/usr/local/nginx \
  --user=www \
  --group=www \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-http_v3_module \
  --with-http_realip_module \
  --with-http_stub_status_module \
  --with-http_gzip_static_module \
  --with-http_gunzip_module \
  --with-http_sub_module \
  --with-http_flv_module \
  --with-http_addition_module \
  --with-http_mp4_module \
  --with-http_dav_module \
  --with-stream \
  --with-stream_ssl_module \
  --with-stream_ssl_preread_module \
  --with-stream_realip_module \
  --with-pcre \
  --with-cc-opt='-O2 -g -pipe'
```

### 主配置文件核心参数

```nginx
worker_processes  auto;           # 自动匹配 CPU 核心
worker_rlimit_nofile 65535;       # 文件描述符限制
worker_connections  10240;        # 每进程最大连接数
use epoll;                        # 高效事件模型
multi_accept on;                  # 批量接受连接
```

---

## 相关链接

- **Nginx 官方文档**: https://nginx.org/en/docs/
- **HTTP/3 说明**: https://nginx.org/en/docs/http/ngx_http_v3_module.html
- **BBR 算法**: https://github.com/google/bbr

---

**文档维护**: Claude Code
**最后更新**: 2026-01-16
