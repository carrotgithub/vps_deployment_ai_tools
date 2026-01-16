#!/bin/bash

################################################################################
#
# V2Ray 核心配置脚本
#
# 功能说明：
#   1. 安装 V2Ray 核心
#   2. 自动申请 ECC SSL 证书 (更小更快)
#   3. 生成 Nginx 单域名配置 (支持 WebSocket + TLS)
#   4. 预留 API 转发入口
#
# 前置条件：
#   - 必须先运行 install_nginx.sh
#   - 域名必须已经解析到本服务器
#
################################################################################

# ==================== 全局配置 ====================

V2RAY_PORT=10000
NGINX_PATH="/usr/local/nginx"
CONF_D="$NGINX_PATH/conf/conf.d"
SSL_DIR="$NGINX_PATH/conf/ssl"
WEB_ROOT="/var/www/static"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== 检查环境 ====================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 必须使用 root 权限运行。${NC}"
    exit 1
fi

if [ ! -d "$NGINX_PATH" ]; then
    echo -e "${RED}错误: 未检测到 Nginx，请先运行 install_nginx.sh${NC}"
    exit 1
fi

# ==================== 1. 交互输入 ====================
echo -e "${CYAN}>>> 请输入节点配置信息${NC}"
echo ""
read -p "请输入域名 (例如 v2.example.com): " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}错误: 域名不能为空。${NC}"
    exit 1
fi

# 自动生成随机路径和 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)
WS_PATH="/ws-$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 8)"

echo ""
echo -e "配置预览:"
echo -e "域名: ${GREEN}$DOMAIN${NC}"
echo -e "UUID: ${GREEN}$UUID${NC}"
echo -e "路径: ${GREEN}$WS_PATH${NC}"
echo ""
read -p "确认继续安装? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then exit 0; fi

# ==================== 2. 安装 V2Ray ====================
echo -e "${CYAN}>>> [1/4] 安装/更新 V2Ray...${NC}"
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

# 生成配置
echo -e "${CYAN}>>> [2/4] 配置 V2Ray (WebSocket)...${NC}"
mkdir -p /usr/local/etc/v2ray
mkdir -p /var/log/v2ray

