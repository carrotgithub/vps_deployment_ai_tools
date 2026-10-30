#!/bin/bash

################################################################################
#
# Hysteria2 一键部署脚本
#
# 设计原则:
#   - 混合模式: 默认非交互直接跑, 支持环境变量覆盖, INTERACTIVE=1 开交互确认
#   - 复用已有 TLS 证书, 不申请证书, 不改 Nginx, 也不动其他代理服务
#   - 可重入: 再跑只补齐二进制和单元; 已有认证密码保持不变, ROTATE=1 才换密码
#   - UDP 监听可与 Nginx 的 TCP 443 共存。本机若已有程序占用该 UDP 端口则拒绝继续
#
# 环境变量:
#   DOMAIN            证书对应域名, 同时作为 SNI          (必填)
#   TLS_CERT          证书 fullchain                      (默认 /usr/local/nginx/conf/ssl/$DOMAIN/fullchain.pem)
#   TLS_KEY           证书私钥                            (默认同目录 key.pem)
#   HY2_PORT          本机 UDP 监听端口                   (默认 443)
#   PUBLIC_IP         分享链接里的地址                    (默认自动探测)
#   PUBLIC_PORT       分享链接里的端口                    (默认=HY2_PORT, NAT 场景才需要另填)
#   SERVICE           systemd 单元名                      (默认 hysteria)
#   TAG               分享链接名称                        (默认=DOMAIN)
#   AUTH_PASSWORD     指定认证密码                        (仅首次或 ROTATE=1 时生效, 须为 URL 安全字符)
#   ROTATE            1=重新生成密码                      (默认 0)
#   SOCKS_ADDR        出站 SOCKS, 形如 host:port          (不设则直连出站)
#   SOCKS_USER        SOCKS 用户名                        (可空)
#   SOCKS_PASS        SOCKS 密码                          (可空)
#   HYSTERIA_VERSION  版本号, 不带 v                      (默认 2.13.0)
#   INTERACTIVE       1=交互确认                          (默认 0)
#
# 用法示例:
#   DOMAIN=example.com bash install_hysteria2.sh
#   DOMAIN=example.com HY2_PORT=24443 bash install_hysteria2.sh
#   DOMAIN=example.com SOCKS_ADDR=1.2.3.4:1080 SOCKS_USER=u SOCKS_PASS=p SERVICE=hysteria-proxy bash install_hysteria2.sh
#
################################################################################

set -euo pipefail

# ==================== 默认配置 ====================
DOMAIN="${DOMAIN:-}"
TLS_CERT="${TLS_CERT:-}"
TLS_KEY="${TLS_KEY:-}"
HY2_PORT="${HY2_PORT:-443}"
PUBLIC_IP="${PUBLIC_IP:-}"
PUBLIC_PORT="${PUBLIC_PORT:-}"
SERVICE="${SERVICE:-hysteria}"
TAG="${TAG:-}"
AUTH_PASSWORD="${AUTH_PASSWORD:-}"
ROTATE="${ROTATE:-0}"
SOCKS_ADDR="${SOCKS_ADDR:-}"
SOCKS_USER="${SOCKS_USER:-}"
SOCKS_PASS="${SOCKS_PASS:-}"
HYSTERIA_VERSION="${HYSTERIA_VERSION:-2.13.0}"
INTERACTIVE="${INTERACTIVE:-0}"

BIN_PATH="/usr/local/bin/hysteria"
CONF_DIR="/etc/hysteria"

# ==================== 颜色 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}>>> $*${NC}"; }
ok()   { echo -e "${GREEN}[ok] $*${NC}"; }
warn() { echo -e "${YELLOW}[!] $*${NC}"; }
err()  { echo -e "${RED}[x] $*${NC}" >&2; }

yaml_quote() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

# ==================== 前置检查 ====================
if [ "$(id -u)" -ne 0 ]; then
    err "必须使用 root 权限运行"
    exit 1
fi

