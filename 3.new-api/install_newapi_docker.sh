#!/bin/bash

################################################################################
#
# New-API Docker 部署脚本
#
# 功能说明：
#   1. 部署 New-API AI 模型聚合管理系统（Docker 方式）
#   2. 自动配置 PostgreSQL / MySQL 数据库
#   3. 自动配置 Redis 缓存
#   4. 自动申请 SSL 证书
#   5. 自动配置 Nginx 反向代理
#   6. 生成随机密码并保存到信息文件
#   7. 默认非交互，用环境变量传参；INTERACTIVE=1 走交互
#
# 环境变量：
#   ACCESS_MODE        domain / ip / http，也可写 1 / 2 / 3     (默认 domain)
#   DOMAIN             域名；ip / http 模式不填则用本机公网 IP  (domain 模式必填)
#   DB                 postgres / mysql，也可写 1 / 2           (默认 postgres)
#   FORCE              1=已安装时覆盖安装                       (默认 0，已安装则中止)
#   ALLOW_SELF_SIGNED  1=Let's Encrypt 失败时退回自签名证书    (默认 0，失败即中止)
#   INTERACTIVE        1=交互输入与确认                        (默认 0)
#
# 示例：
#   DOMAIN=newapi.example.com bash install_newapi_docker.sh
#   DOMAIN=newapi.example.com DB=mysql bash install_newapi_docker.sh
#   INTERACTIVE=1 bash install_newapi_docker.sh
#
# 部署架构：
#   Docker Compose: new-api + PostgreSQL + Redis
#   Nginx: 反向代理到 localhost:3000
#   数据持久化: Docker Volume
#
# 前置条件：
#   - Docker 和 docker-compose 已安装
#   - Nginx 已安装（通过 install_nginx.sh）
#   - 域名已解析到本服务器
#
# 参考来源：
#   - GitHub: https://github.com/QuantumNous/new-api
#   - 官方文档: https://docs.newapi.pro/zh/docs
#
################################################################################

# ==================== 全局配置 ====================

NEWAPI_PORT=3000
POSTGRES_PORT=5432
REDIS_PORT=6379

NGINX_PATH="/usr/local/nginx"
CONF_D="$NGINX_PATH/conf/conf.d"
SSL_DIR="$NGINX_PATH/conf/ssl"

DOCKER_ROOT="/opt/docker-services"
SERVICE_DIR="$DOCKER_ROOT/new-api"
DATA_DIR="$SERVICE_DIR/data"
LOGS_DIR="$SERVICE_DIR/logs"

ACCESS_MODE="${ACCESS_MODE:-domain}"
DOMAIN="${DOMAIN:-}"
DB="${DB:-postgres}"
FORCE="${FORCE:-0}"
ALLOW_SELF_SIGNED="${ALLOW_SELF_SIGNED:-0}"
INTERACTIVE="${INTERACTIVE:-0}"

GITHUB_REPO="QuantumNous/new-api"
DOCKER_IMAGE="calciumion/new-api:latest"

# Docker 网络名称（供其他服务复用）
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

# ==================== 工具函数 ====================

# 生成随机密码（32位）
generate_password() {
    local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local password=""
    for i in {1..32}; do
        password="${password}${chars:$((RANDOM % ${#chars})):1}"
    done
    echo "$password"
}

# 生成 Session Secret（48位）
generate_session_secret() {
    local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local secret=""
    for i in {1..48}; do
        secret="${secret}${chars:$((RANDOM % ${#chars})):1}"
    done
    echo "$secret"
}

# ==================== 环境检查 ====================

if [ "$EUID" -ne 0 ]; then
    log_error "必须使用 root 权限运行。"
    exit 1
fi

# 检查 Docker，未安装则尝试自动安装
if ! command -v docker &> /dev/null; then
    log_warning "未检测到 Docker，尝试自动安装..."

    # 定位 Docker 安装脚本
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    DOCKER_INSTALLER="$SCRIPT_DIR/../01.docker/install_docker.sh"

    if [ -f "$DOCKER_INSTALLER" ]; then
        source "$DOCKER_INSTALLER"
        if ! ensure_docker; then
            log_error "Docker 自动安装失败，请手动安装。"
            log_info "安装命令: curl -fsSL https://get.docker.com | sh"
            exit 1
        fi
    else
        log_error "未找到 Docker 安装脚本: $DOCKER_INSTALLER"
        log_info "安装命令: curl -fsSL https://get.docker.com | sh"
        exit 1
    fi
