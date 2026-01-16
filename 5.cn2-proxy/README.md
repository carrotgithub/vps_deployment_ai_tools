# CN2 VPS 反向代理部署指南

## 📋 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│ 最终用户                                                      │
│ https://newapi.tunecoder.example.com (CN2 线路)                      │
└────────────────────┬────────────────────────────────────────┘
                     │ HTTPS
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ CN2 轻量VPS (前端转发层)                                      │
│ ┌─────────────────────────────────────┐                     │
│ │   Nginx (HTTPS 反向代理)             │                     │
│ │   域名: newapi.tunecoder.example.com        │                     │
│ │   功能: 转发到性能服务器             │                     │
│ │   超时: 600秒 | SSE: 支持            │                     │
│ └─────────────────────────────────────┘                     │
│                                                               │
│ ┌─────────────────────────────────────┐                     │
│ │   V2Ray 服务端 (可选，翻墙用)        │                     │
│ │   与 API 转发无关                    │                     │
│ └─────────────────────────────────────┘                     │
└────────────────────┬────────────────────────────────────────┘
                     │ 公网 HTTPS
                     │ proxy_pass https://api.tunecoder.example.com
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ 性能服务器 (后端业务层)                                       │
│                                                               │
│ ┌─────────────────────────────────────────────────────┐     │
│ │            Nginx (HTTPS 监听 443)                    │     │
│ └───┬─────────────┬─────────────┬───────────────────┘     │
│     │             │             │                           │
│     ▼             ▼             ▼                           │
│ ┌─────────┐  ┌─────────┐  ┌──────────────┐                │
│ │New-API  │  │LiteLLM  │  │CliproxyAPI   │                │
│ │(3000)   │  │(4000)   │  │(8317)        │                │
│ │         │  │         │  │              │                │
│ │api.     │  │litellm. │  │cliproxyapi.  │                │
│ │tunecoder│  │tunecoder│  │tunecoder.example.com │                │
│ │.com     │  │.com     │  │              │                │
│ └────┬────┘  └────┬────┘  └──────┬───────┘                │
│      │            │               │                         │
│      │  内部调用: LiteLLM → CliproxyAPI                     │
│      └────────── New-API → CliproxyAPI + LiteLLM           │
└─────────────────────────────────────────────────────────────┘
```

## 🎯 部署目标

**用户访问流程：**
```
用户 → CN2 VPS (newapi.tunecoder.example.com)
     → 性能服务器 Nginx (api.tunecoder.example.com)
     → New-API (localhost:3000)
     → CliproxyAPI 或 LiteLLM
     → 上游 AI 服务商
```

**管理员访问流程（通过 V2Ray 翻墙）：**
```
管理员 → V2Ray 客户端
      → CN2 VPS V2Ray 服务端
      → 直接访问性能服务器管理台:
         • https://api.tunecoder.example.com (New-API)
         • https://litellm.tunecoder.example.com/ui (LiteLLM)
         • https://cliproxyapi.tunecoder.example.com/v0/ (CliproxyAPI)
```

---

## 📦 部署前提条件

### 性能服务器（已完成）

✅ 已部署以下服务：
- Nginx 1.28.1 + HTTP/3
- New-API (Docker) - `api.tunecoder.example.com`
- LiteLLM (Docker) - `litellm.tunecoder.example.com`
- CliproxyAPI (二进制) - `cliproxyapi.tunecoder.example.com`

✅ 所有服务已申请 Let's Encrypt 证书

### CN2 VPS（待部署）

需要准备：
1. ✅ 已部署 Nginx 1.28.1 + HTTP/3
2. ✅ DNS 配置：`newapi.tunecoder.example.com` → CN2 VPS IP
3. ⏳ V2Ray 翻墙节点（可选，与 API 无关）

---

## 🚀 部署步骤

### 第一步：性能服务器部署（已完成）

如果尚未部署，请依次运行：

```bash
# 1. 部署 Nginx
cd "0.nginx部署（1.28.1 HTTP3）"
./install_nginx.sh

# 2. 部署 New-API
cd "../3.new-api"
./install_newapi_docker.sh
# 输入域名: api.tunecoder.example.com

# 3. 部署 LiteLLM
cd "../4.litellm"
./install_litellm_docker.sh
# 输入域名: litellm.tunecoder.example.com

# 4. 部署 CliproxyAPI
cd "../2.cliproxyapi"
./install_cliproxyapi_v2.sh
# 输入域名: cliproxyapi.tunecoder.example.com
```

**验证部署：**
```bash
# 检查服务状态
systemctl status nginx
cd /opt/docker-services/new-api && docker compose ps
cd /opt/docker-services/litellm && docker compose ps
systemctl status cliproxyapi

