# Cloudflare DNS 配置指南

> 本文档介绍如何在 Cloudflare 上为 VPS 服务配置域名解析，适用于需要 SSL 证书申请的场景。

---

## 前置条件

- 一个已注册的域名
- Cloudflare 账号（免费版即可）
- 域名的 NS 记录已指向 Cloudflare

---

## 步骤一：添加域名到 Cloudflare

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com)
2. 点击 **Add a site**，输入你的域名（如 `example.com`）
3. 选择 **Free** 计划
4. Cloudflare 会扫描现有 DNS 记录，确认后点击 **Continue**
5. 按提示到域名注册商处修改 NS 记录为 Cloudflare 提供的值

---

## 步骤二：添加 A 记录

为每个服务创建对应的子域名解析：

1. 进入域名的 **DNS → Records** 页面
2. 点击 **Add record**
3. 填写以下信息：

| 字段 | 值 | 说明 |
|------|-----|------|
| Type | `A` | IPv4 地址记录 |
| Name | `newapi` | 子域名前缀（最终为 `newapi.example.com`） |
| IPv4 address | `1.2.3.4` | 你的 VPS 服务器 IP |
| Proxy status | **DNS only** (灰色云朵) | 见下方说明 |
| TTL | `Auto` | 自动管理 |

常见子域名配置示例：

```
newapi.example.com  → A → VPS_IP  (New-API)
api.example.com     → A → VPS_IP  (CliproxyAPI)
proxy.example.com   → A → VPS_IP  (V2Ray)
```

---

## 步骤三：关闭 Proxy（重要）

申请 Let's Encrypt SSL 证书时，**必须将 Proxy status 设为 DNS only**（灰色云朵图标）。

原因：
- Let's Encrypt 需要直接访问你的服务器 80 端口进行验证
- Cloudflare 的橙色云朵（Proxied）会拦截验证请求，导致证书申请失败

操作方法：
1. 点击对应记录右侧的橙色云朵图标
2. 切换为灰色云朵（DNS only）
3. 等待 DNS 生效（通常几秒到几分钟）

> **提示**：SSL 证书申请成功后，如果需要使用 Cloudflare CDN，可以再切回 Proxied 模式，但需要在 Cloudflare SSL 设置中选择 **Full (strict)** 模式。

---

## 步骤四：验证 DNS 解析

在服务器上执行：

```bash
# 检查解析是否生效
dig +short newapi.example.com

# 应返回你的 VPS IP，例如：
# 1.2.3.4
```

如果返回空或错误 IP，等待几分钟后重试，或检查：
- NS 记录是否已切换到 Cloudflare
- A 记录是否填写正确
- Proxy status 是否为 DNS only

---

## 常见问题

### 1. 证书申请报错 "DNS problem: NXDOMAIN"

域名解析尚未生效。检查：
```bash
dig +short your-domain.com
# 如果无输出，说明 DNS 未生效
```

等待 DNS 传播（最长 48 小时，通常几分钟）。

### 2. 证书申请报错 "Connection refused" 或 "Timeout"

- 确认 Proxy status 为 **DNS only**（灰色云朵）
- 确认服务器防火墙已开放 80 端口
- 确认 Nginx 正在运行：`systemctl status nginx`

### 3. 是否可以使用 Cloudflare 的免费 SSL？

可以，但本项目脚本默认使用 Let's Encrypt 证书。如果想用 Cloudflare 的 Origin Certificate：

1. 在 Cloudflare **SSL/TLS → Origin Server** 中创建证书
2. 下载证书和私钥
3. 放到 `/usr/local/nginx/conf/ssl/{domain}/` 目录
4. 将 Cloudflare SSL 模式设为 **Full (strict)**

### 4. 多个子域名可以用通配符吗？

可以。添加一条 `*.example.com` 的 A 记录即可覆盖所有子域名。但 Let's Encrypt 通配符证书需要 DNS 验证（而非 HTTP 验证），配置更复杂，建议为每个子域名单独申请证书。

---

**最后更新**: 2026-02-23