fi

# 检查 docker-compose
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null 2>&1; then
    log_error "未检测到 docker-compose，请先安装。"
    log_info "安装命令: apt-get install docker-compose-plugin 或 yum install docker-compose-plugin"
    exit 1
fi

# 统一使用 docker compose（新版）或 docker-compose（旧版）
if docker compose version &> /dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# 检查 Nginx
if [ ! -d "$NGINX_PATH" ]; then
    log_error "未检测到 Nginx，请先运行 install_nginx.sh"
    exit 1
fi

# 检查依赖工具
for cmd in curl wget; do
    if ! command -v $cmd &> /dev/null; then
        log_error "缺少必要工具 $cmd，请安装后重试。"
        exit 1
    fi
done

# ==================== 欢迎横幅 ====================

if [ "$INTERACTIVE" = "1" ]; then clear; fi
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}   New-API Docker 部署程序${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# 检查是否已安装
if [ -f "$SERVICE_DIR/docker-compose.yml" ]; then
    log_warning "检测到已安装 New-API"
    if [ "$INTERACTIVE" = "1" ]; then
        echo ""
        read -p "是否覆盖安装？(y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "安装已取消。"
            exit 0
        fi
    elif [ "$FORCE" != "1" ]; then
        log_error "已安装 New-API，未做任何改动。确认覆盖安装请加 FORCE=1"
        exit 1
    fi
fi

# ==================== 读取配置 ====================

log_step "[1/8] 读取配置信息"
echo ""

detect_server_ip() {
    curl -s --connect-timeout 5 https://api.ipify.org || curl -s --connect-timeout 5 https://ifconfig.me || hostname -I | awk '{print $1}'
}

if [ "$INTERACTIVE" = "1" ]; then
    echo -e "${CYAN}>>> 请选择访问方式${NC}"
    echo ""
    echo "  1) 使用域名（推荐）- 自动申请 Let's Encrypt 证书"
    echo "  2) 使用 IP 地址   - 自签名证书，浏览器会提示不安全"
    echo "  3) 仅使用 HTTP    - 无 SSL 证书，仅限内网/开发环境"
    echo ""
    read -p "请选择 [1/2/3，默认 1]: " v
    [ -n "$v" ] && ACCESS_MODE="$v"
fi

case "$ACCESS_MODE" in
    1|domain) ACCESS_MODE=domain; USE_DOMAIN=true;  USE_HTTP_ONLY=false ;;
    2|ip)     ACCESS_MODE=ip;     USE_DOMAIN=false; USE_HTTP_ONLY=false ;;
    3|http)   ACCESS_MODE=http;   USE_DOMAIN=false; USE_HTTP_ONLY=true ;;
    *)
        log_error "ACCESS_MODE 只能是 domain / ip / http (或 1 / 2 / 3): $ACCESS_MODE"
        exit 1
        ;;
esac

SERVER_IP=$(detect_server_ip)

if [ "$USE_DOMAIN" = true ]; then
    if [ -z "$DOMAIN" ] && [ "$INTERACTIVE" = "1" ]; then
        echo ""
        read -p "请输入域名 (例如 newapi.example.com): " DOMAIN
    fi
    if [ -z "$DOMAIN" ]; then
        log_error "域名模式需要 DOMAIN，例如: DOMAIN=newapi.example.com bash $0 （或 INTERACTIVE=1 交互输入）"
        exit 1
    fi
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log_error "域名格式不正确: $DOMAIN"
        exit 1
    fi
else
    [ -z "$DOMAIN" ] && DOMAIN="$SERVER_IP"
    if [ "$INTERACTIVE" = "1" ]; then
        echo ""
        echo -e "检测到服务器 IP: ${GREEN}$SERVER_IP${NC}"
        if [ "$USE_HTTP_ONLY" = true ]; then
            echo -e "${YELLOW}⚠️  HTTP 模式警告：${NC}"
            echo -e "${YELLOW}   - 数据传输不加密，API Key 可能泄露${NC}"
            echo -e "${YELLOW}   - 仅建议在内网或开发环境使用${NC}"
        fi
        read -p "访问用的 IP [默认: $DOMAIN]: " v
        [ -n "$v" ] && DOMAIN="$v"
    fi
    if [ -z "$DOMAIN" ]; then
        log_error "无法获取服务器 IP，请用 DOMAIN=<IP> 指定"
        exit 1
    fi
