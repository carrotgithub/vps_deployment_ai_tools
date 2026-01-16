# LiteLLM - 统一 LLM API 代理服务器

> 收集自 BerriAI/litellm GitHub 仓库
> 项目地址: https://github.com/BerriAI/litellm

## 项目概述

LiteLLM 是一个开源的 LLM（大语言模型）API 代理服务器，提供统一的接口来访问多个 AI 模型提供商。它允许你使用 OpenAI 兼容的 API 格式调用 100+ 不同的 LLM 模型。

## 主要特性

### 核心功能

1. **统一 API 接口**
   - OpenAI 兼容的 API 格式
   - 支持 100+ LLM 模型（OpenAI, Anthropic Claude, Google Gemini, Azure, AWS Bedrock 等）
   - 统一的请求/响应格式，简化多模型集成

2. **负载均衡与高可用**
   - 多个 API 密钥的负载均衡
   - 自动故障转移（Fallback）
   - 健康检查和自动重试
   - 跨提供商的智能路由

3. **成本控制与监控**
   - API 使用量跟踪
   - 预算限制和警报
   - 详细的使用统计
   - 成本分析和优化建议

4. **安全与认证**
   - Master Key 认证
   - 虚拟密钥（Virtual Keys）管理
   - 基于团队/项目的权限控制
   - API 密钥加密存储

5. **性能优化**
   - 响应缓存（Redis/内存）
   - 请求速率限制
   - 流式响应支持
   - WebSocket 支持

6. **企业级功能**
   - PostgreSQL 数据库集成
   - 日志记录和审计
   - Prometheus 指标导出
   - SSO 集成支持

## Docker 部署

### Docker 镜像信息

**官方镜像:**
- 镜像仓库: `ghcr.io/berriai/litellm`
- 最新版本: `ghcr.io/berriai/litellm:main-latest`
- 稳定版本: `ghcr.io/berriai/litellm:main-stable`

**默认端口:** `4000`

### 快速启动

#### 方式 1: 简单 Docker 运行

```bash
docker run -p 4000:4000 \
  -e LITELLM_MASTER_KEY=your-secret-key \
  ghcr.io/berriai/litellm:main-latest
```

#### 方式 2: 使用配置文件

```bash
docker run -p 4000:4000 \
  -v $(pwd)/config.yaml:/app/config.yaml \
  -e LITELLM_MASTER_KEY=your-secret-key \
  ghcr.io/berriai/litellm:main-latest \
  --config /app/config.yaml
```

#### 方式 3: Docker Compose（推荐生产环境）

参见 `docker-compose.yml` 文件

### 核心环境变量

| 环境变量 | 说明 | 必需 | 默认值 |
|---------|------|------|--------|
| `LITELLM_MASTER_KEY` | 主 API 密钥，用于认证 | 推荐 | - |
| `DATABASE_URL` | PostgreSQL 数据库连接字符串 | 可选 | - |
| `STORE_MODEL_IN_DB` | 是否将模型配置存储在数据库中 | 可选 | `False` |
| `REDIS_HOST` | Redis 主机地址（用于缓存） | 可选 | - |
| `REDIS_PORT` | Redis 端口 | 可选 | `6379` |
| `REDIS_PASSWORD` | Redis 密码 | 可选 | - |

### 模型提供商 API 密钥

```bash
# OpenAI
OPENAI_API_KEY=sk-...

# Anthropic Claude
ANTHROPIC_API_KEY=sk-ant-...

# Google Gemini
GEMINI_API_KEY=...

# Azure OpenAI
AZURE_API_KEY=...
AZURE_API_BASE=https://....openai.azure.com/
AZURE_API_VERSION=2024-02-15-preview

# AWS Bedrock
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION_NAME=us-east-1
```

## 数据库要求

### PostgreSQL（可选，推荐生产环境）

**用途:**
- 存储模型配置
- 用户和虚拟密钥管理
- API 使用统计和日志
- 预算跟踪

**连接格式:**
```
DATABASE_URL=postgresql://username:password@host:port/database
```

**最低版本:** PostgreSQL 12+

### Redis（可选，用于缓存）

**用途:**
- 响应缓存
- 速率限制
- 会话管理

**连接配置:**
```bash
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=your-password
```

## 配置文件示例

参见 `config.yaml` 文件获取完整配置示例

## API 端点

### 标准 OpenAI 兼容端点

- `POST /chat/completions` - 聊天补全
- `POST /completions` - 文本补全
- `POST /embeddings` - 文本嵌入
- `GET /models` - 列出可用模型
- `POST /moderations` - 内容审核

### LiteLLM 管理端点

- `GET /health` - 健康检查
- `GET /health/readiness` - 就绪检查
- `GET /health/liveness` - 存活检查
- `POST /key/generate` - 生成虚拟密钥
- `GET /key/info` - 查询密钥信息
- `POST /user/new` - 创建用户
- `GET /spend/tags` - 查询支出统计

## 使用示例

### 基本请求

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer your-litellm-master-key" \
  -d '{
    "model": "gpt-3.5-turbo",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### 使用不同模型

```bash
# 使用 Claude
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer your-litellm-master-key" \
  -d '{
    "model": "claude-3-opus-20240229",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# 使用 Gemini
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer your-litellm-master-key" \
  -d '{
    "model": "gemini/gemini-pro",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## 生产部署建议

### 安全性

1. **强制使用 MASTER_KEY**
   - 设置强密码
   - 使用环境变量而非配置文件
   - 定期轮换密钥

2. **使用 HTTPS**
   - 通过 Nginx 反向代理
   - 配置 SSL 证书
   - 启用 HSTS

3. **数据库安全**
   - 使用强密码
   - 限制网络访问
   - 启用 SSL 连接

### 性能优化

1. **启用缓存**
   - Redis 缓存响应
   - 设置合理的 TTL
   - 监控缓存命中率

2. **负载均衡**
   - 配置多个 API 密钥
   - 设置权重分配
   - 启用健康检查

3. **资源限制**
   - 设置速率限制
   - 配置预算控制
   - 监控 CPU/内存使用

### 监控与日志

1. **启用详细日志**
   ```yaml
   litellm_settings:
     set_verbose: true
     json_logs: true
   ```

2. **Prometheus 指标**
   - 启用 `/metrics` 端点
   - 配置 Grafana 仪表板
   - 设置告警规则

3. **数据库监控**
   - 查询性能
   - 连接池状态
   - 存储使用量

## 常见问题

### 如何添加自定义模型？

编辑 `config.yaml`:
```yaml
model_list:
  - model_name: my-custom-model
    litellm_params:
      model: openai/gpt-4
      api_key: sk-...
```

### 如何设置速率限制？

```yaml
litellm_settings:
  rpm: 100  # 每分钟请求数
  tpm: 100000  # 每分钟 token 数
```

### 如何启用缓存？

```yaml
litellm_settings:
  cache: true
  cache_params:
    type: redis
    host: localhost
    port: 6379
```

## 资源链接

- 官方文档: https://docs.litellm.ai/
- GitHub 仓库: https://github.com/BerriAI/litellm
- Docker Hub: https://github.com/BerriAI/litellm/pkgs/container/litellm
- Discord 社区: https://discord.com/invite/wuPM9dRgDw
- 问题反馈: https://github.com/BerriAI/litellm/issues

## 许可证

MIT License - 详见项目仓库

---

**收集时间:** 2026-01-05
**文档版本:** 基于 main-latest 分支
