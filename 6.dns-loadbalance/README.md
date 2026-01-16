# 多CN2 VPS协同分流 - DNS轮询方案

## 📋 方案概述

### 架构图

```
                        ┌─────────────────────────────────┐
                        │     DNS服务器（Cloudflare）      │
                        │  newapi.tunecoder.example.com           │
                        │                                 │
                        │  A记录1: 1.2.3.4  (CN2-上海)    │
                        │  A记录2: 5.6.7.8  (CN2-广州)    │
                        │  A记录3: 9.10.11.12 (CN2-深圳)  │
                        └───────────┬─────────────────────┘
                                    │ DNS轮询返回不同IP
                 ┌──────────────────┼──────────────────┐
                 │                  │                  │
                 ▼                  ▼                  ▼
        ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
        │  CN2 VPS-1      │ │  CN2 VPS-2      │ │  CN2 VPS-3      │
        │  上海 1.2.3.4   │ │  广州 5.6.7.8   │ │  深圳 9.10.11.12│
        │                 │ │                 │ │                 │
        │  Nginx 反向代理  │ │  Nginx 反向代理  │ │  Nginx 反向代理  │
        └────────┬────────┘ └────────┬────────┘ └────────┬────────┘
                 │                   │                   │
                 └───────────────────┼───────────────────┘
                                     ▼
                        ┌─────────────────────────────────┐
                        │      性能服务器                   │
                        │   https://api.tunecoder.example.com     │
                        │                                 │
                        │  ┌──────────┐  ┌──────────┐    │
                        │  │ New-API  │  │ LiteLLM  │    │
                        │  │  (3000)  │  │  (4000)  │    │
                        │  └──────────┘  └──────────┘    │
                        └─────────────────────────────────┘
```

### 工作原理

1. **DNS解析轮询**：用户访问 `newapi.tunecoder.example.com` 时，DNS服务器轮流返回3个CN2 VPS的IP地址
2. **流量自然分散**：不同用户/不同时间会被分配到不同的CN2节点
3. **各自独立代理**：每台CN2 VPS独立运行Nginx反向代理，转发到性能服务器

### 优缺点对比

#### ✅ 优点

1. **配置极其简单**
   - 只需在DNS添加多条A记录
   - 每台CN2部署完全相同的配置

2. **零额外成本**
   - 无需购买负载均衡服务
   - 无需额外硬件

3. **自动流量分散**
   - DNS自动轮询分配
   - 无需手动干预

4. **易于扩展**
   - 添加新CN2节点只需加一条A记录
   - 移除节点直接删除A记录

#### ❌ 缺点

1. **无健康检查**
   - 宕机的VPS仍会被DNS解析
   - 约1/3用户会访问失败

2. **故障切换慢**
   - 依赖DNS TTL（通常5分钟）
   - 客户端可能缓存DNS长达数小时

3. **无会话保持**
   - 同一用户可能被分配到不同VPS
   - 对有状态应用不友好

4. **分布不均**
   - DNS缓存导致某些节点负载高
   - 无法根据性能动态调整

#### 适用场景

- ✅ 预算有限，追求极简
- ✅ 用户分散，无会话依赖
- ✅ 对可用性要求不极端高（95%即可）
- ✅ 快速上线，后续可升级到方案2/3

---

## 🚀 部署流程

### 前置条件检查

**性能服务器（已完成）：**
- ✅ 已部署 New-API (api.tunecoder.example.com)
- ✅ 已部署 LiteLLM (litellm.tunecoder.example.com)
- ✅ 已部署 CliproxyAPI (cliproxyapi.tunecoder.example.com)

**CN2 VPS准备：**
- ✅ 准备3台CN2 VPS（可以是1台、2台或更多）
- ✅ 每台都已安装 Nginx 1.28.1 + HTTP/3
- ✅ DNS可以添加多条A记录

---

### 第一步：配置DNS多条A记录

#### 1.1 登录DNS服务商

以Cloudflare为例（其他DNS服务商类似）：

登录 Cloudflare → 选择域名 `tunecoder.example.com` → DNS

#### 1.2 添加多条A记录

**配置示例：**

| 类型 | 名称 | 内容（IPv4地址） | 代理状态 | TTL |
|------|------|-----------------|---------|-----|
| A | newapi | 1.2.3.4 | 🌑 仅DNS | 自动 |
| A | newapi | 5.6.7.8 | 🌑 仅DNS | 自动 |
| A | newapi | 9.10.11.12 | 🌑 仅DNS | 自动 |

**重要配置说明：**