fi

if [ "$INTERACTIVE" = "1" ]; then
    echo ""
    echo -e "${CYAN}选择数据库类型:${NC}"
    echo "  1) PostgreSQL 15 (推荐，官方默认)"
    echo "  2) MySQL 8.2"
    read -p "请选择 [1-2, 默认 1]: " v
    [ -n "$v" ] && DB="$v"
fi

case "$DB" in
    2|mysql)
        USE_MYSQL=true
        DB_TYPE="MySQL"
        DB_IMAGE="mysql:8.2"
        DB_PORT=3306
        ;;
    1|postgres|postgresql)
        USE_POSTGRESQL=true
        DB_TYPE="PostgreSQL"
        DB_IMAGE="postgres:15"
        DB_PORT=5432
        ;;
    *)
        log_error "DB 只能是 postgres / mysql (或 1 / 2): $DB"
        exit 1
        ;;
esac

log_info "已选择: $DB_TYPE"
echo ""

# 生成随机密码
log_info "正在生成随机密码..."
DB_PASSWORD=$(generate_password)
REDIS_PASSWORD=$(generate_password)
SESSION_SECRET=$(generate_session_secret)

log_success "密码已生成（将保存到信息文件）"
echo ""

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$USE_HTTP_ONLY" = true ]; then
    echo -e "${YELLOW}⚠️  HTTP 模式：无 SSL 加密${NC}"
elif [ "$USE_DOMAIN" = true ]; then
    echo -e "${YELLOW}⚠️  重要提示：请确保域名已解析${NC}"
else
    echo -e "${YELLOW}⚠️  IP 模式：将使用自签名证书，浏览器会提示「不安全」${NC}"
fi
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "访问地址: ${GREEN}$DOMAIN${NC}"
echo -e "目标IP:   ${GREEN}$SERVER_IP${NC}"
if [ "$INTERACTIVE" = "1" ]; then
    echo ""
    echo -e "${YELLOW}[按回车键继续部署，Ctrl+C 取消]${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -r
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

# ==================== SSL 证书配置 ====================

log_step "[2/8] 配置 SSL 证书（先于容器，失败即中止）..."

# 创建证书目录
DOMAIN_SSL_DIR="$SSL_DIR/$DOMAIN"
if [ -d "$DOMAIN_SSL_DIR" ]; then SSL_DIR_EXISTED=true; else SSL_DIR_EXISTED=false; fi
mkdir -p "$DOMAIN_SSL_DIR"

if [ "$USE_HTTP_ONLY" = true ]; then
    # HTTP 模式：跳过 SSL 证书
    log_info "HTTP 模式，跳过 SSL 证书配置"
    SSL_TYPE="无 (HTTP 模式)"
elif [ "$USE_DOMAIN" = true ]; then
    # 域名模式：申请 Let's Encrypt 证书
    log_info "申请 Let's Encrypt ECC 证书..."

    # 确保 acme.sh 配置正确
    ensure_acme_sh_config "$DOMAIN"
    [ -f ~/.bashrc ] && source ~/.bashrc

    ACME_PREV_CONF=""
    if [ -f "$CONF_D/${DOMAIN}.conf" ]; then
        ACME_PREV_CONF="$CONF_D/${DOMAIN}.conf.pre-acme"
        cp -a "$CONF_D/${DOMAIN}.conf" "$ACME_PREV_CONF"
    fi

    # 临时 Nginx 配置用于验证
    cat > "$CONF_D/${DOMAIN}.conf" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }
}
EOF

    mkdir -p /var/www/acme
    chmod 755 /var/www/acme
    systemctl reload nginx >/dev/null 2>&1

    # 申请证书
    ~/.acme.sh/acme.sh --issue --server letsencrypt -d "$DOMAIN" --webroot /var/www/acme --keylength ec-256

    # 安装证书
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file       "$DOMAIN_SSL_DIR/key.pem" \
        --fullchain-file "$DOMAIN_SSL_DIR/fullchain.pem" \
        --reloadcmd     "systemctl reload nginx" >/dev/null 2>&1

    if [ $? -eq 0 ] && [ -s "$DOMAIN_SSL_DIR/fullchain.pem" ]; then
        log_success "SSL 证书申请成功 (Let's Encrypt ECC)"
        SSL_TYPE="Let's Encrypt (ECC-256)"
        rm -f "$ACME_PREV_CONF"
    elif [ "$ALLOW_SELF_SIGNED" = "1" ]; then
        log_warning "Let's Encrypt 申请失败，ALLOW_SELF_SIGNED=1，改用自签名证书..."
        rm -f "$ACME_PREV_CONF"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$DOMAIN_SSL_DIR/key.pem" \
            -out "$DOMAIN_SSL_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" >/dev/null 2>&1
        SSL_TYPE="自签名证书 (Let's Encrypt 申请失败)"
    else
        if [ -n "$ACME_PREV_CONF" ]; then
            mv -f "$ACME_PREV_CONF" "$CONF_D/${DOMAIN}.conf"
        else
            rm -f "$CONF_D/${DOMAIN}.conf"
        fi
        [ "$SSL_DIR_EXISTED" = false ] && rm -rf "$DOMAIN_SSL_DIR"
        systemctl reload nginx >/dev/null 2>&1
        log_error "Let's Encrypt 证书申请失败，已中止（未创建目录、未启动容器）。"
        log_info "确认 $DOMAIN 已解析到本机、80 端口公网可达后重跑；确需自签名证书时加 ALLOW_SELF_SIGNED=1。"
        exit 1
    fi