# ==================== 交互确认 (可选) ====================
if [ "$INTERACTIVE" = "1" ]; then
    echo -e "${CYAN}====== 部署参数确认 ======${NC}"
    read -r -p "域名 / SNI [当前: ${DOMAIN:-未填}]: " v && [ -n "$v" ] && DOMAIN="$v"
    read -r -p "UDP 监听端口 [默认: $HY2_PORT]: " v && [ -n "$v" ] && HY2_PORT="$v"
    read -r -p "systemd 单元名 [默认: $SERVICE]: " v && [ -n "$v" ] && SERVICE="$v"
    read -r -p "分享链接名称 [默认: 域名]: " v && [ -n "$v" ] && TAG="$v"
    read -r -p "出站 SOCKS (host:port, 直连则留空) [当前: ${SOCKS_ADDR:-无}]: " v && SOCKS_ADDR="$v"
    if [ -n "$SOCKS_ADDR" ]; then
        read -r -p "SOCKS 用户名 [当前: ${SOCKS_USER:-无}]: " v && SOCKS_USER="$v"
        read -r -p "SOCKS 密码 [留空表示不改已输入的值]: " v && [ -n "$v" ] && SOCKS_PASS="$v"
    fi
fi

if [ -z "$DOMAIN" ]; then
    err "必须设置 DOMAIN, 例如 DOMAIN=example.com"
    exit 1
fi
if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
    err "DOMAIN 含有非法字符: $DOMAIN"
    exit 1
fi
if ! [[ "$HY2_PORT" =~ ^[0-9]+$ ]] || [ "$HY2_PORT" -lt 1 ] || [ "$HY2_PORT" -gt 65535 ]; then
    err "HY2_PORT 不是有效端口: $HY2_PORT"
    exit 1
fi
if ! [[ "$SERVICE" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    err "SERVICE 不是合法的单元名: $SERVICE"
    exit 1
fi
if [ -n "$SOCKS_ADDR" ] && ! [[ "$SOCKS_ADDR" =~ ^[^[:space:]]+:[0-9]+$ ]]; then
    err "SOCKS_ADDR 需要写成 host:port, 当前是: $SOCKS_ADDR"
    exit 1
fi

[ -z "$TAG" ] && TAG="$DOMAIN"
[ -z "$TLS_CERT" ] && TLS_CERT="/usr/local/nginx/conf/ssl/${DOMAIN}/fullchain.pem"
[ -z "$TLS_KEY" ] && TLS_KEY="/usr/local/nginx/conf/ssl/${DOMAIN}/key.pem"
[ -z "$PUBLIC_PORT" ] && PUBLIC_PORT="$HY2_PORT"

CONFIG_PATH="${CONF_DIR}/${SERVICE}.yaml"
SERVICE_PATH="/etc/systemd/system/${SERVICE}.service"
INFO_FILE="/root/${SERVICE}.info.txt"

if [ ! -s "$TLS_CERT" ] || [ ! -s "$TLS_KEY" ]; then
    err "证书不存在或不完整: $TLS_CERT / $TLS_KEY"
    err "先用 2.cliproxyapi/apply_ssl.sh 签发, 或通过 TLS_CERT / TLS_KEY 指定已有文件"
    exit 1
fi

# ==================== 1. 安装二进制 ====================
log "[1/5] 安装 Hysteria2 v${HYSTERIA_VERSION}"

if ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates >/dev/null
    else
        err "缺少 curl, 且不是 apt 系统"
        exit 1
    fi
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)  HY_ARCH="amd64" ;;
    aarch64|arm64) HY_ARCH="arm64" ;;
    *) err "不支持的架构: $ARCH"; exit 1 ;;
esac

NEED_DL=1
if [ -x "$BIN_PATH" ]; then
    CUR=$("$BIN_PATH" version 2>&1 || true)
    if printf '%s\n' "$CUR" | grep -q "${HYSTERIA_VERSION}"; then
        NEED_DL=0
        ok "已安装 v${HYSTERIA_VERSION}, 跳过下载"
    fi
fi

