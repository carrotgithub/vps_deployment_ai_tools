#!/bin/bash

################################################################################
#
# CliproxyAPI 智能安装/升级脚本 v2.1
#
# 功能说明：
#   1. 自动检测是否已安装（智能判断全新安装 or 升级）
#   2. 全新安装：完整的交互式配置流程
#   3. 升级模式：保留所有配置，仅更新二进制文件
#   4. 支持域名模式（自动申请 Let's Encrypt 证书）
#   5. 支持 IP 模式（自签名证书，无需域名）
#   6. 配置 Nginx 反向代理（HTTPS + WebSocket）
#   7. 配置 Systemd 服务自启动
#   8. 支持回滚机制
#
# 前置条件：
#   - 必须先运行 install_nginx.sh
#   - 域名模式：域名需要解析到本服务器
#   - IP 模式：无需域名，使用自签名证书
#
# 使用场景：
#   - 全新安装: 首次部署 CliproxyAPI
#   - 升级: 检测到已安装时自动切换为升级模式
#
# 参考来源：
#   - 官网脚本: cliproxyapi-installer
#   - 原脚本: install_cliproxyapi.sh
#
################################################################################

# ==================== 全局配置 ====================

CLIPROXY_PORT=8317
NGINX_PATH="/usr/local/nginx"
CONF_D="$NGINX_PATH/conf/conf.d"
SSL_DIR="$NGINX_PATH/conf/ssl"

INSTALL_DIR="/opt/cliproxyapi"
CONFIG_DIR="/etc/cliproxyapi"
DATA_DIR="/var/lib/cliproxyapi"
LOG_DIR="/var/log/cliproxyapi"

GITHUB_REPO="router-for-me/CLIProxyAPI"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

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

# ==================== 检查环境 ====================

if [ "$EUID" -ne 0 ]; then
    log_error "必须使用 root 权限运行。"
    exit 1
fi

if [ ! -d "$NGINX_PATH" ]; then
    log_error "未检测到 Nginx，请先运行 install_nginx.sh"
    exit 1
fi

# 检查依赖工具
for cmd in curl wget tar; do
    if ! command -v $cmd &> /dev/null; then
        log_error "缺少必要工具 $cmd，请安装后重试。"
        exit 1
    fi
done

# ==================== 检测安装状态 ====================

IS_UPGRADE=false
CURRENT_VERSION="none"

if [ -f "$INSTALL_DIR/version.txt" ]; then
    IS_UPGRADE=true
    CURRENT_VERSION=$(cat "$INSTALL_DIR/version.txt" 2>/dev/null || echo "unknown")
fi

# ==================== 欢迎横幅 ====================

