#!/bin/bash

################################################################################
#
# LiteLLM Docker 自动化部署脚本
#
# 功能说明：
#   1. 环境检查（Docker、Nginx、端口可用性）
#   2. 域名配置和 DNS 验证提示
#   3. 自动生成密码和密钥（MASTER_KEY、PostgreSQL、Redis）
#   4. 生成 docker-compose.yml 和 config.yaml
#   5. 拉取镜像并启动 Docker 服务
#   6. 申请 Let's Encrypt SSL 证书
#   7. 生成 Nginx 反向代理配置（支持 HTTP/3）
#   8. 输出完整部署信息到 litellm_info.txt
#
# 特点：
#   - 零配置部署：所有配置自动生成
#   - 安全优先：强密码、localhost 绑定、文件权限控制
#   - 生产就绪：SSL、HTTP/3、健康检查、自动重启
#
# 使用方法：
#   chmod +x install_litellm_docker.sh
#   ./install_litellm_docker.sh
#
################################################################################

# ==================== 全局配置 ====================

DOCKER_ROOT="/opt/docker-services"
SERVICE_DIR="$DOCKER_ROOT/litellm"
DATA_DIR="$SERVICE_DIR/data"
LOGS_DIR="$SERVICE_DIR/logs"
DOCKER_IMAGE="ghcr.io/berriai/litellm:main-latest"
LITELLM_PORT=4000
POSTGRES_PORT_EXTERNAL=5433  # 避免与 new-api 的 5432 冲突
REDIS_PORT_EXTERNAL=6380     # 避免与 new-api 的 6379 冲突
DOCKER_NETWORK="ai-services"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 日志函数 ====================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

# ==================== 密码生成函数 ====================

# 生成 LiteLLM Master Key（sk- 开头，48位）
generate_master_key() {
    local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local key="sk-"
    for i in {1..45}; do
        key="${key}${chars:$((RANDOM % ${#chars})):1}"
    done
    echo "$key"
}

# 生成普通密码（32位）
generate_password() {
    local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local password=""
    for i in {1..32}; do
        password="${password}${chars:$((RANDOM % ${#chars})):1}"
    done
    echo "$password"
}

# ==================== 环境检查 ====================

# 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
    log_error "必须使用 root 权限运行此脚本。"
    exit 1
fi

# 检查 Docker
if ! command -v docker &> /dev/null; then
    log_error "未检测到 Docker，请先安装 Docker"
    log_info "安装命令: curl -fsSL https://get.docker.com | sh"
    exit 1
fi

# 检查 docker-compose
if docker compose version &> /dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    log_error "未检测到 docker-compose，请先安装"
    exit 1
fi

log_success "Docker 环境检查通过"

# 检查 Nginx
if ! command -v /usr/local/nginx/sbin/nginx &> /dev/null; then
    log_error "未检测到 Nginx，请先部署 Nginx"
    log_info "运行: cd \"0.nginx部署（1.28.1 HTTP3）\" && ./install_nginx.sh"
    exit 1
fi

log_success "Nginx 检查通过"

# 检查端口占用
check_port() {
    if netstat -tlnp 2>/dev/null | grep -q ":$1 "; then
        return 1
    fi
    return 0
}

if ! check_port $LITELLM_PORT; then
    log_error "端口 $LITELLM_PORT 已被占用"
    netstat -tlnp | grep ":$LITELLM_PORT "
    exit 1
fi

log_success "端口检查通过"

# ==================== 欢迎横幅 ====================