else
    # IP 模式：生成自签名证书
    log_info "生成自签名证书 (IP 模式)..."

    # 生成支持 IP 的自签名证书
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$DOMAIN_SSL_DIR/key.pem" \
        -out "$DOMAIN_SSL_DIR/fullchain.pem" \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName=IP:$DOMAIN" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        log_success "自签名证书生成成功"
        SSL_TYPE="自签名证书 (IP 模式)"
    else
        # 旧版 OpenSSL 不支持 -addext，使用备用方法
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$DOMAIN_SSL_DIR/key.pem" \
            -out "$DOMAIN_SSL_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" >/dev/null 2>&1
        log_success "自签名证书生成成功 (兼容模式)"
        SSL_TYPE="自签名证书 (IP 模式)"
    fi
fi

# ==================== 创建目录结构 ====================

log_step "[3/8] 创建目录结构..."

mkdir -p "$DOCKER_ROOT"
mkdir -p "$SERVICE_DIR"
mkdir -p "$DATA_DIR/postgres"
mkdir -p "$DATA_DIR/redis"
mkdir -p "$LOGS_DIR"

log_success "目录创建完成"

# ==================== 生成 docker-compose.yml ====================

log_step "[4/8] 生成 Docker Compose 配置..."

if [ "$USE_POSTGRESQL" = true ]; then
    # PostgreSQL 配置
    cat > "$SERVICE_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  new-api:
    image: $DOCKER_IMAGE
    container_name: new-api
    restart: always
    ports:
      - "127.0.0.1:$NEWAPI_PORT:3000"
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    environment:
      - SQL_DSN=postgresql://newapi:$DB_PASSWORD@postgres:5432/newapi
      - REDIS_CONN_STRING=redis://:$REDIS_PASSWORD@redis:6379
      - SESSION_SECRET=$SESSION_SECRET
      - TZ=Asia/Shanghai
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      - STREAMING_TIMEOUT=300
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://localhost:3000/api/status || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  postgres:
    image: $DB_IMAGE
    container_name: newapi-postgres
    restart: always
    environment:
      POSTGRES_USER: newapi
      POSTGRES_PASSWORD: $DB_PASSWORD
      POSTGRES_DB: newapi
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U newapi"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: newapi-redis
    restart: always
    command: redis-server --requirepass $REDIS_PASSWORD --appendonly yes
    volumes:
      - redis_data:/data
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "$REDIS_PASSWORD", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5

networks:
  $DOCKER_NETWORK:
    name: $DOCKER_NETWORK
    driver: bridge

volumes:
  postgres_data:
    driver: local
  redis_data:
    driver: local
EOF