clear
if [ "$IS_UPGRADE" = true ]; then
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}   CliproxyAPI 升级程序 v2.0${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    log_info "检测到已安装版本: v${CURRENT_VERSION}"
    log_warning "即将进入升级模式（保留所有配置）"
    echo ""
    read -p "按回车键继续，或 Ctrl+C 取消..." -r
else
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}   CliproxyAPI 安装程序 v2.0${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
fi

# ==================== 交互输入（仅全新安装） ====================

if [ "$IS_UPGRADE" = false ]; then
    echo -e "${CYAN}>>> 请选择访问方式${NC}"
    echo ""
    echo "  1) 使用域名（推荐）- 自动申请 Let's Encrypt 证书"
    echo "  2) 使用 IP 地址   - 自签名证书，无需域名"
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
        echo ""
        read -p "请输入域名 (例如 api.example.com): " DOMAIN

        # 域名格式验证
        if [ -z "$DOMAIN" ]; then
            log_error "域名不能为空。"
            exit 1
        fi

        if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
            log_error "域名格式不正确。"
            exit 1
        fi
    fi

    if [ -z "$DOMAIN" ]; then
        log_error "域名/IP 不能为空。"
        exit 1
    fi

    echo ""
    read -p "请输入管理面板密码: " ADMIN_SECRET

    if [ -z "$ADMIN_SECRET" ]; then
        log_error "管理面板密码不能为空。"
        exit 1
    fi

    # 配置提示
    SERVER_IP=$(curl -s https://api.ipify.org 2>/dev/null || curl -s http://whatismyip.akamai.com 2>/dev/null || hostname -I | awk '{print $1}')

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ "$USE_HTTP_ONLY" = true ]; then
        echo -e "${YELLOW}⚠️  HTTP 模式：无 SSL 加密${NC}"
    elif [ "$USE_DOMAIN" = true ]; then
        echo -e "${YELLOW}⚠️  重要提示：请确保域名已解析${NC}"
    else
        echo -e "${YELLOW}⚠️  IP 模式：将使用自签名证书${NC}"
    fi
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "访问地址: ${GREEN}$DOMAIN${NC}"
    echo -e "服务器IP: ${GREEN}$SERVER_IP${NC}"
    echo ""
    echo -e "${YELLOW}[按回车键继续安装，Ctrl+C 取消]${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read
else
    # 升级模式：从现有配置读取域名
    # 查找包含 cliproxyapi 标识的 Nginx 配置文件
    EXISTING_CONF=""
    for conf_file in "$CONF_D"/*.conf; do
        if [ -f "$conf_file" ] && grep -q "CLI-PROXY-API-START" "$conf_file" 2>/dev/null; then
            EXISTING_CONF="$conf_file"
            break
        fi
    done

    if [ -n "$EXISTING_CONF" ]; then
        DOMAIN=$(grep "server_name" "$EXISTING_CONF" | head -1 | awk '{print $2}' | sed 's/;//g')
        log_info "检测到现有域名: $DOMAIN"
    else
        log_warning "未检测到现有 Nginx 配置，升级后可能需要手动配置"
        DOMAIN=""
    fi

    # 读取现有管理密码
    if [ -f "$CONFIG_DIR/config.yaml" ]; then
        ADMIN_SECRET=$(grep "secret-key:" "$CONFIG_DIR/config.yaml" | awk '{print $2}' | tr -d '"')
        log_info "管理密码: 保留现有配置"
    fi
fi

# ==================== 检测系统架构 ====================

echo ""
log_step "[1/7] 检测系统架构..."

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            echo "linux_amd64"
            ;;
        arm64|aarch64)
            echo "linux_arm64"
            ;;
        *)
            log_error "不支持的系统架构 $(uname -m)"
            exit 1
            ;;
    esac
}

ARCH=$(detect_arch)
log_success "架构: $ARCH"

# ==================== 获取最新版本 ====================

log_step "[2/7] 获取最新版本信息..."

RELEASE_INFO=$(curl -s "$GITHUB_API")

if [ -z "$RELEASE_INFO" ]; then
    log_error "无法获取版本信息，请检查网络连接。"
    exit 1
fi

LATEST_VERSION=$(echo "$RELEASE_INFO" | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 | sed 's/^v//')

if [ -z "$LATEST_VERSION" ]; then
    log_error "无法解析版本号，请检查网络连接。"
    exit 1
fi

log_success "最新版本: v$LATEST_VERSION"

# 升级模式：版本对比
if [ "$IS_UPGRADE" = true ] && [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    log_success "已是最新版本 (v$LATEST_VERSION)，无需升级。"
    exit 0
fi

# ==================== 备份现有配置（仅升级模式） ====================

BACKUP_DIR=""

if [ "$IS_UPGRADE" = true ]; then
    log_step "[3/7] 备份现有配置..."

    BACKUP_DIR="${INSTALL_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"

    # 备份配置
    if [ -f "$CONFIG_DIR/config.yaml" ]; then
        cp -a "$CONFIG_DIR/config.yaml" "$BACKUP_DIR/config.yaml"
        log_success "✓ 已备份配置文件"
    fi

    # 备份数据
    if [ -d "$DATA_DIR" ]; then
        cp -a "$DATA_DIR" "$BACKUP_DIR/data"
        log_success "✓ 已备份数据目录"
    fi

    # 备份二进制
    if [ -f "$INSTALL_DIR/cli-proxy-api" ]; then
        cp -a "$INSTALL_DIR/cli-proxy-api" "$BACKUP_DIR/cli-proxy-api.bak"
        log_success "✓ 已备份可执行文件"
    fi

    log_success "备份完成: $BACKUP_DIR"

    # 停止服务
    SERVICE_WAS_RUNNING=false
    if systemctl is-active --quiet cliproxyapi 2>/dev/null; then
        SERVICE_WAS_RUNNING=true
        systemctl stop cliproxyapi
        log_success "服务已停止"
    fi

    sleep 2
fi

# ==================== 下载并安装 CliproxyAPI ====================

log_step "[${IS_UPGRADE:+4}${IS_UPGRADE:-3}/7] 下载并安装 CliproxyAPI..."

EXPECTED_FILENAME="CLIProxyAPI_${LATEST_VERSION}_${ARCH}.tar.gz"
DOWNLOAD_URL=$(echo "$RELEASE_INFO" | grep -o "\"browser_download_url\": *\"[^\"]*${EXPECTED_FILENAME}[^\"]*\"" | cut -d'"' -f4)

if [ -z "$DOWNLOAD_URL" ]; then
    log_error "无法找到架构 ${ARCH} 的下载地址。"
    exit 1
fi

TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

echo -e "正在下载: $EXPECTED_FILENAME"
if ! wget -q --show-progress "$DOWNLOAD_URL" -O "cli-proxy-api.tar.gz"; then
    log_error "下载失败，请检查网络连接。"
    rm -rf "$TMP_DIR"
    exit 1
fi

log_success "下载完成"

# 解压
tar -xzf "cli-proxy-api.tar.gz"

# 创建安装目录
mkdir -p "$INSTALL_DIR"
mkdir -p "$CONFIG_DIR"
mkdir -p "$DATA_DIR/storage"
mkdir -p "$DATA_DIR/auth"
mkdir -p "$LOG_DIR"

# 移动二进制文件
BINARY_FILE=$(find . -name "cli-proxy-api" -type f | head -1)

if [ -z "$BINARY_FILE" ]; then
    log_error "解压后未找到可执行文件。"
    rm -rf "$TMP_DIR"
    exit 1
fi

mv "$BINARY_FILE" "$INSTALL_DIR/cli-proxy-api"
chmod +x "$INSTALL_DIR/cli-proxy-api"

# 保存版本号
echo "$LATEST_VERSION" > "$INSTALL_DIR/version.txt"

log_success "安装完成: $INSTALL_DIR/cli-proxy-api"

# 清理临时文件
cd /
rm -rf "$TMP_DIR"

# ==================== 生成/恢复配置文件 ====================

log_step "[${IS_UPGRADE:+5}${IS_UPGRADE:-4}/7] 配置文件处理..."

if [ "$IS_UPGRADE" = true ]; then
    # 升级模式：恢复备份的配置
    if [ -f "$BACKUP_DIR/config.yaml" ]; then
        cp -a "$BACKUP_DIR/config.yaml" "$CONFIG_DIR/config.yaml"
        log_success "配置文件已恢复（保留所有设置）"
    else
        log_warning "备份配置不存在，保持现有配置"
    fi
else
    # 全新安装：生成新配置
    generate_api_key() {
        local chars="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        local key="sk-"

        for i in {1..45}; do
            key="${key}${chars:$((RANDOM % ${#chars})):1}"
        done

        echo "$key"
    }

    API_KEY_1=$(generate_api_key)
    API_KEY_2=$(generate_api_key)

    cat > "$CONFIG_DIR/config.yaml" <<EOF
# CliproxyAPI Configuration File
# Auto-generated by install script v2.0

# ==================== Server Configuration ====================
host: "127.0.0.1"
port: $CLIPROXY_PORT

# ==================== Authentication ====================
auth-dir: "$DATA_DIR/auth"

# API keys for client authentication
api-keys:
  - "$API_KEY_1"
  - "$API_KEY_2"

# ==================== Management Panel ====================
remote-management:
  allow-remote: true
  secret-key: "$ADMIN_SECRET"
  disable-control-panel: false
  panel-github-repository: "https://github.com/router-for-me/Cli-Proxy-API-Management-Center"

# ==================== Logging ====================
debug: false
logging-to-file: true
logs-max-total-size-mb: 100

# ==================== Performance ====================
commercial-mode: false
usage-statistics-enabled: false

# ==================== Request Handling ====================
proxy-url: ""
force-model-prefix: false
request-retry: 3
max-retry-interval: 30

quota-exceeded:
  switch-project: true
  switch-preview-model: true

routing:
  strategy: "round-robin"

ws-auth: false

# ==================== TLS ====================
# TLS is handled by Nginx, keep disabled
tls:
  enable: false
  cert: ""
  key: ""
EOF

    log_success "配置文件: $CONFIG_DIR/config.yaml"
    log_info "API 密钥 1: $API_KEY_1"
    log_info "API 密钥 2: $API_KEY_2"
fi

# ==================== SSL 证书处理 ====================

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

# ==================== 申请 SSL 证书 ====================

if [ "$IS_UPGRADE" = false ] && [ -n "$DOMAIN" ]; then
    log_step "[5/7] 配置 SSL 证书..."

    # 创建证书目录
    DOMAIN_SSL_DIR="$SSL_DIR/$DOMAIN"
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

        # 临时 Nginx 配置
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

        if [ $? -eq 0 ] && [ -f "$DOMAIN_SSL_DIR/fullchain.pem" ]; then
            log_success "SSL 证书申请成功 (Let's Encrypt)"
            SSL_TYPE="Let's Encrypt (ECC-256)"
        else
            log_warning "SSL 申请失败，使用自签名证书..."
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "$DOMAIN_SSL_DIR/key.pem" \
                -out "$DOMAIN_SSL_DIR/fullchain.pem" \
                -subj "/CN=$DOMAIN" >/dev/null 2>&1
            SSL_TYPE="自签名证书"
        fi
    else
        # IP 模式：直接生成自签名证书
        log_info "生成自签名证书 (IP 模式)..."

        # 生成支持 IP 的自签名证书
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$DOMAIN_SSL_DIR/key.pem" \
            -out "$DOMAIN_SSL_DIR/fullchain.pem" \
            -subj "/CN=$DOMAIN" \
            -addext "subjectAltName=IP:$DOMAIN" >/dev/null 2>&1

        if [ $? -ne 0 ]; then
            # 旧版 OpenSSL 不支持 -addext，使用备用方法
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "$DOMAIN_SSL_DIR/key.pem" \
                -out "$DOMAIN_SSL_DIR/fullchain.pem" \
                -subj "/CN=$DOMAIN" >/dev/null 2>&1
        fi

        log_success "自签名证书生成成功"
        SSL_TYPE="自签名证书 (IP 模式)"
    fi
fi

# ==================== Nginx 配置（仅全新安装） ====================

if [ "$IS_UPGRADE" = false ] && [ -n "$DOMAIN" ]; then
    log_step "[6/7] 配置 Nginx 反向代理..."

    # 检测 HTTP/3 支持
    NGINX_SUPPORTS_HTTP3=false
    if $NGINX_PATH/sbin/nginx -V 2>&1 | grep -q "http_v3_module"; then
        NGINX_SUPPORTS_HTTP3=true
    fi

    if [ "$USE_HTTP_ONLY" = true ]; then
        # HTTP 模式：仅监听 80 端口
        cat > "$CONF_D/${DOMAIN}.conf" <<'EOF_NGINX_HTTP'
server {
    listen 80;

    server_name DOMAIN_PLACEHOLDER;

    client_max_body_size 100m;
    tcp_nodelay on;

    access_log /var/log/nginx/cliproxyapi_access.log;
    error_log /var/log/nginx/cliproxyapi_error.log warn;

    #CLI-PROXY-API-START

    # WebSocket
    location /v1/ws {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    # OpenAI SSE - Chat Completions
    location /v1/chat/completions {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_set_header Accept-Encoding "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        add_header X-Accel-Buffering no always;
        gzip off;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        chunked_transfer_encoding on;
    }

    # 其他 v1 API
    location /v1/ {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }

    # v0 管理接口
    location /v0/ {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60;
    }

    # 默认
    location / {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }

    #CLI-PROXY-API-END
}
EOF_NGINX_HTTP

        # 替换占位符
        sed -i "s|DOMAIN_PLACEHOLDER|$DOMAIN|g" "$CONF_D/${DOMAIN}.conf"
        sed -i "s|CLIPROXY_PORT_PLACEHOLDER|$CLIPROXY_PORT|g" "$CONF_D/${DOMAIN}.conf"

    elif [ "$NGINX_SUPPORTS_HTTP3" = true ]; then
        # 使用 HTTP/3 配置（394-570行的配置）
        cat > "$CONF_D/${DOMAIN}.conf" <<'EOF_NGINX'
server {
    listen 80;
    listen 443 ssl;
    listen 443 quic;
    http2 on;

    server_name DOMAIN_PLACEHOLDER;

    client_max_body_size 100m;
    tcp_nodelay on;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    #SSL-START
    #HTTP_TO_HTTPS_START
    set $isRedcert 1;
    if ($server_port != 443) {
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
    ssl_protocols TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    add_header Strict-Transport-Security "max-age=31536000";
    add_header Alt-Svc 'quic=":443"; h3=":443"; h3-29=":443"; h3-27=":443";h3-25=":443"; h3-T050=":443"; h3-Q050=":443";h3-Q049=":443";h3-Q048=":443"; h3-Q046=":443"; h3-Q043=":443"';
    error_page 497 https://$host$request_uri;
    #SSL-END

    access_log /var/log/nginx/cliproxyapi_access.log;
    error_log /var/log/nginx/cliproxyapi_error.log warn;

    #CLI-PROXY-API-START

    # WebSocket
    location /v1/ws {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    # OpenAI SSE - Chat Completions
    location /v1/chat/completions {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_set_header Accept-Encoding "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        add_header X-Accel-Buffering no always;
        gzip off;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        chunked_transfer_encoding on;
    }

    # 其他 v1 API
    location /v1/ {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }

    # v0 管理接口
    location /v0/ {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60;
    }

    # 默认
    location / {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }

    #CLI-PROXY-API-END
}
EOF_NGINX
    else
        # HTTP/2 配置（573-747行）
        cat > "$CONF_D/${DOMAIN}.conf" <<'EOF_NGINX_NO_H3'
server {
    listen 80;
    listen 443 ssl;
    http2 on;

    server_name DOMAIN_PLACEHOLDER;

    client_max_body_size 100m;
    tcp_nodelay on;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    #SSL-START
    #HTTP_TO_HTTPS_START
    set $isRedcert 1;
    if ($server_port != 443) {
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
    ssl_protocols TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    add_header Strict-Transport-Security "max-age=31536000";
    error_page 497 https://$host$request_uri;
    #SSL-END

    access_log /var/log/nginx/cliproxyapi_access.log;
    error_log /var/log/nginx/cliproxyapi_error.log warn;

    #CLI-PROXY-API-START

    location /v1/ws {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    location /v1/chat/completions {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Connection "";
        proxy_set_header Accept-Encoding "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        add_header X-Accel-Buffering no always;
        gzip off;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        chunked_transfer_encoding on;
    }

    location /v1/ {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }

    location /v0/ {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60;
    }

    location / {
        proxy_pass http://127.0.0.1:CLIPROXY_PORT_PLACEHOLDER;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }

    #CLI-PROXY-API-END
}
EOF_NGINX_NO_H3
    fi

    # 替换占位符
    sed -i "s|DOMAIN_PLACEHOLDER|$DOMAIN|g" "$CONF_D/${DOMAIN}.conf"
    sed -i "s|SSL_CERT_PLACEHOLDER|$DOMAIN_SSL_DIR/fullchain.pem|g" "$CONF_D/${DOMAIN}.conf"
    sed -i "s|SSL_KEY_PLACEHOLDER|$DOMAIN_SSL_DIR/key.pem|g" "$CONF_D/${DOMAIN}.conf"
    sed -i "s|CLIPROXY_PORT_PLACEHOLDER|$CLIPROXY_PORT|g" "$CONF_D/${DOMAIN}.conf"

    log_success "Nginx 配置已生成"

    # 测试并重载
    if $NGINX_PATH/sbin/nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
        log_success "Nginx 已重载"
    else
        log_error "Nginx 配置测试失败"
        $NGINX_PATH/sbin/nginx -t
    fi
fi

# ==================== Systemd 服务 ====================

log_step "[7/7] 配置 Systemd 服务..."

cat > /etc/systemd/system/cliproxyapi.service <<EOF
[Unit]
Description=CLIProxyAPI Service
Documentation=https://help.router-for.me/cn/
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/cli-proxy-api -config $CONFIG_DIR/config.yaml
Restart=always
RestartSec=10s

Environment="HOME=/root"

NoNewPrivileges=true
PrivateTmp=true

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cliproxyapi >/dev/null 2>&1

# 启动服务
if [ "$IS_UPGRADE" = true ] && [ "$SERVICE_WAS_RUNNING" = true ]; then
    systemctl start cliproxyapi
elif [ "$IS_UPGRADE" = false ]; then
    systemctl start cliproxyapi
fi

sleep 2

if systemctl is-active --quiet cliproxyapi; then
    log_success "服务已启动"
else
    log_warning "服务启动失败，请检查: journalctl -u cliproxyapi -n 50"
fi

# ==================== 完成信息 ====================

clear
echo -e "${GREEN}"
if [ "$IS_UPGRADE" = true ]; then
    cat <<EOF
================================================
       CliproxyAPI 升级成功！
================================================
EOF
    echo -e "${NC}"
    echo -e "旧版本:     ${YELLOW}v${CURRENT_VERSION}${NC}"
    echo -e "新版本:     ${GREEN}v${LATEST_VERSION}${NC}"
    echo ""
    echo -e "${CYAN}[配置保留]${NC}"
    echo -e "配置文件:   已保留"
    echo -e "数据目录:   已保留"
    echo -e "备份位置:   $BACKUP_DIR"
else
    # 确定访问模式显示文本
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

    cat <<EOF
================================================
       CliproxyAPI 安装成功！
================================================
访问模式:  $ACCESS_MODE_TEXT
服务器 IP: $(curl -s https://api.ipify.org 2>/dev/null || echo "N/A")
访问地址:  $DOMAIN

[访问地址]
$( [ "$USE_HTTP_ONLY" = true ] && echo "HTTP:      http://$DOMAIN" || echo "HTTPS:     https://$DOMAIN" )
管理界面:  ${PROTOCOL}://$DOMAIN/management.html
$( [ "$USE_HTTP_ONLY" = true ] && echo "
⚠️  HTTP 模式注意事项:
- 数据传输不加密，API Key 可能泄露
- 仅建议在内网或开发环境使用" )
$( [ "$USE_HTTP_ONLY" = false ] && [ "$USE_DOMAIN" = false ] && echo "
⚠️  IP 模式注意事项:
- 浏览器会提示证书不安全，请点击「高级」→「继续访问」
- API 客户端需要关闭 SSL 验证或信任自签名证书" )

[API 密钥]
密钥 1:    $API_KEY_1
密钥 2:    $API_KEY_2

[管理面板]
访问地址:  ${PROTOCOL}://$DOMAIN/management.html
登录密码:  $ADMIN_SECRET

[配置信息]
版本:      v$LATEST_VERSION
配置文件:  $CONFIG_DIR/config.yaml
数据目录:  $DATA_DIR
日志文件:  $LOG_DIR/cliproxyapi.log

[SSL 证书]
类型:      ${SSL_TYPE:-已存在}
EOF
fi

echo ""
echo -e "${CYAN}[服务管理]${NC}"
echo -e "查看状态:  systemctl status cliproxyapi"
echo -e "启动服务:  systemctl start cliproxyapi"
echo -e "停止服务:  systemctl stop cliproxyapi"
echo -e "重启服务:  systemctl restart cliproxyapi"
echo -e "查看日志:  journalctl -u cliproxyapi -f"
echo ""
echo -e "${GREEN}安装完成！${NC}"
echo "================================================"
echo ""