clear
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}   LiteLLM Docker 自动化部署程序${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${GREEN}功能特性:${NC}"
echo "  • 统一 LLM API 代理（100+ 模型）"
echo "  • 负载均衡与故障转移"
echo "  • 虚拟密钥管理"
echo "  • 成本追踪与预算控制"
echo "  • Redis 缓存加速"
echo ""
echo -e "${YELLOW}部署架构:${NC}"
echo "  Nginx (HTTPS/HTTP3) → LiteLLM (4000) → PostgreSQL + Redis"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ==================== 配置输入 ====================

log_step "[1/8] 环境检查与配置输入"
echo ""

# 访问方式选择
echo -e "${CYAN}>>> 请选择访问方式${NC}"
echo ""
echo "  1) 使用域名（推荐）- 自动申请 Let's Encrypt 证书"
echo "  2) 使用 IP 地址   - 自签名证书，浏览器会提示不安全"
echo "  3) 仅使用 HTTP    - 无 SSL 证书，仅限内网/开发环境"
echo ""
read -p "请选择 [1/2/3]: " ACCESS_MODE

USE_DOMAIN=true
USE_HTTP_ONLY=false
if [ "$ACCESS_MODE" = "2" ]; then
    USE_DOMAIN=false
    # 自动获取服务器 IP
    SERVER_IP=$(curl -s --connect-timeout 5 https://api.ipify.org || curl -s --connect-timeout 5 https://ifconfig.me || hostname -I | awk '{print $1}')
    echo ""
    echo -e "检测到服务器 IP: ${GREEN}$SERVER_IP${NC}"
    read -p "确认使用此 IP？(y/n，或输入其他 IP): " IP_CONFIRM
    if [[ "$IP_CONFIRM" =~ ^[Yy]$ ]] || [ -z "$IP_CONFIRM" ]; then
        DOMAIN="$SERVER_IP"
    elif [[ "$IP_CONFIRM" =~ ^[Nn]$ ]]; then
        read -p "请输入 IP 地址: " DOMAIN
    else
        DOMAIN="$IP_CONFIRM"
    fi
elif [ "$ACCESS_MODE" = "3" ]; then
    USE_DOMAIN=false
    USE_HTTP_ONLY=true
    # 自动获取服务器 IP
    SERVER_IP=$(curl -s --connect-timeout 5 https://api.ipify.org || curl -s --connect-timeout 5 https://ifconfig.me || hostname -I | awk '{print $1}')
    echo ""
    echo -e "检测到服务器 IP: ${GREEN}$SERVER_IP${NC}"
    echo -e "${YELLOW}⚠️  HTTP 模式警告：${NC}"
    echo -e "${YELLOW}   - 数据传输不加密，API Key 可能泄露${NC}"
    echo -e "${YELLOW}   - 仅建议在内网或开发环境使用${NC}"
    echo ""
    read -p "确认使用此 IP？(y/n，或输入其他 IP): " IP_CONFIRM
    if [[ "$IP_CONFIRM" =~ ^[Yy]$ ]] || [ -z "$IP_CONFIRM" ]; then
        DOMAIN="$SERVER_IP"
    elif [[ "$IP_CONFIRM" =~ ^[Nn]$ ]]; then
        read -p "请输入 IP 地址: " DOMAIN
    else
        DOMAIN="$IP_CONFIRM"
    fi
else
    # 域名输入
    while true; do
        read -p "请输入 LiteLLM 访问域名（如 litellm.example.com）: " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            log_error "域名不能为空"
            continue
        fi
        if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
            log_error "域名格式不正确"
            continue
        fi
        break
    done
fi

if [ -z "$DOMAIN" ]; then
    log_error "域名/IP 不能为空"
    exit 1
fi

log_info "访问地址: $DOMAIN"
echo ""

# 生成随机密码
log_info "正在生成随机密码和密钥..."
MASTER_KEY=$(generate_master_key)
DB_PASSWORD=$(generate_password)
REDIS_PASSWORD=$(generate_password)

log_success "密码已生成（将保存到信息文件）"
echo ""

# DNS 配置提示 / IP 模式确认
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -s https://api.ipify.org 2>/dev/null || curl -s http://whatismyip.akamai.com 2>/dev/null || hostname -I | awk '{print $1}')
fi

if [ "$USE_DOMAIN" = true ]; then
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}⚠️  重要提示：请确保域名已解析${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "域名:   ${GREEN}$DOMAIN${NC}"
    echo -e "目标IP: ${GREEN}$SERVER_IP${NC}"
    echo ""
    echo -e "${YELLOW}[按回车键继续部署，Ctrl+C 取消]${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
else
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}⚠️  IP 模式注意事项${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "访问地址: ${GREEN}https://$DOMAIN${NC}"
    echo ""
    echo -e "${YELLOW}提示: 将使用自签名证书${NC}"
    echo -e "${YELLOW}访问时浏览器会提示「不安全」，请点击「高级」→「继续访问」${NC}"
    echo ""
    echo -e "${YELLOW}[按回车键继续部署，Ctrl+C 取消]${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi
read

# ==================== 创建目录结构 ====================

log_step "[2/8] 创建目录结构..."

mkdir -p "$DOCKER_ROOT"
mkdir -p "$SERVICE_DIR"
mkdir -p "$DATA_DIR/postgres"
mkdir -p "$DATA_DIR/redis"
mkdir -p "$LOGS_DIR"
mkdir -p "$SERVICE_DIR/backups"

log_success "目录创建完成"

# ==================== 生成 config.yaml ====================

log_step "[3/8] 生成 LiteLLM 配置文件..."

cat > "$SERVICE_DIR/config.yaml" <<EOF
# LiteLLM 配置文件
# 自动生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 域名: $DOMAIN

# ==================== 通用设置 ====================
general_settings:
  # Master Key（主认证密钥）
  master_key: "$MASTER_KEY"

  # 数据库连接
  database_url: "postgresql://litellm:$DB_PASSWORD@postgres:5432/litellm"

  # 启用数据库存储模型配置
  store_model_in_db: true

# ==================== 模型列表 ====================
# 默认为空，用户后续通过 Web API 或手动编辑添加
# 示例：
# model_list:
#   - model_name: gpt-4
#     litellm_params:
#       model: openai/gpt-4
#       api_key: sk-your-openai-key
#
#   - model_name: claude-3-opus
#     litellm_params:
#       model: anthropic/claude-3-opus-20240229
#       api_key: sk-ant-your-anthropic-key
#
#   - model_name: gemini-pro
#     litellm_params:
#       model: gemini/gemini-pro
#       api_key: your-gemini-key

model_list: []

# ==================== LiteLLM 核心设置 ====================
litellm_settings:
  # 启用详细日志
  set_verbose: true

  # JSON 格式日志
  json_logs: true

  # 启用缓存
  cache: true
  cache_params:
    type: redis
    host: redis
    port: 6379
    password: "$REDIS_PASSWORD"

  # 成功日志（用于调试）
  success_callback: []

  # 失败日志
  failure_callback: []

# ==================== 路由设置 ====================
router_settings:
  # 路由策略（负载均衡）
  # 可选: simple-shuffle, least-busy, usage-based-routing, latency-based-routing
  routing_strategy: least-busy

  # 模型组回退策略
  model_group_alias: {}

  # 超时设置（秒）
  timeout: 600

  # 流式响应超时
  stream_timeout: 600

  # 最大重试次数
  num_retries: 3

  # 允许的失败次数
  allowed_fails: 3

  # 冷却时间（秒）
  cooldown_time: 60

# ==================== 环境与监控 ====================
environment_variables: {}

# Prometheus 监控（可选）
# litellm_settings:
#   success_callback: ["prometheus"]

# Langfuse 追踪（可选）
# litellm_settings:
#   success_callback: ["langfuse"]
#   failure_callback: ["langfuse"]
EOF

# 设置文件权限（仅 root 可读写）
chmod 600 "$SERVICE_DIR/config.yaml"

log_success "config.yaml 已生成并设置权限 600"

# ==================== 生成 docker-compose.yml ====================

log_step "[4/8] 生成 Docker Compose 配置..."

cat > "$SERVICE_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  litellm:
    image: $DOCKER_IMAGE
    container_name: litellm
    restart: always
    ports:
      - "127.0.0.1:$LITELLM_PORT:4000"
    volumes:
      - ./config.yaml:/app/config.yaml:ro
      - ./logs:/app/logs
    command:
      - "--config"
      - "/app/config.yaml"
      - "--port"
      - "4000"
      - "--num_workers"
      - "4"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  postgres:
    image: postgres:15-alpine
    container_name: litellm-postgres
    restart: always
    environment:
      POSTGRES_DB: litellm
      POSTGRES_USER: litellm
      POSTGRES_PASSWORD: $DB_PASSWORD
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:$POSTGRES_PORT_EXTERNAL:5432"
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U litellm"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: litellm-redis
    restart: always
    command: redis-server --requirepass $REDIS_PASSWORD --appendonly yes
    volumes:
      - redis_data:/data
    ports:
      - "127.0.0.1:$REDIS_PORT_EXTERNAL:6379"
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "$REDIS_PASSWORD", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5

networks:
  $DOCKER_NETWORK:
    external: true

volumes:
  postgres_data:
    driver: local
  redis_data:
    driver: local
EOF

log_success "Docker Compose 配置已生成"

# ==================== 检查并创建共享网络 ====================

if ! docker network ls | grep -q "$DOCKER_NETWORK"; then
    log_info "创建共享 Docker 网络: $DOCKER_NETWORK"
    docker network create $DOCKER_NETWORK
    log_success "网络创建成功"
else
    log_info "共享网络 $DOCKER_NETWORK 已存在"
fi

# ==================== 拉取 Docker 镜像 ====================

log_step "[5/8] 拉取 Docker 镜像..."
log_info "正在拉取镜像（可能需要几分钟）..."

cd "$SERVICE_DIR"

if $COMPOSE_CMD pull; then
    log_success "镜像拉取完成"
else
    log_error "镜像拉取失败，请检查网络连接。"
    exit 1
fi

# ==================== 启动 Docker 服务 ====================

log_step "[6/8] 启动 Docker 服务..."

if $COMPOSE_CMD up -d; then
    log_success "Docker 服务启动成功"

    log_info "等待服务初始化（约 30 秒）..."
    sleep 30

    # 健康检查
    if $COMPOSE_CMD ps | grep -q "Up"; then
        log_success "服务运行正常"
    else
        log_error "服务启动异常，请查看日志"
        $COMPOSE_CMD logs --tail=50
        exit 1
    fi
else
    log_error "Docker 服务启动失败"
    exit 1
fi

# ==================== SSL 配置辅助函数 ====================

# 获取主域名邮箱
get_main_domain_email() {
    local domain="$1"
    local main_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
    echo "admin@${main_domain}"
}

# 检查邮箱是否有效
is_valid_ssl_email() {
    local email="$1"
    [ -z "$email" ] && return 1
    echo "$email" | grep -qE "@(example\.com|localhost|test\.com)" && return 1
    return 0
}

# 确保 acme.sh 配置正确
ensure_acme_sh_config() {
    local domain="$1"
    local expected_email=$(get_main_domain_email "$domain")

    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl -s https://get.acme.sh | sh -s email="$expected_email" >/dev/null 2>&1
        [ -f ~/.bashrc ] && source ~/.bashrc
        return 0
    fi

    if [ -f ~/.acme.sh/account.conf ]; then
        local current_email=$(grep "^ACCOUNT_EMAIL=" ~/.acme.sh/account.conf 2>/dev/null | cut -d"'" -f2)

        if ! is_valid_ssl_email "$current_email"; then
            sed -i "s/^ACCOUNT_EMAIL=.*/ACCOUNT_EMAIL='$expected_email'/g" ~/.acme.sh/account.conf
            rm -rf ~/.acme.sh/ca/*/account.json 2>/dev/null || true
        fi
    fi
}

# ==================== 配置 Nginx（临时用于 ACME 验证）====================

log_step "[7/8] 配置 Nginx 并配置 SSL 证书..."

SSL_DIR="/usr/local/nginx/conf/ssl/$DOMAIN"
NGINX_CONF="/usr/local/nginx/conf/conf.d/${DOMAIN}.conf"
CONF_D="/usr/local/nginx/conf/conf.d"

mkdir -p "$SSL_DIR"
mkdir -p "$CONF_D"

if [ "$USE_HTTP_ONLY" = true ]; then
    # HTTP 模式：跳过 SSL 证书
    log_info "HTTP 模式，跳过 SSL 证书配置"
    SSL_TYPE="无 (HTTP 模式)"
elif [ "$USE_DOMAIN" = true ]; then
    # 域名模式：申请 Let's Encrypt 证书

    # 确保 acme.sh 配置正确
    ensure_acme_sh_config "$DOMAIN"
    [ -f ~/.bashrc ] && source ~/.bashrc

    # 先创建临时 Nginx 配置用于 ACME 验证
    log_info "创建临时 Nginx 配置用于证书验证..."

    cat > "$NGINX_CONF" <<EOF
# LiteLLM 临时配置（用于 ACME 验证）
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    location / {
        return 200 'LiteLLM preparing...';
        add_header Content-Type text/plain;
    }
}
EOF

    # 创建 ACME 验证目录
    mkdir -p /var/www/acme
    chmod 755 /var/www/acme

    # 重载 Nginx
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl reload nginx >/dev/null 2>&1
    elif [ -f /usr/local/nginx/sbin/nginx ]; then
        /usr/local/nginx/sbin/nginx -s reload >/dev/null 2>&1
    fi

    # 申请证书
    log_info "正在申请 Let's Encrypt 证书（ECC-256）..."
    log_info "验证方式: Webroot (/var/www/acme)"

    if ~/.acme.sh/acme.sh --issue --server letsencrypt -d "$DOMAIN" --webroot /var/www/acme --keylength ec-256; then
        log_success "证书申请成功"

        # 安装证书
        ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
            --key-file "$SSL_DIR/key.pem" \
            --fullchain-file "$SSL_DIR/fullchain.pem" \
            --reloadcmd "systemctl reload nginx 2>/dev/null || /usr/local/nginx/sbin/nginx -s reload"

        log_success "证书已安装到: $SSL_DIR"
        SSL_TYPE="Let's Encrypt (ECC-256)"
    else
        log_warning "Let's Encrypt 证书申请失败，使用自签名证书"
        log_info "常见原因: DNS 未解析、防火墙阻止、域名被占用"

        # 生成自签名证书
        openssl req -x509 -nodes -days 365 -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "$SSL_DIR/key.pem" \
            -out "$SSL_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" 2>/dev/null

        log_info "已生成自签名证书（浏览器会提示不安全）"
        SSL_TYPE="自签名证书 (Let's Encrypt 申请失败)"
    fi
else
    # IP 模式：生成自签名证书
    log_info "生成自签名证书 (IP 模式)..."

    # 生成支持 IP 的自签名证书
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$SSL_DIR/key.pem" \
        -out "$SSL_DIR/fullchain.pem" \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName=IP:$DOMAIN" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        log_success "自签名证书生成成功"
        SSL_TYPE="自签名证书 (IP 模式)"
    else
        # 旧版 OpenSSL 不支持 -addext，使用备用方法
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$SSL_DIR/key.pem" \
            -out "$SSL_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" >/dev/null 2>&1
        log_success "自签名证书生成成功 (兼容模式)"
        SSL_TYPE="自签名证书 (IP 模式)"
    fi
fi

# ==================== 配置 Nginx（正式反向代理）====================

log_step "[8/8] 配置 Nginx 反向代理..."

if [ "$USE_HTTP_ONLY" = true ]; then
    # HTTP 模式：仅监听 80 端口
    cat > "$NGINX_CONF" <<EOF
# LiteLLM 反向代理配置 (HTTP 模式)
# 自动生成时间: $(date '+%Y-%m-%d %H:%M:%S')

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # Cloudflare 真实 IP
    set_real_ip_from 0.0.0.0/0;
    real_ip_header CF-Connecting-IP;

    # 日志
    access_log /var/log/nginx/litellm_access.log;
    error_log /var/log/nginx/litellm_error.log;

    # 反向代理到 LiteLLM
    location / {
        proxy_pass http://127.0.0.1:$LITELLM_PORT;
        proxy_http_version 1.1;

        # WebSocket 支持
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # 传递真实 IP 和域名
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # 超时设置（支持长时间流式响应）
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;

        # 关闭缓冲（SSE 支持）
        proxy_buffering off;
        proxy_cache off;

        # 允许大文件上传
        client_max_body_size 100M;
    }

    # Swagger UI（API 文档）
    location /docs {
        proxy_pass http://127.0.0.1:$LITELLM_PORT/docs;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }

    # 健康检查端点
    location /health {
        proxy_pass http://127.0.0.1:$LITELLM_PORT/health;
        access_log off;
    }
}
EOF
else
    # HTTPS 模式
    cat > "$NGINX_CONF" <<EOF
# LiteLLM 反向代理配置
# 自动生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# HTTP 自动跳转 HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # ACME 验证目录（证书续期）
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    # 其他请求跳转 HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS + HTTP/3
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    listen 443 quic reuseport;
    listen [::]:443 quic reuseport;

    http2 on;
    http3 on;
    quic_retry on;

    server_name $DOMAIN;

    # SSL 证书
    ssl_certificate $SSL_DIR/fullchain.pem;
    ssl_certificate_key $SSL_DIR/key.pem;

    # SSL 优化配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # HTTP/3 提示头
    add_header Alt-Svc 'h3=":443"; ma=86400';
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    # Cloudflare 真实 IP
    set_real_ip_from 0.0.0.0/0;
    real_ip_header CF-Connecting-IP;

    # 日志
    access_log /var/log/nginx/litellm_access.log;
    error_log /var/log/nginx/litellm_error.log;

    # 反向代理到 LiteLLM
    location / {
        proxy_pass http://127.0.0.1:$LITELLM_PORT;
        proxy_http_version 1.1;

        # WebSocket 支持
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # 传递真实 IP 和域名
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # 超时设置（支持长时间流式响应）
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;

        # 关闭缓冲（SSE 支持）
        proxy_buffering off;
        proxy_cache off;

        # 允许大文件上传
        client_max_body_size 100M;
    }

    # Swagger UI（API 文档）
    location /docs {
        proxy_pass http://127.0.0.1:$LITELLM_PORT/docs;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }

    # 健康检查端点
    location /health {
        proxy_pass http://127.0.0.1:$LITELLM_PORT/health;
        access_log off;
    }
}
EOF
fi

log_success "Nginx 配置已生成: $NGINX_CONF"

# 测试 Nginx 配置
if /usr/local/nginx/sbin/nginx -t; then
    log_success "Nginx 配置测试通过"
    systemctl reload nginx
    log_success "Nginx 已重载"
else
    log_error "Nginx 配置测试失败"
    exit 1
fi

# ==================== 生成部署信息文件 ====================

INFO_FILE="$SERVICE_DIR/litellm_info.txt"

# 确定访问模式和协议
if [ "$USE_HTTP_ONLY" = true ]; then
    ACCESS_MODE_TEXT="HTTP 模式 (无 SSL)"
    PROTOCOL="http"
elif [ "$USE_DOMAIN" = true ]; then
    ACCESS_MODE_TEXT="域名模式"
    PROTOCOL="https"
else
    ACCESS_MODE_TEXT="IP 模式"
    PROTOCOL="https"
fi

cat > "$INFO_FILE" <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  LiteLLM Docker 部署信息
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

部署时间: $(date '+%Y-%m-%d %H:%M:%S')
访问模式: $ACCESS_MODE_TEXT
服务器IP: $SERVER_IP
访问地址: ${PROTOCOL}://$DOMAIN
证书类型: $SSL_TYPE
$( [ "$USE_HTTP_ONLY" = true ] && echo "
⚠️  HTTP 模式注意事项:
- 数据传输不加密，API Key 可能泄露
- 仅建议在内网或开发环境使用" )
$( [ "$USE_HTTP_ONLY" = false ] && [ "$USE_DOMAIN" = false ] && echo "
⚠️  IP 模式注意事项:
- 浏览器会提示证书不安全，请点击「高级」→「继续访问」
- API 客户端可能需要关闭 SSL 验证" )

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  服务配置
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

LiteLLM 端口: 127.0.0.1:$LITELLM_PORT
PostgreSQL 端口: 127.0.0.1:$POSTGRES_PORT_EXTERNAL
Redis 端口: 127.0.0.1:$REDIS_PORT_EXTERNAL

Docker 网络: $DOCKER_NETWORK (共享)
Docker 镜像: $DOCKER_IMAGE

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  认证密钥（请妥善保管）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

LITELLM_MASTER_KEY: $MASTER_KEY
PostgreSQL 密码: $DB_PASSWORD
Redis 密码: $REDIS_PASSWORD

⚠️  所有密钥已保存在 config.yaml 文件中
⚠️  文件权限已设置为 600（仅 root 可读）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  API 访问
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

API 端点: ${PROTOCOL}://$DOMAIN/v1
Swagger 文档: ${PROTOCOL}://$DOMAIN/
健康检查: ${PROTOCOL}://$DOMAIN/health

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  OpenAI 兼容 API 示例
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

curl ${PROTOCOL}://$DOMAIN/v1/chat/completions \\
  -H "Authorization: Bearer $MASTER_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{
    "model": "gpt-4",
    "messages": [{"role": "user", "content": "Hello"}]
  }'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  管理 API 示例
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# 生成虚拟密钥（30天有效，预算100美元）
curl ${PROTOCOL}://$DOMAIN/key/generate \\
  -H "Authorization: Bearer $MASTER_KEY" \\
  -H "Content-Type: application/json" \\
  -d '{
    "duration": "30d",
    "max_budget": 100,
    "models": ["gpt-4", "claude-3-opus"]
  }'

# 查看支出统计
curl ${PROTOCOL}://$DOMAIN/spend/tags \\
  -H "Authorization: Bearer $MASTER_KEY"

# 列出所有密钥
curl ${PROTOCOL}://$DOMAIN/key/info \\
  -H "Authorization: Bearer $MASTER_KEY"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  配置 AI 模型
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

编辑配置文件添加模型（需要重启服务）：

  nano $SERVICE_DIR/config.yaml

添加示例（在 model_list 部分）：

  model_list:
    - model_name: gpt-4
      litellm_params:
        model: openai/gpt-4
        api_key: sk-your-openai-key

    - model_name: claude-3-opus
      litellm_params:
        model: anthropic/claude-3-opus-20240229
        api_key: sk-ant-your-anthropic-key

    - model_name: gemini-pro
      litellm_params:
        model: gemini/gemini-pro
        api_key: your-gemini-key

修改后重启服务：
  cd $SERVICE_DIR && $COMPOSE_CMD restart litellm

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  常用管理命令
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

进入目录:
  cd $SERVICE_DIR

查看服务状态:
  $COMPOSE_CMD ps

查看日志:
  $COMPOSE_CMD logs -f litellm

重启服务:
  $COMPOSE_CMD restart

停止服务:
  $COMPOSE_CMD stop

启动服务:
  $COMPOSE_CMD start

升级服务:
  cd /root && ./upgrade_litellm_docker.sh

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  数据库管理
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

连接 PostgreSQL:
  $COMPOSE_CMD exec postgres psql -U litellm

备份数据库:
  $COMPOSE_CMD exec postgres pg_dump -U litellm litellm > backup_\$(date +%Y%m%d).sql

恢复数据库:
  cat backup_20260105.sql | $COMPOSE_CMD exec -T postgres psql -U litellm litellm

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  配置文件位置
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Compose 配置: $SERVICE_DIR/docker-compose.yml
LiteLLM 配置: $SERVICE_DIR/config.yaml (权限 600)
Nginx 配置: $NGINX_CONF
部署信息: $INFO_FILE (权限 600)
日志目录: $LOGS_DIR

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  重要提示
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⚠️  请妥善保管 MASTER_KEY，它是访问所有 API 的主密钥
⚠️  建议定期备份 PostgreSQL 数据库和 config.yaml
⚠️  首次使用前，请编辑 config.yaml 添加 AI 模型配置
⚠️  不要将 config.yaml 提交到版本控制系统（包含密钥）

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  下一步操作
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. 编辑 config.yaml 添加 AI 提供商的 API 密钥
2. 重启服务使配置生效
3. 访问 ${PROTOCOL}://$DOMAIN/ 查看 Swagger API 文档
4. 生成虚拟密钥供应用使用
5. 配置监控和日志告警

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

chmod 600 "$INFO_FILE"

log_success "部署信息已保存: $INFO_FILE (权限 600)"

# ==================== 完成信息 ====================

clear
echo -e "${GREEN}"
echo "================================================"
echo "       LiteLLM 部署完成！"
echo "================================================"
echo -e "${NC}"
echo ""

# 根据访问模式设置协议
if [ "$USE_HTTP_ONLY" = true ]; then
    PROTOCOL="http"
    ACCESS_MODE_TEXT="HTTP 模式"
elif [ "$USE_DOMAIN" = true ]; then
    PROTOCOL="https"
    ACCESS_MODE_TEXT="域名模式"
else
    PROTOCOL="https"
    ACCESS_MODE_TEXT="IP 模式"
fi

echo -e "${CYAN}[访问信息]${NC}"
echo -e "访问模式:     $ACCESS_MODE_TEXT"
echo -e "地址:         ${GREEN}${PROTOCOL}://$DOMAIN${NC}"
echo -e "API 端点:     ${GREEN}${PROTOCOL}://$DOMAIN/v1${NC}"
echo -e "Swagger UI:   ${GREEN}${PROTOCOL}://$DOMAIN/${NC}"
echo -e "健康检查:     ${GREEN}${PROTOCOL}://$DOMAIN/health${NC}"
if [ "$USE_HTTP_ONLY" = true ]; then
    echo ""
    echo -e "${YELLOW}⚠️ HTTP 模式: 数据传输不加密，仅建议在内网或开发环境使用${NC}"
elif [ "$USE_DOMAIN" = false ]; then
    echo ""
    echo -e "${YELLOW}⚠️ IP 模式: 浏览器会提示证书不安全，请点击「高级」→「继续访问」${NC}"
fi
echo ""
echo -e "${CYAN}[认证密钥]${NC}"
echo -e "MASTER_KEY:   ${YELLOW}$MASTER_KEY${NC}"
echo ""
echo -e "${CYAN}[服务状态]${NC}"
cd "$SERVICE_DIR"
$COMPOSE_CMD ps
echo ""
echo -e "${CYAN}[配置文件]${NC}"
echo -e "LiteLLM 配置: ${YELLOW}$SERVICE_DIR/config.yaml${NC} (权限 600)"
echo -e "部署信息:     ${YELLOW}$INFO_FILE${NC} (权限 600)"
echo ""
echo -e "${CYAN}[下一步操作]${NC}"
echo -e "1. 编辑 config.yaml 添加 AI 模型:"
echo -e "   ${YELLOW}nano $SERVICE_DIR/config.yaml${NC}"
echo ""
echo -e "2. 重启服务使配置生效:"
echo -e "   ${YELLOW}cd $SERVICE_DIR && $COMPOSE_CMD restart litellm${NC}"
echo ""
echo -e "3. 查看详细部署信息:"
echo -e "   ${YELLOW}cat $INFO_FILE${NC}"
echo ""
echo -e "${GREEN}部署完成！所有配置已保存在 config.yaml 文件中。${NC}"
echo "================================================"
echo ""