else
    # MySQL 配置
    cat > "$SERVICE_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  new-api:
    image: $DOCKER_IMAGE
    container_name: new-api
    restart: always
    ports:
      - "127.0.0.1:$NEWAPI_PORT:3000"
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    environment:
      - SQL_DSN=newapi:$DB_PASSWORD@tcp(mysql:3306)/newapi
      - REDIS_CONN_STRING=redis://:$REDIS_PASSWORD@redis:6379
      - SESSION_SECRET=$SESSION_SECRET
      - TZ=Asia/Shanghai
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      - STREAMING_TIMEOUT=300
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_started
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://localhost:3000/api/status || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  mysql:
    image: $DB_IMAGE
    container_name: newapi-mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: $DB_PASSWORD
      MYSQL_DATABASE: newapi
      MYSQL_USER: newapi
      MYSQL_PASSWORD: $DB_PASSWORD
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - $DOCKER_NETWORK
    command: --default-authentication-plugin=mysql_native_password --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p$DB_PASSWORD"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: newapi-redis
    restart: always
    command: redis-server --requirepass $REDIS_PASSWORD --appendonly yes
    volumes:
      - redis_data:/data
    networks:
      - $DOCKER_NETWORK
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "$REDIS_PASSWORD", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5

networks:
  $DOCKER_NETWORK:
    name: $DOCKER_NETWORK
    driver: bridge

volumes:
  mysql_data:
    driver: local
  redis_data:
    driver: local
EOF

fi

log_success "Docker Compose 配置已生成"

# ==================== 拉取 Docker 镜像 ====================

log_step "[5/8] 拉取 Docker 镜像..."

cd "$SERVICE_DIR"

log_info "正在拉取镜像（可能需要几分钟）..."
if $COMPOSE_CMD pull; then
    log_success "镜像拉取完成"
else
    log_error "镜像拉取失败，请检查网络连接。"
    exit 1
fi

# ==================== 启动服务 ====================

log_step "[6/8] 启动 Docker 服务..."

log_info "正在启动容器..."
if $COMPOSE_CMD up -d; then
    log_success "容器启动成功"
else
    log_error "容器启动失败"
    log_info "查看日志: cd $SERVICE_DIR && $COMPOSE_CMD logs"
    exit 1
fi

# 等待服务启动
log_info "等待服务初始化（约 30 秒）..."
sleep 30

# 检查服务状态
if $COMPOSE_CMD ps | grep -q "Up"; then
    log_success "服务运行正常"
else
    log_warning "服务可能未正常启动，请检查日志"
    $COMPOSE_CMD ps
fi

# ==================== 配置 Nginx 反向代理 ====================

log_step "[7/8] 配置 Nginx 反向代理..."

# 检测 HTTP/3 支持
NGINX_SUPPORTS_HTTP3=false
if $NGINX_PATH/sbin/nginx -V 2>&1 | grep -q "http_v3_module"; then
    NGINX_SUPPORTS_HTTP3=true
    log_info "检测到 HTTP/3 支持"
fi

# 生成 Nginx 配置
if [ "$USE_HTTP_ONLY" = true ]; then
    # HTTP 模式：仅监听 80 端口
    cat > "$CONF_D/${DOMAIN}.conf" <<'EOF_NGINX_HTTP'
server {
    listen 80;

    server_name DOMAIN_PLACEHOLDER;

    # 大请求支持（图片上传等）
    client_max_body_size 50m;

    # 降低延迟
    tcp_nodelay on;

    # 日志
    access_log /var/log/nginx/newapi_access.log;
    error_log /var/log/nginx/newapi_error.log warn;

    #NEW-API-START
    location / {
        proxy_pass http://127.0.0.1:NEWAPI_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket 支持
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # SSE 流式响应支持
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        chunked_transfer_encoding on;
    }
    #NEW-API-END
}
EOF_NGINX_HTTP
elif [ "$NGINX_SUPPORTS_HTTP3" = true ]; then
    # HTTP/3 配置
    cat > "$CONF_D/${DOMAIN}.conf" <<'EOF_NGINX'
server {
    listen 80;
    listen 443 ssl;
    listen 443 quic;
    http2 on;

    server_name DOMAIN_PLACEHOLDER;

    # 大请求支持（图片上传等）
    client_max_body_size 50m;

    # 降低延迟
    tcp_nodelay on;

    # ACME 验证路径
    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    #SSL-START
    #HTTP_TO_HTTPS_START
    set $isRedcert 1;
    if ($scheme = http) {
        set $isRedcert 2;
    }
    if ( $uri ~ /\.well-known/ ) {
        set $isRedcert 1;
    }
    if ($isRedcert != 1) {
        rewrite ^(.*)$ https://$host$1 permanent;
    }
    #HTTP_TO_HTTPS_END
    ssl_certificate SSL_CERT_PLACEHOLDER;
    ssl_certificate_key SSL_KEY_PLACEHOLDER;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    add_header Strict-Transport-Security "max-age=31536000";
    add_header Alt-Svc 'h3=":443"; ma=86400';
    error_page 497 https://$host$request_uri;
    #SSL-END

    # 日志
    access_log /var/log/nginx/newapi_access.log;
    error_log /var/log/nginx/newapi_error.log warn;

    #NEW-API-START
    location / {
        proxy_pass http://127.0.0.1:NEWAPI_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket 支持
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # SSE 流式响应支持
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        chunked_transfer_encoding on;
    }
    #NEW-API-END
}
EOF_NGINX
else
    # HTTP/2 配置
    cat > "$CONF_D/${DOMAIN}.conf" <<'EOF_NGINX_NO_H3'
