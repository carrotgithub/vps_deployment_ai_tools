#!/bin/bash

################################################################################
#
# VLESS + Reality + Vision 一键部署脚本 (xray-core)
#
# 设计原则:
#   - 混合模式: 默认非交互直接跑, 支持环境变量覆盖, INTERACTIVE=1 开交互确认
#   - 不需域名 / 不需证书, Reality 自身完成 TLS 伪装
#   - 两种部署方式:
#       standalone  xray 直接监听公网端口 (默认 443), 本机不能再有网站占用该端口
#       nginx       与 Nginx 上的网站共用 TCP 443。需先运行 0.nginx/tools/nginx_sni_split.sh enable,
#                   xray 只听本机端口, 由 Nginx 按 SNI 把伪装域名的连接转过来
#   - NAT 场景通过 PUBLIC_PORT 指定分享链接里的公网端口
#
# 环境变量:
#   MODE           standalone | nginx     (默认 standalone)
#   SNI_TARGET     伪装站 SNI             (默认 www.cisco.com)
#   DEST           回落目标               (默认 SNI_TARGET:443; nginx 模式下 SNI_TARGET 是本机站点时自动用 127.0.0.1:8443)
#   REALITY_PORT   xray 监听端口          (standalone 默认 443, nginx 默认 10443 且只听 127.0.0.1)
#   PUBLIC_IP      公网 IP                (默认自动探测)
#   PUBLIC_PORT    公网端口               (standalone 默认=REALITY_PORT, nginx 默认 443)
#   XRAY_VERSION   xray 版本              (默认 latest)
#   INTERACTIVE    1=交互确认            (默认 0)
#
# 用法示例:
#   bash install_reality.sh                                  # 普通 VPS (443 直通)
#   PUBLIC_PORT=57442 bash install_reality.sh                # NAT (分享链接端口)
#   MODE=nginx SNI_TARGET=www.cisco.com bash install_reality.sh   # 与网站共用 443
#   INTERACTIVE=1 SNI_TARGET=www.adobe.com bash install_reality.sh
#
################################################################################

set -e

# ==================== 默认配置 ====================
MODE="${MODE:-standalone}"
SNI_TARGET="${SNI_TARGET:-www.cisco.com}"
DEST="${DEST:-}"
DEST_XVER="${DEST_XVER:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
XRAY_VERSION="${XRAY_VERSION:-latest}"
INTERACTIVE="${INTERACTIVE:-0}"
if [ "$MODE" = "nginx" ]; then
    REALITY_PORT="${REALITY_PORT:-10443}"
    PUBLIC_PORT="${PUBLIC_PORT:-443}"
else
    REALITY_PORT="${REALITY_PORT:-443}"
    PUBLIC_PORT="${PUBLIC_PORT:-}"
fi

NGINX_PATH="${NGINX_PATH:-/usr/local/nginx}"
SNI_SPLIT_CONF="$NGINX_PATH/conf/stream.d/sni_split.conf"
SNI_MAP_FILE="$NGINX_PATH/conf/stream.d/sni_map/reality.map"
SPLIT_BACKEND="127.0.0.1:8443"

INSTALL_DIR="/usr/local/etc/xray"
BIN_PATH="/usr/local/bin/xray"
SERVICE_PATH="/etc/systemd/system/xray.service"
INFO_FILE="/root/reality.info.txt"
LOG_DIR="/var/log/xray"

# ==================== 颜色 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}>>> $*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}"; }
err()  { echo -e "${RED}✗ $*${NC}" >&2; }

# ==================== 前置检查 ====================
if [ "$EUID" -ne 0 ]; then
    err "必须使用 root 权限运行"
    exit 1
fi

# ==================== 交互确认 (可选) ====================
if [ "$INTERACTIVE" = "1" ]; then
    echo -e "${CYAN}====== 部署参数确认 ======${NC}"
    read -p "伪装站 SNI [默认: $SNI_TARGET]: " v && [ -n "$v" ] && SNI_TARGET="$v"
    read -p "监听端口 [默认: $REALITY_PORT]: " v && [ -n "$v" ] && REALITY_PORT="$v"
    read -p "公网端口 (NAT 才填, 默认=监听端口): " v && [ -n "$v" ] && PUBLIC_PORT="$v"
fi