# 检查 SSL 证书
ls -lh /usr/local/nginx/conf/ssl/api.tunecoder.example.com/
ls -lh /usr/local/nginx/conf/ssl/litellm.tunecoder.example.com/
ls -lh /usr/local/nginx/conf/ssl/cliproxyapi.tunecoder.example.com/
```

---

### 第二步：CN2 VPS 部署 Nginx

```bash
# 1. 部署 Nginx（如果尚未安装）
cd "0.nginx部署（1.28.1 HTTP3）"
./install_nginx.sh
```

---

### 第三步：CN2 VPS 配置 SSL 证书

脚本支持三种模式：
- **域名模式**：自动申请 Let's Encrypt 证书（推荐）
- **IP 模式**：使用自签名证书，无需域名
- **HTTP 模式**：无 SSL 证书，仅限内网/开发环境

```bash
cd "5.cn2-vps反向代理"

# 赋予执行权限
chmod +x apply_ssl_cn2.sh

# 域名模式（推荐）
./apply_ssl_cn2.sh -d newapi.tunecoder.example.com

# IP 模式（无需域名）
./apply_ssl_cn2.sh -i 1.2.3.4

# HTTP 模式（无 SSL）
./apply_ssl_cn2.sh -h 1.2.3.4
```

**脚本会自动：**
1. 域名模式：检查并修复 acme.sh 邮箱配置
2. 域名模式：创建临时 Nginx 配置用于 ACME 验证
3. 域名模式：申请 Let's Encrypt ECC-256 证书
4. IP 模式：直接生成自签名证书（10年有效期）
5. HTTP 模式：跳过 SSL 证书配置
6. 失败时自动降级到自签名证书

**成功后会看到：**
```
✓ SSL 证书配置完成！
访问模式: 域名模式/IP 模式/HTTP 模式
证书类型: Let's Encrypt (ECC-256) 或 自签名证书 (IP 模式) 或 无 (HTTP 模式)
证书路径: /usr/local/nginx/conf/ssl/newapi.tunecoder.example.com/
```

**IP 模式注意事项：**
- 浏览器会提示「不安全」，请点击「高级」→「继续访问」
- API 客户端可能需要关闭 SSL 验证

**HTTP 模式注意事项：**
- 数据传输不加密，API Key 可能泄露
- 仅建议在内网或开发环境使用

---

### 第四步：配置 Nginx 反向代理

#### 4.1 添加 WebSocket 升级配置（仅需执行一次）

编辑 Nginx 主配置文件：
```bash
nano /usr/local/nginx/conf/nginx.conf
```

在 `http { }` 块中添加（如果还没有）：
```nginx
http {
    # ... 现有配置 ...

    # WebSocket Connection Upgrade Map
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    # 连接池优化
    upstream_keepalive_timeout 300s;

    # ... 现有配置 ...
}
```

保存并测试配置：
```bash
/usr/local/nginx/sbin/nginx -t
```

#### 4.2 部署反向代理配置

```bash
cd "5.cn2-vps反向代理"

# 复制配置文件
cp nginx_newapi_proxy.conf /usr/local/nginx/conf/conf.d/newapi.tunecoder.example.com.conf

# 测试配置
/usr/local/nginx/sbin/nginx -t

# 重载 Nginx
systemctl reload nginx
```

---

### 第五步：验证部署

```bash
cd "5.cn2-vps反向代理"

# 赋予执行权限
chmod +x test_proxy.sh

# 运行测试脚本
./test_proxy.sh
```

**测试脚本会检查：**
1. ✅ DNS 解析是否正确
2. ✅ 性能服务器连通性
3. ✅ SSL 证书有效性
4. ✅ Nginx 配置语法
5. ✅ 反向代理响应
6. ✅ SSE 流式传输配置
7. ✅ 超时配置（600秒）
8. ✅ 日志文件访问

**所有测试通过后会显示：**
```
✓ 所有测试通过！
• CN2 VPS 反向代理正常运行
• SSL 证书配置正确
• SSE 流式传输已启用
• 超时配置符合要求 (600秒)
```

---

## 🧪 功能测试

### 测试 1: 基本连通性

```bash
# 测试 CN2 VPS 访问
curl -I https://newapi.tunecoder.example.com

# 应返回 200 或 401（需要认证）
```

### 测试 2: API 调用（需要 API Key）

```bash
# 在性能服务器的 New-API 管理台创建 API Key
# 访问: https://api.tunecoder.example.com
# 默认用户: root / 123456

# 使用 CN2 域名测试
curl https://newapi.tunecoder.example.com/v1/models \
  -H "Authorization: Bearer YOUR_API_KEY"