server {
    listen 80;
    listen 443 ssl;
    http2 on;

    server_name DOMAIN_PLACEHOLDER;

    client_max_body_size 50m;
    tcp_nodelay on;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    #SSL-START
    #HTTP_TO_HTTPS_START
    set $isRedcert 1;
    if ($scheme = http) {
        set $isRedcert 2;
    }
    if ( $uri ~ /\.well-known/ ) {
        set $isRedcert 1;
    }
    if ($isRedcert != 1) {
        rewrite ^(.*)$ https://$host$1 permanent;
    }
    #HTTP_TO_HTTPS_END
    ssl_certificate SSL_CERT_PLACEHOLDER;
    ssl_certificate_key SSL_KEY_PLACEHOLDER;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    add_header Strict-Transport-Security "max-age=31536000";
    error_page 497 https://$host$request_uri;
    #SSL-END

    access_log /var/log/nginx/newapi_access.log;
    error_log /var/log/nginx/newapi_error.log warn;

    #NEW-API-START
    location / {
        proxy_pass http://127.0.0.1:NEWAPI_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        chunked_transfer_encoding on;
    }
    #NEW-API-END
}
EOF_NGINX_NO_H3
fi

# 替换占位符
sed -i "s|DOMAIN_PLACEHOLDER|$DOMAIN|g" "$CONF_D/${DOMAIN}.conf"
sed -i "s|SSL_CERT_PLACEHOLDER|$DOMAIN_SSL_DIR/fullchain.pem|g" "$CONF_D/${DOMAIN}.conf"
sed -i "s|SSL_KEY_PLACEHOLDER|$DOMAIN_SSL_DIR/key.pem|g" "$CONF_D/${DOMAIN}.conf"
sed -i "s|NEWAPI_PORT_PLACEHOLDER|$NEWAPI_PORT|g" "$CONF_D/${DOMAIN}.conf"

HTTPS_LISTEN_SNIPPET="$NGINX_PATH/conf/snippets/https_listen.conf"
if [ -f "$HTTPS_LISTEN_SNIPPET" ]; then
    sed -i -E "s|^([[:space:]]*)listen 443 ssl;|\1include $HTTPS_LISTEN_SNIPPET;|" "$CONF_D/${DOMAIN}.conf"
fi

log_success "Nginx 配置已生成"

# 测试并重载 Nginx
if $NGINX_PATH/sbin/nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    log_success "Nginx 已重载"
else
    log_error "Nginx 配置测试失败"
    $NGINX_PATH/sbin/nginx -t
fi

# ==================== 生成配置信息文件 ====================

log_step "[8/8] 生成配置信息文件..."

INFO_FILE="$SERVICE_DIR/newapi_info.txt"

cat > "$INFO_FILE" <<EOF
================================================
       New-API Docker 部署完成
================================================
访问模式: $( [ "$USE_HTTP_ONLY" = true ] && echo "HTTP 模式" || ( [ "$USE_DOMAIN" = true ] && echo "域名模式" || echo "IP 模式" ) )
服务器 IP: $SERVER_IP
$( [ "$USE_DOMAIN" = true ] && echo "域名:      $DOMAIN" || echo "访问地址:  $DOMAIN" )

[访问地址]
$( [ "$USE_HTTP_ONLY" = true ] && echo "HTTP:      http://$DOMAIN" || echo "HTTPS:     https://$DOMAIN" )
$( [ "$USE_HTTP_ONLY" = true ] && echo "管理界面:  http://$DOMAIN" || echo "管理界面:  https://$DOMAIN" )

