# V2Ray 节点部署

> **版本**: v3.1
> **更新日期**: 2026-01-16
> **部署方式**: V2Ray 二进制 + Nginx 反向代理

---

## 目录

- [项目简介](#项目简介)
- [快速开始](#快速开始)
- [详细部署步骤](#详细部署步骤)
- [服务管理](#服务管理)
- [客户端配置](#客户端配置)
- [常见问题](#常见问题)

---

## 项目简介

本目录提供 V2Ray 代理节点的自动化部署脚本，实现基于 WebSocket + TLS 的安全代理。

### 核心特性

- **安全传输**: WebSocket over TLS，流量伪装为 HTTPS
- **随机化配置**: UUID 和 WebSocket 路径自动随机生成
- **双证书策略**: 优先 Let's Encrypt，失败自动降级为自签名证书
- **伪装网站**: 内置静态维护页面，防止路径探测
- **Cloudflare 兼容**: 自动配置真实 IP 还原
- **双模式支持**: 支持域名模式和 IP 模式

### 访问模式

| 模式 | SSL 证书 | 适用场景 | 客户端设置 |
|------|----------|----------|------------|
| 域名模式 | Let's Encrypt（自动申请） | 生产环境（推荐） | 正常连接 |
| IP 模式 | 自签名证书 | 测试环境/无域名 | 需开启 AllowInsecure |
| HTTP 模式 | 无 | 内网/开发环境 | TLS 设置为关闭 |

### 技术架构

```
用户客户端 (V2Ray)
    ↓ HTTPS (443)
Nginx (TLS 终止)
    ├─→ / (默认) → 静态伪装网站
    └─→ /ws-xxxxx → V2Ray (localhost:10000)
                        ↓
                    自由出站
```

---

## 快速开始

### 前置条件

1. **Nginx 已安装**
   ```bash
   # 如未安装，先运行
   cd "../0.nginx部署（1.28.1 HTTP3）"
   ./install_nginx.sh
   ```

2. **域名已解析**（域名模式）
   - 将域名 A 记录指向服务器 IP
   - 例如: `v2.example.com → 123.45.67.89`
   - IP 模式无需此步骤

3. **端口开放**
   - TCP 80 (HTTP, ACME 验证)
   - TCP 443 (HTTPS)

### 部署命令

```bash
cd "1.v2ray节点部署"
chmod +x install_v2ray.sh install_web.sh
./install_v2ray.sh    # 选择访问模式，输入域名或使用 IP
./install_web.sh      # 部署伪装网站
```

**部署时间**: 约 3-5 分钟

---

## 详细部署步骤

### 步骤 1: 安装 V2Ray 核心

```bash
./install_v2ray.sh
```

**交互输入**:
- 域名（例如: v2.example.com）

**自动完成**:
- 下载并安装 V2Ray
- 生成随机 UUID 和 WebSocket 路径
- 申请 SSL 证书
- 配置 Nginx 反向代理
- 启动 V2Ray 服务

### 步骤 2: 部署伪装网站

```bash
./install_web.sh
```

生成一个"系统维护中"的静态页面，用于流量伪装。

### 步骤 3: 验证部署

```bash
# 检查服务状态
systemctl status nginx
systemctl status v2ray

# 测试 HTTPS 访问
curl -I https://v2.example.com

# 查看连接信息
cat v2ray_node_info.txt
```

---

## 服务管理

### V2Ray 服务

```bash
# 查看状态
systemctl status v2ray

# 启动/停止/重启
systemctl start v2ray
systemctl stop v2ray
systemctl restart v2ray

# 查看日志
journalctl -u v2ray -f
```

### Nginx 服务

```bash
# 测试配置
/usr/local/nginx/sbin/nginx -t

# 重载配置
systemctl reload nginx

# 查看访问日志
tail -f /var/log/nginx/access.log
```

### SSL 证书管理

```bash
# 查看证书列表
~/.acme.sh/acme.sh --list

# 手动续期
~/.acme.sh/acme.sh --renew -d v2.example.com --ecc --force
systemctl reload nginx
```

---

## 客户端配置

### 连接参数

部署完成后，连接信息保存在 `v2ray_node_info.txt`：

| 参数 | 值 |
|------|-----|
| 协议 | VMess |
| 地址 | v2.example.com |
| 端口 | 443 |
| UUID | (自动生成) |
| 传输 | WebSocket (ws) |
| 路径 | /ws-xxxxxxxx |
| TLS | 开启 |

### V2RayN/V2RayNG 配置

1. 添加服务器 → VMess
2. 填写地址、端口、UUID
3. 传输协议选择 WebSocket
4. 填写 WebSocket 路径
5. 启用 TLS

### Cloudflare 配置（可选）

如需使用 Cloudflare CDN：

1. DNS 中将域名设为"橙色云朵"（代理模式）
2. SSL/TLS 设置为"Full (strict)"
3. 在客户端中启用"AllowInsecure"（仅自签名证书时需要）

---

## 常见问题

### 1. V2Ray 连接失败

**排查步骤**:
```bash
# 检查服务状态
systemctl status v2ray

# 检查配置语法
/usr/local/bin/v2ray test -config /usr/local/etc/v2ray/config.json

# 查看详细日志
journalctl -u v2ray -n 50
```

### 2. SSL 证书申请失败

**常见原因**:
- DNS 未正确解析到服务器
- 80 端口被占用或被防火墙阻止

**解决方案**:
```bash
# 验证 DNS 解析
dig +short v2.example.com

# 检查 80 端口
netstat -tlnp | grep :80

# 重新申请证书
~/.acme.sh/acme.sh --issue -d v2.example.com --webroot /var/www/acme --keylength ec-256
```

### 3. 浏览器访问显示错误

**预期行为**:
- 访问域名应显示"System Maintenance"页面
- 这是正常的伪装效果

**如果显示 502/504**:
```bash
# 检查 V2Ray 是否运行
systemctl status v2ray

# 检查 Nginx 配置
/usr/local/nginx/sbin/nginx -t
```

---

## 配置文件路径

| 文件 | 路径 |
|------|------|
| V2Ray 配置 | `/usr/local/etc/v2ray/config.json` |
| Nginx 站点配置 | `/usr/local/nginx/conf/conf.d/{domain}.conf` |
| SSL 证书 | `/usr/local/nginx/conf/ssl/{domain}/` |
| 伪装网站 | `/var/www/static/index.html` |
| 连接信息 | `./v2ray_node_info.txt` |

---

## 安全建议

1. **保护连接信息**: `v2ray_node_info.txt` 包含 UUID，妥善保管
2. **定期更换 UUID**: 可通过重新运行脚本更换
3. **启用防火墙**: 仅开放必要端口（22, 80, 443）
4. **监控流量**: 定期检查 Nginx 访问日志

---

## 相关链接

- **V2Ray 官方文档**: https://www.v2fly.org/
- **V2RayN 客户端**: https://github.com/2dust/v2rayN
- **V2RayNG 客户端**: https://github.com/2dust/v2rayNG

---

**文档维护**: Claude Code
**最后更新**: 2026-01-16
