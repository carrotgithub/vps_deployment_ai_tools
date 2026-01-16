#!/bin/bash

################################################################################
#
# CN2 VPS SSL 证书申请脚本
#
# 功能说明：
#   1. 为 CN2 VPS 的反向代理域名申请 Let's Encrypt 证书
#   2. 自动配置 Nginx ACME 验证路径
#   3. 使用主域名邮箱策略（与性能服务器统一）
#   4. 失败自动降级到自签名证书
#
# 使用方法：
#   ./apply_ssl_cn2.sh -d newapi.example.com  # 【需替换】替换为你的域名
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
        log_info "安装 acme.sh..."
        curl -s https://get.acme.sh | sh -s email="$expected_email" >/dev/null 2>&1
        [ -f ~/.bashrc ] && source ~/.bashrc
        return 0
    fi

    if [ -f ~/.acme.sh/account.conf ]; then
        local current_email=$(grep "^ACCOUNT_EMAIL=" ~/.acme.sh/account.conf 2>/dev/null | cut -d"'" -f2)

        if ! is_valid_ssl_email "$current_email"; then
            log_warning "检测到无效邮箱配置: $current_email"
            log_info "修复为: $expected_email"
            sed -i "s/^ACCOUNT_EMAIL=.*/ACCOUNT_EMAIL='$expected_email'/g" ~/.acme.sh/account.conf
            rm -rf ~/.acme.sh/ca/*/account.json 2>/dev/null || true
        fi
    fi
}

# ==================== 参数解析 ====================

DOMAIN=""

while getopts "d:" opt; do
    case $opt in
        d)
            DOMAIN="$OPTARG"
            ;;
        *)
            echo "使用方法: $0 -d <域名>"
            echo "示例: $0 -d newapi.example.com"  # 【需替换】替换为你的域名
            exit 1
            ;;
    esac
done

if [ -z "$DOMAIN" ]; then
    log_error "请指定域名"
    echo "使用方法: $0 -d <域名>"
    exit 1
fi

# ==================== 环境检查 ====================

if [ "$EUID" -ne 0 ]; then
    log_error "必须使用 root 权限运行"
    exit 1
fi

if [ ! -d "$NGINX_PATH" ]; then
    log_error "未检测到 Nginx，请先运行 install_nginx.sh"
    exit 1
fi

# ==================== 欢迎信息 ====================

clear
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}   CN2 VPS SSL 证书申请程序${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
log_info "域名: $DOMAIN"
echo ""

# DNS 提示
SERVER_IP=$(curl -s https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
echo -e "${YELLOW}⚠️  请确保域名已解析到本服务器:${NC}"
echo -e "域名:   ${GREEN}$DOMAIN${NC}"
echo -e "目标IP: ${GREEN}$SERVER_IP${NC}"
echo ""
read -p "按回车键继续，或 Ctrl+C 取消..." -r
echo ""

# ==================== 步骤1: 确保 acme.sh 配置正确 ====================

log_info "[1/4] 检查 acme.sh 配置..."

ensure_acme_sh_config "$DOMAIN"
[ -f ~/.bashrc ] && source ~/.bashrc

if [ -f ~/.acme.sh/acme.sh ]; then
    log_success "acme.sh 配置正常"
    log_info "邮箱: $(get_main_domain_email "$DOMAIN")"
else
    log_error "acme.sh 安装失败"
    exit 1
fi

echo ""

# ==================== 步骤2: 创建证书目录 ====================

log_info "[2/4] 创建证书目录..."

DOMAIN_SSL_DIR="$SSL_DIR/$DOMAIN"
mkdir -p "$DOMAIN_SSL_DIR"
log_success "证书目录: $DOMAIN_SSL_DIR"

echo ""

# ==================== 步骤3: 配置临时 Nginx（用于 ACME 验证）====================

log_info "[3/4] 配置 Nginx ACME 验证路径..."

# 创建临时配置（仅用于证书申请）
cat > "$CONF_D/${DOMAIN}.tmp.conf" <<EOF
# 临时配置（用于 ACME 验证）
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    location / {
        return 200 'SSL certificate applying...';
        add_header Content-Type text/plain;
    }
}
EOF

# 创建 ACME 验证目录
mkdir -p /var/www/acme
chmod 755 /var/www/acme

# 测试 Nginx 配置
if $NGINX_PATH/sbin/nginx -t >/dev/null 2>&1; then
    systemctl reload nginx >/dev/null 2>&1 || $NGINX_PATH/sbin/nginx -s reload >/dev/null 2>&1
    log_success "Nginx 临时配置已应用"
else
    log_error "Nginx 配置测试失败"
    $NGINX_PATH/sbin/nginx -t
    exit 1
fi

echo ""

# ==================== 步骤4: 申请 SSL 证书 ====================

log_info "[4/4] 申请 Let's Encrypt 证书..."
log_info "证书类型: ECC-256"
log_info "验证方式: Webroot (/var/www/acme)"

echo ""

# 申请证书
if ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --webroot /var/www/acme --keylength ec-256; then
    log_success "✓ 证书申请成功"

    # 安装证书
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file "$DOMAIN_SSL_DIR/key.pem" \
        --fullchain-file "$DOMAIN_SSL_DIR/fullchain.pem" \
        --reloadcmd "systemctl reload nginx 2>/dev/null || /usr/local/nginx/sbin/nginx -s reload"

    if [ $? -eq 0 ]; then
        log_success "✓ 证书已安装"
        SSL_SUCCESS=true
        SSL_TYPE="Let's Encrypt (ECC-256)"
    else
        log_error "证书安装失败"
        SSL_SUCCESS=false
    fi
else
    log_warning "Let's Encrypt 证书申请失败"
    log_info "常见原因:"
    log_info "  1. DNS 未解析到本服务器"
    log_info "  2. 防火墙阻止 80 端口"
    log_info "  3. 域名被其他服务占用"
    echo ""
    log_warning "降级为自签名证书..."

    # 生成自签名证书
    openssl req -x509 -nodes -days 3650 -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$DOMAIN_SSL_DIR/key.pem" \
        -out "$DOMAIN_SSL_DIR/fullchain.pem" \
        -subj "/CN=$DOMAIN" 2>/dev/null

    if [ $? -eq 0 ]; then
        log_success "✓ 自签名证书已生成"
        SSL_SUCCESS=true
        SSL_TYPE="Self-Signed (浏览器会提示不安全)"
    else
        log_error "自签名证书生成失败"
        SSL_SUCCESS=false
    fi
fi

# 删除临时配置
rm -f "$CONF_D/${DOMAIN}.tmp.conf"

echo ""

# ==================== 完成信息 ====================

if [ "$SSL_SUCCESS" = true ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  SSL 证书申请完成！${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "域名:       ${CYAN}$DOMAIN${NC}"
    echo -e "证书类型:   ${CYAN}$SSL_TYPE${NC}"
    echo -e "证书路径:   ${YELLOW}$DOMAIN_SSL_DIR/${NC}"
    echo -e "  ├─ key.pem (私钥)"
    echo -e "  └─ fullchain.pem (证书链)"
    echo ""
    echo -e "${CYAN}[下一步操作]${NC}"
    echo -e "1. 部署反向代理配置:"
    echo -e "   ${YELLOW}cp nginx_newapi_proxy.conf $CONF_D/${DOMAIN}.conf${NC}"
    echo ""
    echo -e "2. 测试并重载 Nginx:"
    echo -e "   ${YELLOW}$NGINX_PATH/sbin/nginx -t && systemctl reload nginx${NC}"
    echo ""
    echo -e "3. 验证 SSL 证书:"
    echo -e "   ${YELLOW}curl -I https://$DOMAIN${NC}"
    echo ""

    if [ "$SSL_TYPE" = "Self-Signed (浏览器会提示不安全)" ]; then
        echo -e "${YELLOW}[提示] 使用自签名证书${NC}"
        echo -e "DNS 配置完成后可重新申请正式证书:"
        echo -e "  ${YELLOW}$0 -d $DOMAIN${NC}"
        echo ""
    fi

    echo -e "${CYAN}[证书自动续期]${NC}"
    echo -e "Let's Encrypt 证书有效期 90 天"
    echo -e "acme.sh 已配置 cron 自动续期任务"
    echo -e "查看 cron: ${YELLOW}crontab -l | grep acme${NC}"
    echo ""
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  SSL 证书申请失败${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    log_error "请检查错误信息并重试"
    exit 1
fi
