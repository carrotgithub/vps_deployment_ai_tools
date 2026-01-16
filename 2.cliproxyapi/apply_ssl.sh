#!/bin/bash

################################################################################
#
# 通用 SSL 证书申请工具 (v1.0)
#
# 功能说明：
#   - 为任意域名申请 Let's Encrypt ECC-256 证书
#   - 自动配置 Nginx（可选）
#   - 支持交互式和非交互式使用
#   - 失败时自动降级为自签名证书
#
# 使用场景：
#   1. 域名尚未解析，安装时跳过了 SSL 申请
#   2. 为新的服务申请证书
#   3. 手动更新证书
#   4. 为多个域名批量申请证书
#
# 使用方法：
#   交互式:   ./apply_ssl.sh
#   非交互式: ./apply_ssl.sh -d api.example.com -s cliproxyapi -p 8317
#
# 参数说明：
#   -d DOMAIN   域名（必填）
#   -s SERVICE  服务名称（用于生成 Nginx 配置文件名，可选）
#   -p PORT     后端服务端口（可选，默认自动检测）
#   -h          显示帮助信息
#
################################################################################

# ==================== 全局配置 ====================

NGINX_PATH="/usr/local/nginx"
CONF_D="$NGINX_PATH/conf/conf.d"
SSL_DIR="$NGINX_PATH/conf/ssl"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== 帮助信息 ====================

show_help() {
    cat <<EOF
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}
   通用 SSL 证书申请工具 v1.0
${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}

${GREEN}功能说明:${NC}
  为任意域名申请 Let's Encrypt ECC-256 证书
  失败时自动降级为自签名证书

${GREEN}使用方法:${NC}
  交互式:   $0
  非交互式: $0 -d <域名> [-s <服务名>] [-p <端口>]

${GREEN}参数说明:${NC}
  -d DOMAIN   域名（必填）
              示例: -d api.example.com

  -s SERVICE  服务名称（可选）
              用于生成 Nginx 配置文件名
              示例: -s cliproxyapi
              生成: cliproxyapi-api.example.com.conf

  -p PORT     后端服务端口（可选）
              如果指定，将生成完整的反向代理配置
              示例: -p 8317

  -h          显示此帮助信息

${GREEN}使用示例:${NC}
  # 仅申请证书，不修改 Nginx 配置
  $0 -d api.example.com

  # 申请证书并生成基础 Nginx 配置
  $0 -d api.example.com -s cliproxyapi

  # 申请证书并生成完整反向代理配置
  $0 -d api.example.com -s cliproxyapi -p 8317

${GREEN}注意事项:${NC}
  1. 必须以 root 权限运行
  2. 域名需要已解析到本服务器
  3. Nginx 必须已安装并运行
  4. 防火墙需开放 80 和 443 端口

EOF
}

# ==================== 参数解析 ====================

DOMAIN=""
SERVICE=""
PORT=""

while getopts "d:s:p:h" opt; do
    case $opt in
        d) DOMAIN="$OPTARG" ;;
        s) SERVICE="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
        h) show_help; exit 0 ;;
        *) show_help; exit 1 ;;
    esac
done

# ==================== 环境检查 ====================

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 必须使用 root 权限运行此脚本。${NC}"
    exit 1
fi

if [ ! -d "$NGINX_PATH" ]; then
    echo -e "${RED}错误: 未检测到 Nginx 安装。${NC}"
    exit 1
fi

if ! systemctl is-active --quiet nginx; then
    echo -e "${RED}错误: Nginx 未运行。${NC}"
    echo -e "请先启动 Nginx: systemctl start nginx"
    exit 1
fi

# ==================== 交互式输入 ====================

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}   通用 SSL 证书申请工具 v1.0${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# 交互式输入域名
if [ -z "$DOMAIN" ]; then
    read -p "请输入域名 (例如 api.example.com): " DOMAIN
fi

# 域名验证
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}错误: 域名不能为空。${NC}"
    exit 1
fi

# 正则验证域名格式
if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    echo -e "${RED}错误: 域名格式不正确。${NC}"
    exit 1
fi