⚠️ 首次访问请在 Web 界面创建管理员账号
$( [ "$USE_HTTP_ONLY" = true ] && echo "
⚠️  HTTP 模式注意事项:
- 数据传输不加密，API Key 可能泄露
- 仅建议在内网或开发环境使用" )
$( [ "$USE_HTTP_ONLY" = false ] && [ "$USE_DOMAIN" = false ] && echo "
⚠️  IP 模式注意事项:
- 浏览器会提示证书不安全，请点击「高级」→「继续访问」
- API 客户端可能需要关闭 SSL 验证" )

[数据库信息]
类型:      $DB_TYPE
用户名:    newapi
密码:      $DB_PASSWORD
数据库名:  newapi
端口:      $DB_PORT (仅容器内访问)

[Redis 信息]
密码:      $REDIS_PASSWORD
端口:      6379 (仅容器内访问)

[Session Secret]
$SESSION_SECRET

⚠️ 重要：请妥善保管以上密码信息！

[服务目录]
Docker 目录:  $SERVICE_DIR
数据目录:     $DATA_DIR
日志目录:     $LOGS_DIR
配置文件:     $SERVICE_DIR/docker-compose.yml

[Docker 管理命令]
进入服务目录:  cd $SERVICE_DIR
查看服务状态:  $COMPOSE_CMD ps
查看日志:      $COMPOSE_CMD logs -f new-api
启动服务:      $COMPOSE_CMD start
停止服务:      $COMPOSE_CMD stop
重启服务:      $COMPOSE_CMD restart
完全停止:      $COMPOSE_CMD down

[升级命令]
cd $SERVICE_DIR
$COMPOSE_CMD pull
$COMPOSE_CMD up -d

[备份命令]
备份数据库:
EOF

if [ "$USE_POSTGRESQL" = true ]; then
    cat >> "$INFO_FILE" <<EOF
  $COMPOSE_CMD exec postgres pg_dump -U newapi newapi > backup_\$(date +%Y%m%d).sql
恢复数据库:
  $COMPOSE_CMD exec -T postgres psql -U newapi newapi < backup_20260104.sql
EOF
else
    cat >> "$INFO_FILE" <<EOF
  $COMPOSE_CMD exec mysql mysqldump -u newapi -p$DB_PASSWORD newapi > backup_\$(date +%Y%m%d).sql
恢复数据库:
  $COMPOSE_CMD exec -T mysql mysql -u newapi -p$DB_PASSWORD newapi < backup_20260104.sql
EOF
fi

cat >> "$INFO_FILE" <<EOF

[SSL 证书]
类型:      $SSL_TYPE
证书目录:  $DOMAIN_SSL_DIR/
自动续期:  已启用（acme.sh cron 任务）

[Nginx 配置]
配置文件:  $CONF_D/${DOMAIN}.conf
测试配置:  $NGINX_PATH/sbin/nginx -t
重载配置:  systemctl reload nginx

[Docker 网络]
网络名称:  $DOCKER_NETWORK
说明:      其他服务可通过此网络与 New-API 通信

[官方文档]
https://docs.newapi.pro/zh/docs

================================================
EOF

chmod 600 "$INFO_FILE"
log_success "配置信息已保存: $INFO_FILE"

# ==================== 完成信息 ====================

if [ "$INTERACTIVE" = "1" ]; then clear; fi
echo -e "${GREEN}"
cat "$INFO_FILE"
echo -e "${NC}"

# 确定访问协议
if [ "$USE_HTTP_ONLY" = true ]; then
    ACCESS_URL="http://$DOMAIN"
else
    ACCESS_URL="https://$DOMAIN"
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ New-API 部署完成！${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "📋 配置信息文件: ${YELLOW}$INFO_FILE${NC}"
echo -e "🌐 访问地址: ${GREEN}$ACCESS_URL${NC}"
echo -e "📊 服务状态: ${CYAN}cd $SERVICE_DIR && $COMPOSE_CMD ps${NC}"
echo ""
if [ "$USE_HTTP_ONLY" = true ]; then
    echo -e "${YELLOW}⚠️ HTTP 模式: 数据传输不加密，仅建议在内网或开发环境使用${NC}"
    echo ""
elif [ "$USE_DOMAIN" = false ]; then
    echo -e "${YELLOW}⚠️ IP 模式: 浏览器会提示证书不安全，请点击「高级」→「继续访问」${NC}"
    echo ""
fi
echo -e "${YELLOW}⚠️ 下一步: 请访问 Web 界面创建管理员账号${NC}"
echo ""