1. **名称相同**：所有记录的名称都是 `newapi`
2. **代理状态**：必须是灰色云朵（仅DNS），不能启用橙色云（Cloudflare代理）
3. **TTL**：建议设置为 `300`（5分钟）或 `自动`

#### 1.3 验证DNS配置

```bash
# 查询DNS记录（应返回3个IP）
dig +short newapi.tunecoder.example.com

# 输出示例：
# 1.2.3.4
# 5.6.7.8
# 9.10.11.12

# 多次查询，观察IP顺序是否变化
for i in {1..5}; do
  echo "=== 第${i}次查询 ==="
  dig +short newapi.tunecoder.example.com
  sleep 2
done
```

如果看到3个IP地址，说明DNS配置成功！

---

### 第二步：在每台CN2 VPS上部署

每台CN2 VPS的部署**完全相同**，这里以CN2-1为例：

#### 2.1 上传部署脚本

```bash
# 在本地Windows上，将部署文件上传到CN2-1
scp -r "5.cn2-vps反向代理" root@1.2.3.4:/root/

# SSH登录到CN2-1
ssh root@1.2.3.4
```

#### 2.2 申请SSL证书

```bash
cd /root/5.cn2-vps反向代理

# 赋予执行权限
chmod +x apply_ssl_cn2.sh

# 申请证书（每台CN2都需要申请相同域名的证书）
./apply_ssl_cn2.sh -d newapi.tunecoder.example.com
```

**重要说明：**
- 每台CN2都需要为 `newapi.tunecoder.example.com` 申请独立的SSL证书
- Let's Encrypt允许同一域名在不同服务器上申请证书
- 证书申请时会通过DNS验证域名所有权

#### 2.3 配置Nginx主配置（仅需一次）

编辑 `/usr/local/nginx/conf/nginx.conf`，在 `http {}` 块中添加：

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

测试配置：
```bash
/usr/local/nginx/sbin/nginx -t
```

#### 2.4 部署反向代理配置

```bash
cd /root/5.cn2-vps反向代理

# 复制配置文件
cp nginx_newapi_proxy.conf /usr/local/nginx/conf/conf.d/newapi.tunecoder.example.com.conf

# 测试配置
/usr/local/nginx/sbin/nginx -t

# 重载Nginx
systemctl reload nginx
```

#### 2.5 验证部署

```bash
# 运行测试脚本
chmod +x test_proxy.sh
./test_proxy.sh

# 手动测试
curl -I https://newapi.tunecoder.example.com
# 应返回 200 或 401 (需要认证)
```

#### 2.6 在CN2-2和CN2-3上重复步骤2.1-2.5

**在CN2-2上：**
```bash
# 上传
scp -r "5.cn2-vps反向代理" root@5.6.7.8:/root/

# SSH登录
ssh root@5.6.7.8

# 执行相同的步骤2.2-2.5
cd /root/5.cn2-vps反向代理
./apply_ssl_cn2.sh -d newapi.tunecoder.example.com
# ... 后续步骤完全相同
```

**在CN2-3上：**
```bash
# 上传
scp -r "5.cn2-vps反向代理" root@9.10.11.12:/root/

# SSH登录
ssh root@9.10.11.12

# 执行相同的步骤2.2-2.5
cd /root/5.cn2-vps反向代理
./apply_ssl_cn2.sh -d newapi.tunecoder.example.com
# ... 后续步骤完全相同
```

---

### 第三步：验证DNS轮询效果

#### 3.1 测试DNS解析轮询

```bash
# 多次解析，观察返回的IP是否轮换
for i in {1..10}; do
  echo "=== 第${i}次 ==="
  dig +short newapi.tunecoder.example.com
  echo ""
  sleep 1
done
```

#### 3.2 测试HTTP请求分布

创建测试脚本 `test_dns_roundrobin.sh`：

```bash
#!/bin/bash

echo "测试DNS轮询分布（发送100个请求）"
echo "================================"

declare -A ip_count

for i in {1..100}; do
  # 解析域名获取IP
  ip=$(dig +short newapi.tunecoder.example.com | head -1)

  # 统计
  ((ip_count[$ip]++))

  # 清除DNS缓存（Linux）
  # systemd-resolve --flush-caches 2>/dev/null || true

  sleep 0.1
done

echo ""
echo "请求分布统计："
echo "================================"
for ip in "${!ip_count[@]}"; do
  echo "$ip: ${ip_count[$ip]} 次"
done
```

运行测试：
```bash
chmod +x test_dns_roundrobin.sh
./test_dns_roundrobin.sh
```

**预期输出：**
```
请求分布统计：
================================
1.2.3.4: 33 次
5.6.7.8: 34 次
9.10.11.12: 33 次
```