# 交互式输入服务名（可选）
if [ -z "$SERVICE" ]; then
    read -p "服务名称 (留空则不生成 Nginx 配置): " SERVICE
fi

# 交互式输入端口（可选）
if [ -z "$PORT" ] && [ -n "$SERVICE" ]; then
    read -p "后端服务端口 (留空则生成基础配置): " PORT
fi

# ==================== DNS 检查提示 ====================

SERVER_IP=$(curl -s https://api.ipify.org 2>/dev/null || curl -s http://whatismyip.akamai.com 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}⚠️  DNS 解析检查${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "域名:         ${GREEN}$DOMAIN${NC}"
echo -e "服务器 IP:    ${GREEN}$SERVER_IP${NC}"

# 检查域名解析
RESOLVED_IP=$(nslookup $DOMAIN 2>/dev/null | grep -A1 'Name:' | tail -n1 | awk '{print $2}')
if [ -z "$RESOLVED_IP" ]; then
    RESOLVED_IP=$(dig +short $DOMAIN 2>/dev/null | tail -n1)
fi

if [ -n "$RESOLVED_IP" ]; then
    echo -e "域名解析到:   ${GREEN}$RESOLVED_IP${NC}"

    if [ "$RESOLVED_IP" == "$SERVER_IP" ]; then
        echo -e "${GREEN}✓ 域名解析正确${NC}"
    else
        echo -e "${YELLOW}⚠ 域名未解析到本服务器，SSL 申请可能失败${NC}"
        echo -e "${YELLOW}  如果使用 Cloudflare CDN，这是正常的${NC}"
    fi
else
    echo -e "${YELLOW}⚠ 无法解析域名，请确保 DNS 已配置${NC}"
fi

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -p "按回车继续申请证书..."

# ==================== 安装 acme.sh ====================

echo ""
echo -e "${CYAN}>>> [1/3] 检查 acme.sh...${NC}"

if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
    echo -e "正在安装 acme.sh..."
    curl -s https://get.acme.sh | sh -s email=admin@$DOMAIN
    source ~/.bashrc
    echo -e "${GREEN}✓ acme.sh 安装完成${NC}"
else
    echo -e "${GREEN}✓ acme.sh 已安装${NC}"
fi

# ==================== 申请 SSL 证书 ====================

echo -e "${CYAN}>>> [2/3] 申请 SSL 证书...${NC}"

# 创建证书存放目录
DOMAIN_SSL_DIR="$SSL_DIR/$DOMAIN"
mkdir -p "$DOMAIN_SSL_DIR"

# 检查是否存在 Nginx 配置
NGINX_CONF="$CONF_D/${DOMAIN}.conf"
TEMP_CONF=false

if [ ! -f "$NGINX_CONF" ]; then
    # 创建临时配置用于验证
    echo -e "创建临时 Nginx 配置..."
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }
}
EOF
    TEMP_CONF=true
    mkdir -p /var/www/acme
    $NGINX_PATH/sbin/nginx -t >/dev/null 2>&1 && systemctl reload nginx
fi

# 申请 ECC-256 证书
echo -e "正在申请 Let's Encrypt 证书 (ECC-256)..."
~/.acme.sh/acme.sh --issue -d "$DOMAIN" --webroot /var/www/acme --keylength ec-256

# 安装证书
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --key-file       "$DOMAIN_SSL_DIR/key.pem" \
    --fullchain-file "$DOMAIN_SSL_DIR/fullchain.pem" \
    --reloadcmd     "systemctl reload nginx"

if [ $? -eq 0 ] && [ -f "$DOMAIN_SSL_DIR/fullchain.pem" ]; then
    echo -e "${GREEN}✓ SSL 证书申请成功 (Let's Encrypt ECC-256)${NC}"
    SSL_TYPE="Let's Encrypt (ECC-256)"
    SSL_OK=true
else
    echo -e "${YELLOW}⚠ SSL 申请失败，生成自签名证书...${NC}"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$DOMAIN_SSL_DIR/key.pem" \
        -out "$DOMAIN_SSL_DIR/fullchain.pem" \
        -subj "/CN=$DOMAIN" 2>/dev/null
    SSL_TYPE="Self-Signed"
    SSL_OK=false