if [ "$NEED_DL" = "1" ]; then
    ASSET="hysteria-linux-${HY_ARCH}"
    DL_URL="https://github.com/apernet/hysteria/releases/download/app/v${HYSTERIA_VERSION}/${ASSET}"
    TMP=$(mktemp)
    if ! curl -fL --retry 3 --retry-delay 2 -o "$TMP" "$DL_URL"; then
        warn "GitHub 直连失败, 尝试 ghproxy..."
        curl -fL --retry 3 --retry-delay 2 -o "$TMP" "https://ghproxy.com/${DL_URL}" \
            || { err "下载 Hysteria2 失败"; rm -f "$TMP"; exit 1; }
    fi
    install -m 755 "$TMP" "$BIN_PATH"
    rm -f "$TMP"
    VER_LINE=$("$BIN_PATH" version 2>&1 | head -1)
    ok "${VER_LINE} 已安装到 $BIN_PATH"
fi

# ==================== 2. 认证密码 ====================
log "[2/5] 确定认证密码"

read_password() {
    [ -f "$CONFIG_PATH" ] || return 0
    awk '
        /^auth:/ { in_auth=1; next }
        in_auth && /^[^[:space:]]/ { in_auth=0 }
        in_auth && /^[[:space:]]+password:/ {
            sub(/^[[:space:]]*password:[[:space:]]*/, "")
            gsub(/^"/, ""); gsub(/"$/, "")
            print
            exit
        }
    ' "$CONFIG_PATH"
}

if [ "$ROTATE" = "1" ]; then
    if [ -n "$AUTH_PASSWORD" ]; then
        PASSWORD="$AUTH_PASSWORD"
    else
        PASSWORD=$(openssl rand -hex 16)
    fi
    warn "ROTATE=1, 认证密码已更换, 旧分享链接失效"
elif [ -f "$CONFIG_PATH" ]; then
    PASSWORD=$(read_password || true)
    if [ -z "$PASSWORD" ]; then
        err "已有配置读不出密码: $CONFIG_PATH"
        exit 1
    fi
    if [ -n "$AUTH_PASSWORD" ] && [ "$AUTH_PASSWORD" != "$PASSWORD" ]; then
        warn "已忽略 AUTH_PASSWORD。要换密码请加 ROTATE=1"
    fi
    ok "沿用已有认证密码"
else
    if [ -n "$AUTH_PASSWORD" ]; then
        PASSWORD="$AUTH_PASSWORD"
    else
        PASSWORD=$(openssl rand -hex 16)
    fi
    ok "已生成新的认证密码"
fi

if ! [[ "$PASSWORD" =~ ^[A-Za-z0-9._~-]+$ ]]; then
    err "认证密码含有不能放进分享链接的字符。请改用十六进制, 或让脚本自动生成"
    exit 1
fi

# ==================== 3. 端口占用 ====================
log "[3/5] 检查 UDP ${HY2_PORT}"

LISTENERS=$(ss -ulnpH "sport = :${HY2_PORT}" 2>/dev/null || true)
if [ -n "$LISTENERS" ]; then
    if printf '%s\n' "$LISTENERS" | grep -q hysteria; then
        ok "UDP ${HY2_PORT} 已由 hysteria 监听, 将重启本服务"
    else
        err "UDP ${HY2_PORT} 已被其他进程占用:"
        printf '%s\n' "$LISTENERS" >&2
        exit 1
    fi
else
    ok "UDP ${HY2_PORT} 空闲"
fi

# ==================== 4. 配置与 systemd ====================
log "[4/5] 写入配置并启动 ${SERVICE}"

mkdir -p "$CONF_DIR"
umask 077

{
    echo "listen: :${HY2_PORT}"
    echo "tls:"
    echo "  cert: ${TLS_CERT}"
    echo "  key: ${TLS_KEY}"
    echo "auth:"
    echo "  type: password"
    printf '  password: %s\n' "$(yaml_quote "$PASSWORD")"
    echo "ignoreClientBandwidth: true"
    if [ -n "$SOCKS_ADDR" ]; then
        echo "outbounds:"
        echo "  - name: proxy"
        echo "    type: socks5"
        echo "    socks5:"
        printf '      addr: %s\n' "$(yaml_quote "$SOCKS_ADDR")"
        printf '      username: %s\n' "$(yaml_quote "$SOCKS_USER")"
        printf '      password: %s\n' "$(yaml_quote "$SOCKS_PASS")"
    fi
} > "$CONFIG_PATH"
chmod 600 "$CONFIG_PATH"

cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Hysteria2 Server (${SERVICE})
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} server -c ${CONFIG_PATH}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${HY2_PORT}/udp" >/dev/null
    ok "ufw 已放行 UDP ${HY2_PORT}"
fi

if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --add-port="${HY2_PORT}/udp" --permanent >/dev/null
    firewall-cmd --reload >/dev/null
    ok "firewalld 已放行 UDP ${HY2_PORT}"
fi

INPUT_POLICY=$(iptables -S INPUT 2>/dev/null | awk '$1=="-P" && $2=="INPUT" { print $3; exit }')
if [ "$INPUT_POLICY" = "DROP" ] || [ "$INPUT_POLICY" = "REJECT" ]; then
    iptables -C INPUT -p udp --dport "$HY2_PORT" -j ACCEPT >/dev/null 2>&1 \
        || iptables -I INPUT -p udp --dport "$HY2_PORT" -j ACCEPT
    ok "iptables INPUT 为 ${INPUT_POLICY}, 已放行 UDP ${HY2_PORT}"
fi

systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1 || true
systemctl restart "$SERVICE"
sleep 1

if ! systemctl is-active --quiet "$SERVICE"; then
    err "${SERVICE} 启动失败:"
    journalctl -u "$SERVICE" -n 40 --no-pager >&2 || true
    exit 1
fi
if ! ss -ulnpH "sport = :${HY2_PORT}" | grep -q hysteria; then
    err "${SERVICE} 在运行, 但没有监听 UDP ${HY2_PORT}"
    journalctl -u "$SERVICE" -n 40 --no-pager >&2 || true
    exit 1
fi
ok "${SERVICE} 正在监听 UDP ${HY2_PORT}"

# ==================== 5. 分享链接 ====================
log "[5/5] 生成分享链接"

if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
             || curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
             || echo "")
fi
if [ -z "$PUBLIC_IP" ]; then
    err "探测不到公网 IP, 请设置 PUBLIC_IP"
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    TAG_ENC=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$TAG")
else
    TAG_ENC="$TAG"
fi

SHARE_URL="hysteria2://${PASSWORD}@${PUBLIC_IP}:${PUBLIC_PORT}?sni=${DOMAIN}#${TAG_ENC}"

if [ -n "$SOCKS_ADDR" ]; then
    EGRESS="SOCKS ${SOCKS_ADDR}"
else
    EGRESS="直连 (本机 ${PUBLIC_IP})"
fi

cat > "$INFO_FILE" <<EOF
===== Hysteria2 部署信息 =====
生成时间: $(date '+%Y-%m-%d %H:%M:%S')

Server     : ${PUBLIC_IP}
Port       : ${PUBLIC_PORT} (UDP, 本机监听 ${HY2_PORT})
SNI        : ${DOMAIN}
Service    : ${SERVICE}
Config     : ${CONFIG_PATH}
Cert       : ${TLS_CERT}
Egress     : ${EGRESS}
Password   : ${PASSWORD}

--- v2rayN / sing-box ---
${SHARE_URL}
EOF
chmod 600 "$INFO_FILE"

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}          Hysteria2 部署完成${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "Server   : ${YELLOW}${PUBLIC_IP}:${PUBLIC_PORT}${NC} UDP"
echo -e "SNI      : ${YELLOW}${DOMAIN}${NC}"
echo -e "出口     : ${YELLOW}${EGRESS}${NC}"
echo -e "单元     : ${YELLOW}${SERVICE}${NC}"
echo -e "信息文件 : ${YELLOW}${INFO_FILE}${NC}"
echo ""
echo -e "${CYAN}--- v2rayN 分享链接 ---${NC}"
echo -e "${YELLOW}${SHARE_URL}${NC}"
echo ""