```

### 测试 3: SSE 流式传输

```bash
curl https://newapi.tunecoder.example.com/v1/chat/completions \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": true
  }'

# 应看到逐行返回的 data: 流
```

### 测试 4: 响应时间

```bash
curl -o /dev/null -s -w "Time: %{time_total}s\n" \
  https://newapi.tunecoder.example.com/v1/models \
  -H "Authorization: Bearer YOUR_API_KEY"
```

---

## 📊 监控和日志

### 查看 CN2 VPS 日志

```bash
# 访问日志（包含响应时间）
tail -f /var/log/nginx/newapi_proxy_access.log

# 错误日志
tail -f /var/log/nginx/newapi_proxy_error.log

# 实时监控（每5秒刷新）
watch -n 5 'tail -10 /var/log/nginx/newapi_proxy_access.log'
```

### 日志格式说明

访问日志包含以下信息：
- `rt`: 总请求时间
- `uct`: 上游连接时间
- `uht`: 上游响应头时间
- `urt`: 上游响应总时间

**示例日志：**
```
1.2.3.4 - - [05/Jan/2026:12:00:00 +0000] "POST /v1/chat/completions HTTP/2.0" 200 1234
"https://example.com" "curl/7.68.0" rt=2.345 uct="0.010" uht="0.050" urt="2.340"
```

表示：
- 总请求时间: 2.345秒
- 连接后端用时: 0.010秒
- 后端响应头用时: 0.050秒
- 后端完整响应用时: 2.340秒

---

## 🔧 故障排查

### 问题 1: SSL 证书申请失败

**症状：**
```
Let's Encrypt 证书申请失败
降级为自签名证书
```

**排查步骤：**
```bash
# 1. 检查 DNS 解析
dig +short newapi.tunecoder.example.com
# 应返回 CN2 VPS 的 IP

# 2. 检查 80 端口是否开放
netstat -tlnp | grep :80

# 3. 测试 ACME 验证路径
curl http://newapi.tunecoder.example.com/.well-known/acme-challenge/test

# 4. 查看 acme.sh 日志
cat ~/.acme.sh/acme.sh.log

# 5. 手动重试
./apply_ssl_cn2.sh -d newapi.tunecoder.example.com
```

---

### 问题 2: 502 Bad Gateway

**症状：**
```
访问 https://newapi.tunecoder.example.com 返回 502
```

**排查步骤：**
```bash
# 1. 检查性能服务器是否可访问
curl -I https://api.tunecoder.example.com
# 应返回 200

# 2. 检查防火墙
iptables -L -n | grep 443

# 3. 测试后端连接
curl -v https://api.tunecoder.example.com 2>&1 | grep "Connected"

# 4. 查看 Nginx 错误日志
tail -50 /var/log/nginx/newapi_proxy_error.log

# 5. 测试 DNS 解析
nslookup api.tunecoder.example.com
```

---

### 问题 3: 请求超时

**症状：**
```
AI 长响应时被中断
curl: (28) Operation timed out
```

**排查步骤：**
```bash
# 1. 检查超时配置
grep "timeout" /usr/local/nginx/conf/conf.d/newapi.tunecoder.example.com.conf

# 应看到:
# proxy_read_timeout 600s;
# proxy_send_timeout 600s;

# 2. 如果超时配置不正确，修改配置
nano /usr/local/nginx/conf/conf.d/newapi.tunecoder.example.com.conf

# 找到并修改为:
proxy_read_timeout 600s;
proxy_send_timeout 600s;

# 3. 重载 Nginx
nginx -t && systemctl reload nginx
```

---

### 问题 4: SSE 流式传输不工作

**症状：**
```
流式响应被缓冲，无法实时显示
```

**排查步骤：**
```bash
# 1. 检查缓冲配置
grep "buffering" /usr/local/nginx/conf/conf.d/newapi.tunecoder.example.com.conf

# 应看到:
# proxy_buffering off;
# proxy_cache off;
# proxy_request_buffering off;

# 2. 检查是否有 gzip 压缩干扰
grep "gzip" /usr/local/nginx/conf/nginx.conf

# 3. 添加调试头
curl -I https://newapi.tunecoder.example.com/v1/chat/completions \
  -H "Authorization: Bearer YOUR_API_KEY" \
  | grep "X-Accel-Buffering"

# 应返回: X-Accel-Buffering: no
```

---

## 🔐 安全建议

### 1. 限制访问来源（可选）

如果只允许特定 IP 访问，在 Nginx 配置中添加：

```nginx
location / {
    # 允许特定 IP
    allow 1.2.3.4;
    # 拒绝其他
    deny all;

    proxy_pass https://api.tunecoder.example.com;
    # ... 其他配置 ...
}
```

### 2. 启用访问日志分析

```bash
# 安装 GoAccess（实时日志分析工具）
apt-get install goaccess  # Debian/Ubuntu
yum install goaccess      # CentOS/RHEL