fi

# ==================== 配置 Nginx ====================

echo -e "${CYAN}>>> [3/3] 配置 Nginx...${NC}"

if [ -n "$SERVICE" ]; then
    # 生成配置文件名
    if [ "$TEMP_CONF" = true ]; then
        # 如果是临时配置，使用 域名.conf
        FINAL_CONF="$CONF_D/${DOMAIN}.conf"
    else
        # 如果已有配置，备份后覆盖
        FINAL_CONF="$NGINX_CONF"
        if [ -f "$FINAL_CONF" ]; then
            cp "$FINAL_CONF" "${FINAL_CONF}.bak.$(date +%Y%m%d%H%M%S)"
            echo -e "${YELLOW}已备份原配置: ${FINAL_CONF}.bak${NC}"
        fi
    fi

    # 根据是否指定端口生成不同配置
    if [ -n "$PORT" ]; then
        # 生成完整反向代理配置
        cat > "$FINAL_CONF" <<EOF
# HTTP → HTTPS 重定向
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS 反向代理
server {
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;

    ssl_certificate $DOMAIN_SSL_DIR/fullchain.pem;
    ssl_certificate_key $DOMAIN_SSL_DIR/key.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    access_log /var/log/nginx/${SERVICE}_access.log main;
    error_log /var/log/nginx/${SERVICE}_error.log warn;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
EOF
        echo -e "${GREEN}✓ 已生成完整反向代理配置${NC}"
    else
        # 生成基础 HTTPS 配置
        cat > "$FINAL_CONF" <<EOF
# HTTP → HTTPS 重定向
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS 基础配置
server {
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;

    ssl_certificate $DOMAIN_SSL_DIR/fullchain.pem;
    ssl_certificate_key $DOMAIN_SSL_DIR/key.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    root /var/www/html;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
        echo -e "${GREEN}✓ 已生成基础 HTTPS 配置${NC}"
    fi

    echo -e "配置文件: ${YELLOW}$FINAL_CONF${NC}"
else
    echo -e "${YELLOW}未指定服务名，跳过 Nginx 配置生成${NC}"
    if [ "$TEMP_CONF" = true ]; then
        echo -e "${YELLOW}保留临时验证配置${NC}"
    fi
fi

# 测试并重载 Nginx
if $NGINX_PATH/sbin/nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    echo -e "${GREEN}✓ Nginx 配置测试通过并已重载${NC}"
else
    echo -e "${RED}⚠ Nginx 配置测试失败，请检查配置${NC}"
    $NGINX_PATH/sbin/nginx -t
fi

# ==================== 输出结果 ====================

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}   SSL 证书申请完成${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "域名:       ${CYAN}$DOMAIN${NC}"
echo -e "证书类型:   ${CYAN}$SSL_TYPE${NC}"
echo -e "证书目录:   ${CYAN}$DOMAIN_SSL_DIR/${NC}"
echo -e "  - 私钥:   ${YELLOW}key.pem${NC}"
echo -e "  - 证书:   ${YELLOW}fullchain.pem${NC}"

if [ -n "$SERVICE" ]; then
    echo -e "Nginx配置:  ${CYAN}$FINAL_CONF${NC}"
fi

echo ""
echo -e "${CYAN}[访问地址]${NC}"
echo -e "HTTP:       ${YELLOW}http://$DOMAIN${NC}"
echo -e "HTTPS:      ${YELLOW}https://$DOMAIN${NC}"

if [ "$SSL_OK" = true ]; then
    echo ""
    echo -e "${GREEN}[证书续期]${NC}"
    echo -e "acme.sh 已自动配置 cron 任务，证书将在到期前自动续期。"
    echo -e "查看任务: ${YELLOW}crontab -l | grep acme${NC}"
else
    echo ""
    echo -e "${YELLOW}[提示]${NC}"
    echo -e "使用自签名证书，客户端需要:"
    echo -e "  1. 跳过证书验证（不安全）"
    echo -e "  2. 或手动信任此证书"
    echo -e ""
    echo -e "建议确保域名正确解析后，重新运行此脚本申请有效证书。"
fi

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