# ==================== 部署方式 ====================
case "$MODE" in
    standalone)
        LISTEN_ADDR="0.0.0.0"
        SOCKOPT=""
        [ -z "$DEST" ] && DEST="$SNI_TARGET:443"
        ;;
    nginx)
        if [ ! -f "$SNI_SPLIT_CONF" ]; then
            err "未开启 Nginx 443 分流, 先运行 0.nginx/tools/nginx_sni_split.sh enable"
            exit 1
        fi
        LISTEN_ADDR="127.0.0.1"
        SOCKOPT='"sockopt": { "acceptProxyProtocol": true },'
        if [ -z "$DEST" ]; then
            SNI_RE="${SNI_TARGET//./\\.}"
            if grep -qsE "^[[:space:]]*server_name([[:space:]]+[^;]*)?[[:space:]]${SNI_RE}([[:space:]]|;)" \
                    "$NGINX_PATH"/conf/conf.d/*.conf; then
                DEST="$SPLIT_BACKEND"
            else
                DEST="$SNI_TARGET:443"
            fi
        fi
        if [ -z "$DEST_XVER" ] && [ "$DEST" = "$SPLIT_BACKEND" ]; then
            DEST_XVER=1
        fi
        HOLDER=$(ss -tlnpH "sport = :$REALITY_PORT" 2>/dev/null | grep -v xray || true)
        if [ -n "$HOLDER" ]; then
            err "本机端口 $REALITY_PORT 已被其他进程占用: $HOLDER"
            exit 1
        fi
        ;;
    *)
        err "MODE 只能是 standalone 或 nginx, 当前: $MODE"
        exit 1
        ;;
esac
DEST_XVER="${DEST_XVER:-0}"

# ==================== 1. 安装依赖 ====================
log "[1/6] 安装依赖 (curl / unzip / qrencode)"
if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip qrencode ca-certificates >/dev/null
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl unzip qrencode ca-certificates >/dev/null
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl unzip qrencode ca-certificates >/dev/null
else
    err "未识别的包管理器 (非 apt/yum/dnf)"
    exit 1
fi
ok "依赖安装完成"

# ==================== 2. 下载 xray-core ====================
log "[2/6] 下载 xray-core ($XRAY_VERSION)"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)  XRAY_ARCH="64" ;;
    aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
    armv7l)        XRAY_ARCH="arm32-v7a" ;;
    *) err "不支持的架构: $ARCH"; exit 1 ;;
esac

if [ "$XRAY_VERSION" = "latest" ]; then
    DL_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"
else
    DL_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
fi

TMP=$(mktemp -d)
cd "$TMP"

if ! curl -fsSL -o xray.zip "$DL_URL"; then
    warn "GitHub 直连失败, 尝试 ghproxy..."
    PROXY_URL="https://ghproxy.com/${DL_URL}"
    curl -fsSL -o xray.zip "$PROXY_URL" || { err "下载 xray 失败"; exit 1; }
fi

unzip -o -q xray.zip
install -m 755 xray "$BIN_PATH"
mkdir -p "$INSTALL_DIR" "$LOG_DIR"
cd - >/dev/null
rm -rf "$TMP"
ok "xray $($BIN_PATH version | head -1) 已安装到 $BIN_PATH"

# ==================== 3. 生成 Reality 参数 ====================
log "[3/6] 生成 Reality 密钥对与 UUID"

KEY_OUT=$("$BIN_PATH" x25519)
# 兼容新旧两种输出格式:
#   旧 (xray < 1.8):   "Private key: xxx" / "Public key: xxx"
#   新 (xray 26.x+):   "PrivateKey: xxx" / "Password (PublicKey): xxx"
PRIVATE_KEY=$(echo "$KEY_OUT" | grep -iE '^(Private ?[Kk]ey)' | head -1 | awk -F: '{print $2}' | tr -d '[:space:]')
PUBLIC_KEY=$(echo "$KEY_OUT"  | grep -iE 'Public ?[Kk]ey|Password'  | head -1 | awk -F: '{print $NF}' | tr -d '[:space:]')

UUID=$("$BIN_PATH" uuid)
SHORT_ID=$(head -c 8 /dev/urandom | xxd -p)

[ -z "$PRIVATE_KEY" ] && { err "x25519 生成失败"; exit 1; }

ok "UUID       = $UUID"
ok "PublicKey  = $PUBLIC_KEY"
ok "ShortId    = $SHORT_ID"

# ==================== 4. 写配置 ====================
log "[4/6] 写入 $INSTALL_DIR/config.json"

cat > "$INSTALL_DIR/config.json" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "$LOG_DIR/access.log",
    "error":  "$LOG_DIR/error.log"
  },
  "inbounds": [
    {
      "listen": "$LISTEN_ADDR",
      "port": $REALITY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        $SOCKOPT
        "realitySettings": {
          "show": false,
          "dest": "$DEST",
          "xver": $DEST_XVER,
          "serverNames": ["$SNI_TARGET"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom",   "tag": "direct" },
    { "protocol": "blackhole", "tag": "block"  }
  ]
}
EOF

if ! "$BIN_PATH" -test -config "$INSTALL_DIR/config.json" >/dev/null 2>&1; then
    err "config.json 校验失败"
    "$BIN_PATH" -test -config "$INSTALL_DIR/config.json"
    exit 1
fi
ok "配置校验通过"

# ==================== 5. systemd 服务 ====================
log "[5/6] 配置 systemd 服务"

cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Xray Service (VLESS + Reality)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$BIN_PATH run -config $INSTALL_DIR/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 1

if ! systemctl is-active --quiet xray; then
    err "xray 启动失败, 查看日志:"
    journalctl -u xray -n 30 --no-pager
    exit 1
fi
ok "xray 服务运行中 ($LISTEN_ADDR:$REALITY_PORT)"

if [ "$MODE" = "nginx" ]; then
    mkdir -p "$(dirname "$SNI_MAP_FILE")"
    echo "$SNI_TARGET 127.0.0.1:$REALITY_PORT;" > "$SNI_MAP_FILE"
    if "$NGINX_PATH/sbin/nginx" -t >/dev/null 2>&1; then
        systemctl reload nginx
        ok "Nginx 443 分流已登记: $SNI_TARGET -> 127.0.0.1:$REALITY_PORT"
    else
        rm -f "$SNI_MAP_FILE"
        err "登记分流后 nginx -t 失败, 已撤销登记:"
        "$NGINX_PATH/sbin/nginx" -t || true
        exit 1
    fi
fi

if [ "$DEST" = "$SNI_TARGET:443" ]; then
    log "检查伪装目标 $SNI_TARGET (需 TLS 1.3 + h2 + X25519)"
    timeout 20 "$BIN_PATH" tls ping "$SNI_TARGET" 2>&1 | head -30 || warn "xray tls ping 未完成"
fi

# ==================== 6. 生成订阅信息 ====================
log "[6/6] 生成客户端订阅信息"

if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
             || curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
             || echo "")
fi
[ -z "$PUBLIC_IP" ] && { warn "公网 IP 探测失败, 请手动替换 URL 中的 <IP>"; PUBLIC_IP="<IP>"; }

[ -z "$PUBLIC_PORT" ] && PUBLIC_PORT="$REALITY_PORT"

TAG="Reality-$(echo "$PUBLIC_IP" | tr '.' '-')"

VLESS_URL="vless://${UUID}@${PUBLIC_IP}:${PUBLIC_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI_TARGET}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${TAG}"

SINGBOX_JSON=$(cat <<EOF
{
  "type": "vless",
  "tag": "$TAG",
  "server": "$PUBLIC_IP",
  "server_port": $PUBLIC_PORT,
  "uuid": "$UUID",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "$SNI_TARGET",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": {
      "enabled": true,
      "public_key": "$PUBLIC_KEY",
      "short_id": "$SHORT_ID"
    }
  }
}
EOF
)

CLASH_YAML=$(cat <<EOF
proxies:
  - name: "$TAG"
    type: vless
    server: $PUBLIC_IP
    port: $PUBLIC_PORT
    uuid: $UUID
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: $SNI_TARGET
    client-fingerprint: chrome
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
EOF
)

# 保存信息
cat > "$INFO_FILE" <<EOF
===== VLESS + Reality 部署信息 =====
生成时间: $(date '+%Y-%m-%d %H:%M:%S')

--- 基本参数 ---
Mode         : $MODE
Server       : $PUBLIC_IP
Port (公网)  : $PUBLIC_PORT
Port (监听)  : $LISTEN_ADDR:$REALITY_PORT
Dest         : $DEST (xver $DEST_XVER)
UUID         : $UUID
Flow         : xtls-rprx-vision
SNI          : $SNI_TARGET
Fingerprint  : chrome
PublicKey    : $PUBLIC_KEY
PrivateKey   : $PRIVATE_KEY   (请勿泄露)
ShortId      : $SHORT_ID

--- VLESS URL (xray / v2rayN / NekoBox / Shadowrocket) ---
$VLESS_URL

--- sing-box outbound ---
$SINGBOX_JSON

--- Clash Meta / mihomo ---
$CLASH_YAML
EOF
chmod 600 "$INFO_FILE"

# 输出
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}          VLESS + Reality 部署完成${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "Server      : ${YELLOW}$PUBLIC_IP:$PUBLIC_PORT${NC}"
echo -e "SNI 伪装站  : ${YELLOW}$SNI_TARGET${NC}"
echo -e "UUID        : ${YELLOW}$UUID${NC}"
echo -e "PublicKey   : ${YELLOW}$PUBLIC_KEY${NC}"
echo -e "ShortId     : ${YELLOW}$SHORT_ID${NC}"
echo -e "信息文件    : ${YELLOW}$INFO_FILE${NC}  (含完整配置)"
echo ""
echo -e "${CYAN}--- VLESS URL ---${NC}"
echo -e "${YELLOW}$VLESS_URL${NC}"
echo ""

if command -v qrencode >/dev/null 2>&1; then
    echo -e "${CYAN}--- 二维码 ---${NC}"
    qrencode -t ANSIUTF8 "$VLESS_URL"
    qrencode -o /root/reality_qr.png "$VLESS_URL" 2>/dev/null && \
        echo -e "二维码 PNG: ${YELLOW}/root/reality_qr.png${NC}"
fi

echo ""
echo -e "${GREEN}服务状态:${NC}"
systemctl status xray --no-pager -l | head -10