#### 3.3 测试实际API调用

```bash
# 在性能服务器的New-API管理台创建API Key
# 访问: https://api.tunecoder.example.com

# 使用CN2域名测试（多次请求）
for i in {1..5}; do
  echo "=== 第${i}次请求 ==="
  curl https://newapi.tunecoder.example.com/v1/models \
    -H "Authorization: Bearer YOUR_API_KEY" \
    -w "\nIP: %{remote_ip}\n\n"
done
```

---

## 📊 监控和管理

### 1. 查看各节点日志

**在CN2-1上：**
```bash
tail -f /var/log/nginx/newapi_proxy_access.log
```

**在CN2-2上：**
```bash
tail -f /var/log/nginx/newapi_proxy_access.log
```

**在CN2-3上：**
```bash
tail -f /var/log/nginx/newapi_proxy_access.log
```

### 2. 统计流量分布

在每台CN2上运行：

```bash
# 统计今天的请求总数
grep "$(date +%d/%b/%Y)" /var/log/nginx/newapi_proxy_access.log | wc -l

# 统计最近1小时的请求数
awk -v d="$(date +%d/%b/%Y:%H)" '$0 ~ d' /var/log/nginx/newapi_proxy_access.log | wc -l
```

### 3. 手动调整DNS权重（模拟）

DNS轮询无法真正控制权重，但可以通过添加多条相同IP记录来实现：

**示例：让CN2-1承担更多流量**
```
类型  名称     内容
A     newapi   1.2.3.4  (CN2-1)
A     newapi   1.2.3.4  (CN2-1) ← 重复
A     newapi   5.6.7.8  (CN2-2)
A     newapi   9.10.11.12 (CN2-3)
```

理论上CN2-1会收到约50%流量（实际效果取决于DNS服务器实现）。

---

## 🔧 故障处理

### 场景1: 单台CN2宕机

**症状：**
```
部分用户（约33%）访问失败
错误: Connection refused 或 Timeout
```

**临时解决：**
```bash
# 方法1: 删除故障节点的DNS记录
# 登录DNS管理后台，删除故障IP的A记录

# 方法2: 等待DNS缓存过期（不推荐）
# 用户需等待5-60分钟，DNS缓存自然过期后不再访问故障节点
```

**永久修复：**
```bash
# 1. SSH登录故障节点
ssh root@<故障IP>

# 2. 检查Nginx状态
systemctl status nginx

# 3. 查看错误日志
tail -50 /var/log/nginx/newapi_proxy_error.log

# 4. 重启Nginx
systemctl restart nginx

# 5. 验证恢复
curl -I https://newapi.tunecoder.example.com

# 6. 如果修复成功，重新添加DNS记录
```

---

### 场景2: 性能服务器宕机

**症状：**
```
所有CN2节点都返回 502 Bad Gateway
```

**排查步骤：**
```bash
# 在任一CN2节点上测试
curl -I https://api.tunecoder.example.com

# 如果无法访问，登录性能服务器检查
ssh root@<性能服务器IP>

# 检查服务状态
systemctl status nginx
cd /opt/docker-services/new-api && docker compose ps
```

---

### 场景3: SSL证书过期

**症状：**
```
浏览器提示证书过期
curl: (60) SSL certificate problem
```

**解决方法：**

```bash
# 在受影响的CN2节点上

# 1. 检查证书有效期
openssl x509 -in /usr/local/nginx/conf/ssl/newapi.tunecoder.example.com/fullchain.pem \
  -noout -dates

# 2. 手动续期
~/.acme.sh/acme.sh --renew -d newapi.tunecoder.example.com --ecc --force

# 3. 重载Nginx
systemctl reload nginx

# 4. 验证
curl -I https://newapi.tunecoder.example.com
```

**预防措施：**
```bash
# acme.sh自动续期已配置cron，检查是否正常
crontab -l | grep acme

# 输出示例：
# 0 0 * * * "/root/.acme.sh"/acme.sh --cron --home "/root/.acme.sh" > /dev/null
```

---

### 场景4: DNS未生效

**症状：**
```
dig命令只返回1个IP，或返回错误IP
```

**排查步骤：**
```bash
# 1. 检查DNS传播
dig @8.8.8.8 newapi.tunecoder.example.com  # Google DNS
dig @1.1.1.1 newapi.tunecoder.example.com  # Cloudflare DNS

# 2. 检查本地DNS缓存
# Linux
systemd-resolve --flush-caches

# macOS
sudo dscacheutil -flushcache

# Windows
ipconfig /flushdns

# 3. 等待DNS传播（最多24小时，通常几分钟）
```