# 实时分析访问日志
goaccess /var/log/nginx/newapi_proxy_access.log -o report.html --real-time-html

# 在浏览器中打开 report.html 查看实时统计
```

### 3. 定期备份配置

```bash
# 备份 Nginx 配置
tar -czf nginx_config_backup_$(date +%Y%m%d).tar.gz \
  /usr/local/nginx/conf/

# 备份 SSL 证书
tar -czf ssl_certs_backup_$(date +%Y%m%d).tar.gz \
  /usr/local/nginx/conf/ssl/
```

---

## 📈 性能优化（可选）

### 1. 启用 Brotli 压缩

Brotli 比 gzip 压缩率更高，但需要编译 Nginx 模块。

### 2. 配置缓存（仅限静态资源）

**注意：** 不要对 API 端点启用缓存！

```nginx
# 仅对管理界面静态资源缓存
location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
    proxy_pass https://api.tunecoder.example.com;
    proxy_cache_valid 200 1h;
    add_header X-Cache-Status $upstream_cache_status;
}
```

### 3. 启用 TCP BBR（需要内核支持）

```bash
# 检查是否支持 BBR
sysctl net.ipv4.tcp_congestion_control

# 如果支持，启用 BBR
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
```

---

## 📚 附录

### 配置文件位置

```
CN2 VPS:
├── /usr/local/nginx/conf/nginx.conf (主配置)
├── /usr/local/nginx/conf/conf.d/newapi.tunecoder.example.com.conf (反向代理配置)
├── /usr/local/nginx/conf/ssl/newapi.tunecoder.example.com/ (SSL 证书)
└── /var/log/nginx/ (日志目录)
    ├── newapi_proxy_access.log
    └── newapi_proxy_error.log

性能服务器:
├── /usr/local/nginx/conf/conf.d/api.tunecoder.example.com.conf (New-API)
├── /usr/local/nginx/conf/conf.d/litellm.tunecoder.example.com.conf (LiteLLM)
├── /usr/local/nginx/conf/conf.d/cliproxyapi.tunecoder.example.com.conf (CliproxyAPI)
└── /usr/local/nginx/conf/ssl/ (SSL 证书)
    ├── api.tunecoder.example.com/
    ├── litellm.tunecoder.example.com/
    └── cliproxyapi.tunecoder.example.com/
```

### 常用命令速查

```bash
# Nginx 管理
systemctl status nginx
systemctl reload nginx
nginx -t
nginx -V

# 日志查看
tail -f /var/log/nginx/newapi_proxy_access.log
tail -f /var/log/nginx/newapi_proxy_error.log

# SSL 证书
~/.acme.sh/acme.sh --list
~/.acme.sh/acme.sh --renew -d newapi.tunecoder.example.com --ecc

# 测试连接
curl -I https://newapi.tunecoder.example.com
curl -v https://api.tunecoder.example.com
dig +short newapi.tunecoder.example.com

# 性能测试
ab -n 100 -c 10 https://newapi.tunecoder.example.com/
```

---

## ✅ 部署验证清单

完成以下检查确认部署成功：

- [ ] DNS 解析正确（newapi.tunecoder.example.com → CN2 VPS IP）
- [ ] SSL 证书申请成功（Let's Encrypt 或自签名）
- [ ] Nginx 配置语法正确（`nginx -t` 通过）
- [ ] 反向代理响应正常（`curl -I https://newapi.tunecoder.example.com` 返回 200/401）
- [ ] SSE 流式传输配置正确（`proxy_buffering off`）
- [ ] 超时配置正确（`proxy_read_timeout 600s`）
- [ ] 日志文件正常写入
- [ ] 性能服务器可访问（`curl -I https://api.tunecoder.example.com`）
- [ ] API 调用测试通过（使用 API Key 测试）

---

## 🆘 获取帮助

如果遇到问题：

1. 运行测试脚本：`./test_proxy.sh`
2. 查看错误日志：`tail -50 /var/log/nginx/newapi_proxy_error.log`
3. 检查 Nginx 配置：`nginx -t`
4. 测试后端连接：`curl -v https://api.tunecoder.example.com`

---

**部署完成后，您的用户可以通过 CN2 线路访问：**
- API Base URL: `https://newapi.tunecoder.example.com`
- 享受 CN2 线路的低延迟和高稳定性
- 支持 SSE 流式传输和超长响应（600秒）