cat > /usr/local/etc/v2ray/config.json <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/v2ray/access.log",
    "error": "/var/log/v2ray/error.log"
  },
  "inbounds": [{
    "port": $V2RAY_PORT,
    "listen": "127.0.0.1",
    "protocol": "vmess",
    "settings": {
      "clients": [{ "id": "$UUID", "alterId": 0 }]
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": { "path": "$WS_PATH" }
    }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF

systemctl enable v2ray
systemctl restart v2ray

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

# ==================== 3. 申请 SSL 证书 (ECC) ====================
echo -e "${CYAN}>>> [3/4] 申请 SSL 证书 (ECC)...${NC}"

# 确保 acme.sh 配置正确
ensure_acme_sh_config "$DOMAIN"
[ -f ~/.bashrc ] && source ~/.bashrc

# 创建证书存放目录
DOMAIN_SSL_DIR="$SSL_DIR/$DOMAIN"
mkdir -p "$DOMAIN_SSL_DIR"

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
systemctl reload nginx

# 申请证书 (ECC 256)
~/.acme.sh/acme.sh --issue -d "$DOMAIN" --webroot /var/www/acme --keylength ec-256

# 安装证书
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --key-file       "$DOMAIN_SSL_DIR/key.pem" \
    --fullchain-file "$DOMAIN_SSL_DIR/fullchain.pem" \
    --reloadcmd     "systemctl reload nginx"

if [ $? -eq 0 ] && [ -f "$DOMAIN_SSL_DIR/fullchain.pem" ]; then
    echo -e "${GREEN}✓ SSL 证书申请成功 (ECC)${NC}"
    SSL_OK=true
else
    echo -e "${YELLOW}⚠ SSL 申请失败，降级为自签名证书...${NC}"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$DOMAIN_SSL_DIR/key.pem" \
        -out "$DOMAIN_SSL_DIR/fullchain.pem" \
        -subj "/CN=$DOMAIN" >/dev/null 2>&1
    SSL_OK=false
fi

# ==================== 4. 配置 Nginx 最终版 ====================
echo -e "${CYAN}>>> [4/4] 生成 Nginx 最终配置...${NC}"

# 自动获取 Cloudflare IP 列表 (如果网络不通则使用内置列表)
CF_IPS=""
# 这里为了脚本速度，直接使用内置的常见 CF IP 段，避免 curl 卡住
CF_CONF_BLOCK=" \
    # Cloudflare Real IP
    set_real_ip_from 173.245.48.0/20;
    set_real_ip_from 103.21.244.0/22;
    set_real_ip_from 103.22.200.0/22;
    set_real_ip_from 103.31.4.0/22;
    set_real_ip_from 141.101.64.0/18;
    set_real_ip_from 108.162.192.0/18;
    set_real_ip_from 190.93.240.0/20;
    set_real_ip_from 188.114.96.0/20;
    set_real_ip_from 197.234.240.0/22;
    set_real_ip_from 198.41.128.0/17;
    set_real_ip_from 162.158.0.0/15;
    set_real_ip_from 104.16.0.0/13;
    set_real_ip_from 104.24.0.0/14;
    set_real_ip_from 172.64.0.0/13;
    set_real_ip_from 131.0.72.0/22;
    set_real_ip_from 2400:cb00::/32;
    set_real_ip_from 2606:4700::/32;
    set_real_ip_from 2803:f800::/32;
    set_real_ip_from 2405:b500::/32;
    set_real_ip_from 2405:8100::/32;
    set_real_ip_from 2a06:98c0::/29;
    set_real_ip_from 2c0f:f248::/32;
    real_ip_header CF-Connecting-IP;
"

cat > "$CONF_D/${DOMAIN}.conf" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name $DOMAIN;

    ssl_certificate $DOMAIN_SSL_DIR/fullchain.pem;
    ssl_certificate_key $DOMAIN_SSL_DIR/key.pem;
    
    # 优化 SSL 设置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    $CF_CONF_BLOCK

    root $WEB_ROOT;
    index index.html;

    # 1. 静态伪装站 (默认访问路径)
    location / {
        try_files \$uri \$uri/ =404;
    }

    # 2. V2Ray 代理路径
    location $WS_PATH {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$V2RAY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        
        # 传递真实 IP 给 V2Ray
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # 3. [扩展预留] API 转发示例
    # 如果您以后需要添加 API 转发，请取消注释并修改下方代码
    # 或者新建一个 conf.d/api.conf 文件
    # location /api/ {
    #     proxy_pass http://YOUR_BACKEND_IP:PORT;
    #     proxy_set_header Host \$host;
    #     proxy_set_header X-Real-IP \$remote_addr;
    # }
}
EOF

systemctl reload nginx

# ==================== 5. 输出结果 ====================
IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
INFO_FILE="$(dirname "$0")/v2ray_node_info.txt"

cat > "$INFO_FILE" <<EOF
================================================
          V2Ray 节点配置完成 (v3.0)
================================================
服务器 IP: $IP
域名:      $DOMAIN

[连接参数]
协议:      VMess
地址:      $DOMAIN
端口:      443
UUID:      $UUID
传输:      ws (WebSocket)
路径:      $WS_PATH
TLS:       开启 (tls)

[注意事项]
1. 证书类型: $( [ "$SSL_OK" = true ] && echo "ECC (Let's Encrypt)" || echo "自签名 (请开启 AllowInsecure)" )
2. Cloudflare: 
   - 追求速度: 请在 CF 后台开启【灰色云朵】(直连)
   - 追求隐匿: 请开启【橙色云朵】(CDN代理)
   - 此配置兼容两种模式

[扩展指南]
如果需要添加 API 站点，请在 $CONF_D 下新建 .conf 文件
并执行 systemctl reload nginx 即可。
================================================
EOF

clear
echo -e "${GREEN}"
cat "$INFO_FILE"
echo -e "${NC}"
echo -e "配置信息已保存至: ${YELLOW}$INFO_FILE${NC}"