---

## 🎯 优化建议

### 1. 降低DNS TTL

在DNS配置中将TTL设置为较低值：

```
TTL: 300 (5分钟)   # 推荐
或
TTL: 60 (1分钟)    # 更快故障切换，但增加DNS查询量
```

**优点：** 节点故障时，客户端更快切换到健康节点
**缺点：** 增加DNS查询负载

---

### 2. 客户端DNS缓存控制

在Nginx响应头中添加：

```nginx
# 编辑 /usr/local/nginx/conf/conf.d/newapi.tunecoder.example.com.conf

location / {
    # ... 现有配置 ...

    # 减少客户端DNS缓存
    add_header X-DNS-Prefetch-Control "on";

    # ... 现有配置 ...
}
```

---

### 3. 定期健康巡检

创建定时任务，定期检查所有CN2节点：

**`health_check_cron.sh`**
```bash
#!/bin/bash

NODES=(
  "1.2.3.4:CN2-上海"
  "5.6.7.8:CN2-广州"
  "9.10.11.12:CN2-深圳"
)

for node in "${NODES[@]}"; do
  IP="${node%%:*}"
  NAME="${node##*:}"

  if curl -sf --max-time 5 "https://$IP/health-proxy" > /dev/null; then
    echo "[OK] $NAME ($IP) 正常"
  else
    echo "[FAIL] $NAME ($IP) 异常！需要检查"
    # 可以发送告警邮件或Webhook
  fi
done
```

添加到cron：
```bash
# 每5分钟检查一次
*/5 * * * * /root/health_check_cron.sh >> /var/log/health_check.log 2>&1
```

---

### 4. 启用HTTP/3（已支持）

所有CN2节点已配置HTTP/3，客户端支持时会自动使用QUIC协议，降低延迟。

验证：
```bash
# 使用支持HTTP/3的curl测试
curl --http3 -I https://newapi.tunecoder.example.com
```

---

## 📈 性能测试

### 1. 并发测试

```bash
# 安装Apache Bench
apt-get install apache2-utils  # Debian/Ubuntu
yum install httpd-tools         # CentOS

# 测试100并发，1000请求
ab -n 1000 -c 100 https://newapi.tunecoder.example.com/

# 观察：
# - Requests per second （每秒请求数）
# - Time per request （平均响应时间）
# - Failed requests （失败请求数，应为0）
```

### 2. 延迟测试

在不同地区测试延迟：

```bash
# 使用ping测试到各CN2节点的延迟
ping -c 10 1.2.3.4
ping -c 10 5.6.7.8
ping -c 10 9.10.11.12

# 使用curl测试HTTP延迟
curl -o /dev/null -s -w "Total: %{time_total}s\n" https://newapi.tunecoder.example.com/
```

---

## 📋 部署检查清单

部署完成后，确认以下项目：

- [ ] DNS配置：3条A记录已添加，TTL设置为300秒
- [ ] DNS解析：`dig +short newapi.tunecoder.example.com` 返回3个IP
- [ ] CN2-1部署：SSL证书、Nginx配置、测试通过
- [ ] CN2-2部署：SSL证书、Nginx配置、测试通过
- [ ] CN2-3部署：SSL证书、Nginx配置、测试通过
- [ ] 健康检查：所有节点 `/health-proxy` 返回200
- [ ] API测试：使用API Key测试成功
- [ ] 日志记录：所有节点日志正常写入
- [ ] DNS轮询：多次请求分布均匀

---

## 🔄 后续升级路径

如果DNS轮询方案无法满足需求，可以平滑升级：

### 升级到Cloudflare负载均衡（方案2）

**优点：** 健康检查、自动故障切换、地理路由
**成本：** ~$5/月
**迁移难度：** 低（只需修改DNS配置）

### 升级到Nginx负载均衡（方案3）

**优点：** 完全自主控制、高级路由
**成本：** 1台额外VPS
**迁移难度：** 中（需部署负载均衡器）

---

## 总结

**DNS轮询方案适合：**
- ✅ 快速上线，控制成本
- ✅ 用户分散，无状态服务
- ✅ 对可用性要求95%即可
- ✅ 技术团队经验有限

**关键限制：**
- ⚠️ 无健康检查（节点故障约1/3用户受影响）
- ⚠️ 故障切换慢（5-60分钟）
- ⚠️ 无法精确控制流量分配

**推荐策略：**
- 先用DNS轮询快速上线
- 积累经验和流量数据
- 根据实际需求决定是否升级到方案2/3
