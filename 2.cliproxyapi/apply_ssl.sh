#!/bin/bash
################################################################################
#
# 通用 SSL 工具 v2.2（灰云 HTTP-01）
#
# 职责：Let's Encrypt ECC-256 签发 / 续签 + 保证 Nginx 80 端口 HTTP-01 通道。
# 默认不覆盖已有 443 业务配置。黄云（Cloudflare 橙云）拒绝办理，请走 DNS-01。
#
# 用法：
#   ./apply_ssl.sh -d example.com
#   ./apply_ssl.sh -d example.com --force
#   ./apply_ssl.sh -d example.com --write-nginx -s mysvc -p 8317
#
################################################################################

set -euo pipefail

NGINX_PATH="/usr/local/nginx"
CONF_D="$NGINX_PATH/conf/conf.d"
SSL_DIR="$NGINX_PATH/conf/ssl"
WEBROOT="/var/www/acme"
ACME_SH="${HOME}/.acme.sh/acme.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

DOMAIN=""
SERVICE=""
PORT=""
FORCE=0
WRITE_NGINX=0
FORCE_EDIT=0
NONINTERACTIVE=0

log_info()    { echo -e "${CYAN}>>>${NC} $1"; }
log_ok()      { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_err()     { echo -e "${RED}✗${NC} $1" >&2; }

show_help() {
    cat <<EOF
${CYAN}通用 SSL 工具 v2.2（灰云 HTTP-01）${NC}

${GREEN}用法:${NC}
  $0 -d <域名> [--force] [--write-nginx -s <服务> [-p <端口>]]

${GREEN}参数:${NC}
  -d DOMAIN        域名（必填；带此参数时不再交互询问）
  -s SERVICE       仅配合 --write-nginx：服务名（日志文件名）
  -p PORT          仅配合 --write-nginx：反代到 127.0.0.1:PORT
  --force          强制用 Let's Encrypt 重新签发
  --write-nginx    证书安装后生成 80+443 模板；已有 443 配置则拒绝覆盖
  --force-edit     允许修改带 "vps-relay managed" 标记的 conf
  -y               非交互（有 -d 时默认已是非交互）
  -h               帮助

${GREEN}默认行为:${NC}
  锁 Let's Encrypt → 给 listen 80 补 HTTP-01 location → issue/renew
  → install-cert 到 ${SSL_DIR}/<domain>/ → reload nginx
  已有 443 业务配置不会被覆盖。

${GREEN}不支持:${NC}
  Cloudflare 橙云 / 通配符证书（请用 dns_cf）
EOF
}

die() { log_err "$1"; exit 1; }

apex_email() {
    local d="$1"
    local n
    n=$(awk -F. '{print NF}' <<<"$d")
    if [ "$n" -le 2 ]; then
        echo "admin@$d"
    else
        echo "admin@$(awk -F. '{print $(NF-1)"."$NF}' <<<"$d")"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d) DOMAIN="${2:-}"; shift 2 ;;
        -s) SERVICE="${2:-}"; shift 2 ;;
        -p) PORT="${2:-}"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        -y) NONINTERACTIVE=1; shift ;;
        --force) FORCE=1; shift ;;
        --write-nginx) WRITE_NGINX=1; shift ;;
        --force-edit) FORCE_EDIT=1; shift ;;
        *) die "未知参数: $1" ;;
    esac
done

[ "$EUID" -eq 0 ] || die "必须以 root 运行"
[ -d "$NGINX_PATH" ] || die "未找到 $NGINX_PATH（需要编译安装的 Nginx）"
command -v python3 >/dev/null || die "需要 python3（用于安全改 Nginx conf）"
command -v openssl >/dev/null || die "需要 openssl"
command -v curl >/dev/null || die "需要 curl"

if [ -z "$DOMAIN" ]; then
    read -r -p "请输入域名: " DOMAIN
fi
[ -n "$DOMAIN" ] || die "域名不能为空"
if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    die "域名格式不正确: $DOMAIN"
fi
NONINTERACTIVE=1

if [ "$WRITE_NGINX" -eq 1 ] && [ -z "$SERVICE" ]; then
    die "--write-nginx 需要同时指定 -s <服务名>"
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}   通用 SSL 工具 v2.2${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

EMAIL="$(apex_email "$DOMAIN")"
DOMAIN_SSL_DIR="$SSL_DIR/$DOMAIN"
mkdir -p "$DOMAIN_SSL_DIR" "$WEBROOT"
chmod 755 "$WEBROOT"

nginx_running() {
    if command -v systemctl >/dev/null && systemctl is-active --quiet nginx; then
        return 0
    fi
    pgrep -f 'nginx: master process' >/dev/null 2>&1
}

nginx_reload() {
    if command -v systemctl >/dev/null && systemctl is-active --quiet nginx; then
        systemctl reload nginx
        return $?
    fi
    "$NGINX_PATH/sbin/nginx" -s reload
}

if nginx_running; then
    if command -v systemctl >/dev/null && systemctl is-active --quiet nginx; then
        RELOAD_CMD="systemctl reload nginx"
    else
        RELOAD_CMD="$NGINX_PATH/sbin/nginx -s reload"
        log_warn "systemd 中 nginx 未 active，改用进程 reload: $RELOAD_CMD"
    fi
else
    die "Nginx 未运行"
fi

# ---------- DNS / 黄云 ----------
log_info "[1/6] 检查 DNS（灰云要求 A 记录 = 本机公网 IP）"

SERVER_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
if [ -z "$SERVER_IP" ]; then
    SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi
[ -n "$SERVER_IP" ] || die "无法获取本机公网 IP"

RESOLVED_IP="$(python3 - "$DOMAIN" <<'PY'
import socket, sys
d = sys.argv[1]
try:
    infos = socket.getaddrinfo(d, None, socket.AF_INET, socket.SOCK_STREAM)
    ips = []
    for item in infos:
        ip = item[4][0]
        if ip not in ips:
            ips.append(ip)
    print(ips[0] if ips else "")
except Exception:
    print("")
PY
)"

LOCAL_IPS="$(ip -4 addr show | awk '/inet /{print $2}' | cut -d/ -f1 | tr '\n' ' ')"
echo "  域名:       $DOMAIN"
echo "  探测公网IP: ${SERVER_IP:-<ipify失败>}"
echo "  本机地址:   $LOCAL_IPS"
echo "  域名解析:   ${RESOLVED_IP:-<无法解析>}"

[ -n "$RESOLVED_IP" ] || die "域名无法解析，灰云 HTTP-01 不能签发"

IS_CF="$(python3 - "$RESOLVED_IP" <<'PY'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
cidrs = [
    "173.245.48.0/20","103.21.244.0/22","103.22.200.0/22","103.31.4.0/22",
    "141.101.64.0/18","108.162.192.0/18","190.93.240.0/20","188.114.96.0/20",
    "197.234.240.0/22","198.41.128.0/17","162.158.0.0/15","104.16.0.0/13",
    "104.24.0.0/14","172.64.0.0/13","131.0.72.0/22",
]
print("yes" if any(ip in ipaddress.ip_network(c) for c in cidrs) else "no")
PY
)"

if [ "$IS_CF" = "yes" ]; then
    die "解析落到 Cloudflare 任播（$RESOLVED_IP），判定为橙云。本脚本只做灰云 HTTP-01，请用 dns_cf。"
fi
DNS_OK=0
[ -n "$SERVER_IP" ] && [ "$RESOLVED_IP" = "$SERVER_IP" ] && DNS_OK=1
echo " $LOCAL_IPS " | grep -q " $RESOLVED_IP " && DNS_OK=1
if [ "$DNS_OK" -eq 1 ]; then
    log_ok "DNS 灰云直连本机"
else
    log_warn "A 记录 $RESOLVED_IP 不在本机网卡上（常见于 1:1 NAT / EIP），非橙云，继续 HTTP-01"
fi

# ---------- acme.sh ----------
log_info "[2/6] 准备 acme.sh（默认 CA = Let's Encrypt）"
if [ ! -x "$ACME_SH" ]; then
    curl -fsSL https://get.acme.sh | sh -s email="$EMAIL" || die "安装 acme.sh 失败"
    ACME_SH="${HOME}/.acme.sh/acme.sh"
fi
[ -x "$ACME_SH" ] || die "acme.sh 不存在"
"$ACME_SH" --set-default-ca --server letsencrypt >/dev/null
log_ok "acme.sh 就绪，账户邮箱 $EMAIL"

# ---------- HTTP-01 nginx ----------
log_info "[3/6] 确保 Nginx 80 端口 HTTP-01 通道"

find_conf_for_domain() {
    local d="$1" f
    [ -f "$CONF_D/${d}.conf" ] && { echo "$CONF_D/${d}.conf"; return 0; }
    shopt -s nullglob
    for f in "$CONF_D"/*.conf; do
        if grep -qE "server_name[[:space:]].*[[:space:]]${d}(;|[[:space:]])" "$f" \
            || grep -qE "server_name[[:space:]]+${d};" "$f"; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

NGINX_CONF=""
if NGINX_CONF="$(find_conf_for_domain "$DOMAIN")"; then
    echo "  命中 conf: $NGINX_CONF"
    if grep -q "vps-relay managed" "$NGINX_CONF" && [ "$FORCE_EDIT" -eq 0 ]; then
        die "该 conf 由 vps-relay 管理，默认不改。确认后加 --force-edit。"
    fi
else
    NGINX_CONF="$CONF_D/${DOMAIN}.conf"
    echo "  无现有 conf，将写最小 80 端口文件: $NGINX_CONF"
fi

if [ "$WRITE_NGINX" -eq 1 ] && [ -f "$NGINX_CONF" ] && grep -q "listen" "$NGINX_CONF" 2>/dev/null; then
    if grep -qE "listen[[:space:]]+443|https_listen(_default)?\.conf" "$NGINX_CONF"; then
        die "--write-nginx 拒绝覆盖已有 443 配置: $NGINX_CONF"
    fi
fi

BACKUP=""
if [ -f "$NGINX_CONF" ]; then
    BACKUP="${NGINX_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$NGINX_CONF" "$BACKUP"
fi

PATCH_STATUS="$(python3 - "$NGINX_CONF" "$DOMAIN" "$WEBROOT" <<'PY'
import re, sys, os
path, domain, webroot = sys.argv[1], sys.argv[2], sys.argv[3]
ACME_LOC = (
    "    location /.well-known/acme-challenge/ {\n"
    f"        root {webroot};\n"
    "    }\n"
)
ACME_SERVER = (
    "server {\n"
    "    listen 80;\n"
    f"    server_name {domain};\n"
    + ACME_LOC +
    "    location / {\n"
    "        return 301 https://$host$request_uri;\n"
    "    }\n"
    "}\n"
)

def extract_servers(text):
    out = []
    i, n = 0, len(text)
    while True:
        m = re.search(r'server\s*\{', text[i:])
        if not m:
            break
        start = i + m.start()
        brace = i + m.end() - 1
        depth = 0
        j = brace
        while j < n:
            if text[j] == '{':
                depth += 1
            elif text[j] == '}':
                depth -= 1
                if depth == 0:
                    out.append((start, j + 1, text[start:j + 1]))
                    i = j + 1
                    break
            j += 1
        else:
            break
    return out

def names_of(block):
    names = []
    for m in re.finditer(r'server_name\s+([^;]+);', block):
        names.extend(m.group(1).split())
    return names

def listen_80(block):
    return re.search(r'listen\s+(?:\[[^\]]+\]:)?80\b', block) is not None

def has_acme(block):
    return 'acme-challenge' in block

def patch_block(block):
    if has_acme(block):
        return block, False
    m = re.search(r'^([ \t]*)return\s+301\s+https://\$host\$request_uri;\s*$', block, re.M)
    if m:
        indent = m.group(1)
        repl = (
            f"{indent}location /.well-known/acme-challenge/ {{\n"
            f"{indent}    root {webroot};\n"
            f"{indent}}}\n"
            f"{indent}location / {{\n"
            f"{indent}    return 301 https://$host$request_uri;\n"
            f"{indent}}}\n"
        )
        return block[:m.start()] + repl + block[m.end():], True
    m = re.search(r'^([ \t]*)location\s+/\s*\{', block, re.M)
    if m:
        return block[:m.start()] + ACME_LOC + block[m.start():], True
    m = re.search(r'server_name\s+[^;]+;\n', block)
    if m:
        return block[:m.end()] + ACME_LOC + block[m.end():], True
    return block, False

if not os.path.isfile(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(ACME_SERVER)
    print('CREATED')
    sys.exit(0)

text = open(path, encoding='utf-8', errors='replace').read()
servers = extract_servers(text)
matched_80 = []
matched_any = False
for start, end, block in servers:
    if domain not in names_of(block):
        continue
    matched_any = True
    if listen_80(block):
        matched_80.append((start, end, block))

if matched_80:
    # patch last matching 80 block (usually the dedicated http server)
    start, end, block = matched_80[-1]
    new_block, changed = patch_block(block)
    if not changed:
        print('UNCHANGED')
        sys.exit(0)
    text = text[:start] + new_block + text[end:]
    open(path, 'w', encoding='utf-8').write(text)
    print('PATCHED')
    sys.exit(0)

# domain exists only on 443: append a dedicated 80 server
if matched_any:
    if not text.endswith('\n'):
        text += '\n'
    text += '\n' + ACME_SERVER
    open(path, 'w', encoding='utf-8').write(text)
    print('APPENDED80')
    sys.exit(0)

if not text.endswith('\n'):
    text += '\n'
text += '\n' + ACME_SERVER
open(path, 'w', encoding='utf-8').write(text)
print('APPENDED80')
PY
)"

echo "  HTTP-01 处理: $PATCH_STATUS"

if ! "$NGINX_PATH/sbin/nginx" -t >/tmp/apply_ssl_nginx_t.out 2>&1; then
    log_err "nginx -t 失败，回滚"
    cat /tmp/apply_ssl_nginx_t.out >&2
    if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
        mv -f "$BACKUP" "$NGINX_CONF"
        "$NGINX_PATH/sbin/nginx" -t >/dev/null 2>&1 && nginx_reload || true
    fi
    die "Nginx 配置测试失败"
fi
nginx_reload
log_ok "Nginx HTTP-01 已就绪（$PATCH_STATUS）"

# 探测：不得 301（reload 后 worker 可能有短暂旧配置，重试几次）
PROBE_CODE=""
i=0
while [ "$i" -lt 8 ]; do
    PROBE_CODE="$(curl -sI -o /tmp/apply_ssl_probe.hdr -w '%{http_code}' --max-time 8 \
        -H "Host: $DOMAIN" "http://127.0.0.1/.well-known/acme-challenge/apply-ssl-probe" || true)"
    case "$PROBE_CODE" in
        301|302|000) sleep 0.4; i=$((i + 1)); continue ;;
        *) break ;;
    esac
done
if [ "$PROBE_CODE" = "301" ] || [ "$PROBE_CODE" = "302" ]; then
    die "HTTP-01 仍被重定向到 HTTPS（HTTP $PROBE_CODE）。请检查 $NGINX_CONF"
fi
log_ok "本机 HTTP-01 探测 HTTP $PROBE_CODE（404/200 均可，不能是 301）"

CERT_FULLCHAIN="$DOMAIN_SSL_DIR/fullchain.pem"
CERT_KEY="$DOMAIN_SSL_DIR/key.pem"
if [ -f "$NGINX_CONF" ]; then
    _cf="$(grep -E 'ssl_certificate ' "$NGINX_CONF" | grep -v ssl_certificate_key | awk '{print $2}' | tr -d ';' | head -1 || true)"
    _ck="$(grep -E 'ssl_certificate_key ' "$NGINX_CONF" | awk '{print $2}' | tr -d ';' | head -1 || true)"
    [ -n "$_cf" ] && CERT_FULLCHAIN="$_cf"
    [ -n "$_ck" ] && CERT_KEY="$_ck"
fi
mkdir -p "$(dirname "$CERT_FULLCHAIN")" "$(dirname "$CERT_KEY")"
echo "  证书安装路径: $CERT_FULLCHAIN"

# ---------- 是否需要签发 ----------
log_info "[4/6] 签发 / 续签 Let's Encrypt ECC-256"

need_issue() {
    local pem="$CERT_FULLCHAIN"
    [ "$FORCE" -eq 1 ] && return 0
    [ -f "$pem" ] || return 0
    openssl x509 -in "$pem" -noout -checkend 2592000 >/dev/null 2>&1 || return 0
    openssl x509 -in "$pem" -noout -issuer 2>/dev/null | grep -qi "Let's Encrypt" || return 0
    return 1
}

if need_issue; then
    log_info "向 Let's Encrypt 申请证书（--force=$FORCE）"
    if ! "$ACME_SH" --issue --server letsencrypt -d "$DOMAIN" \
            --webroot "$WEBROOT" --keylength ec-256 --force; then
        die "Let's Encrypt 签发失败（不会降级自签名）"
    fi
    log_ok "Let's Encrypt 签发成功"
else
    log_ok "现有证书仍是 Let's Encrypt 且 30 天内不过期，跳过签发"
fi

# ---------- install-cert ----------
log_info "[5/6] 安装证书并注册 reloadcmd"
if ! "$ACME_SH" --install-cert -d "$DOMAIN" --ecc \
        --key-file       "$CERT_KEY" \
        --fullchain-file "$CERT_FULLCHAIN" \
        --reloadcmd      "$RELOAD_CMD"; then
    die "install-cert 失败"
fi
nginx_reload
log_ok "证书已安装到 $DOMAIN_SSL_DIR"

# ---------- --write-nginx（仅空站；443 引用的证书此时已存在） ----------
if [ "$WRITE_NGINX" -eq 1 ]; then
    log_info "写入新站 Nginx 模板（--write-nginx）"
    FINAL_CONF="$CONF_D/${DOMAIN}.conf"
    TPL_BACKUP=""
    if [ -f "$FINAL_CONF" ]; then
        TPL_BACKUP="${FINAL_CONF}.pre-write.$(date +%Y%m%d%H%M%S)"
        cp -a "$FINAL_CONF" "$TPL_BACKUP"
    fi
    if [ -n "$PORT" ]; then
        cat > "$FINAL_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root $WEBROOT;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

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
        proxy_read_timeout 3600s;
    }
}
EOF
    else
        cat > "$FINAL_CONF" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root $WEBROOT;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

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

    root /var/www/static;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    fi
    HTTPS_LISTEN_SNIPPET="$NGINX_PATH/conf/snippets/https_listen.conf"
    if [ -f "$HTTPS_LISTEN_SNIPPET" ]; then
        sed -i -E "s|^([[:space:]]*)listen 443 ssl;|\1include $HTTPS_LISTEN_SNIPPET;|" "$FINAL_CONF"
    fi
    if ! "$NGINX_PATH/sbin/nginx" -t >/tmp/apply_ssl_nginx_t.out 2>&1; then
        log_err "nginx -t 失败，恢复写模板前的配置"
        cat /tmp/apply_ssl_nginx_t.out >&2
        if [ -n "$TPL_BACKUP" ]; then
            mv -f "$TPL_BACKUP" "$FINAL_CONF"
        else
            rm -f "$FINAL_CONF"
        fi
        "$NGINX_PATH/sbin/nginx" -t >/dev/null 2>&1 && nginx_reload || true
        die "--write-nginx 模板未通过 nginx -t"
    fi
    [ -n "$TPL_BACKUP" ] && rm -f "$TPL_BACKUP"
    nginx_reload
    log_ok "已写入 $FINAL_CONF"
fi

# ---------- 验收 ----------
log_info "[6/6] 验收"
PEM="$CERT_FULLCHAIN"
[ -f "$PEM" ] || die "找不到 $PEM"
ISSUER="$(openssl x509 -in "$PEM" -noout -issuer)"
DATES="$(openssl x509 -in "$PEM" -noout -dates)"
SUBJECT="$(openssl x509 -in "$PEM" -noout -subject)"
echo "  $SUBJECT"
echo "  $ISSUER"
echo "  $DATES"
echo "$ISSUER" | grep -qi "Let's Encrypt" || die "签发机构不是 Let's Encrypt: $ISSUER"
openssl x509 -in "$PEM" -noout -checkend 86400 >/dev/null || die "证书 24 小时内过期或已过期"

CRON_LINE="$(crontab -l 2>/dev/null | grep acme.sh || true)"
if [ -z "$CRON_LINE" ]; then
    "$ACME_SH" --install-cronjob >/dev/null || true
    CRON_LINE="$(crontab -l 2>/dev/null | grep acme.sh || true)"
fi
[ -n "$CRON_LINE" ] || die "acme.sh cron 未安装"
log_ok "cron: $CRON_LINE"

LIVE_CODE="$(curl -skI -o /dev/null -w '%{http_code}' --max-time 10 \
    --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" || true)"
echo "  本机 HTTPS ($DOMAIN → 127.0.0.1) HTTP $LIVE_CODE"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}   SSL 完成${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "域名:     ${CYAN}$DOMAIN${NC}"
echo -e "CA:       ${CYAN}Let's Encrypt ECC-256${NC}"
echo -e "证书:     ${CYAN}$PEM${NC}"
echo -e "Nginx:    ${CYAN}${NGINX_CONF}${NC}  ($PATCH_STATUS)"
echo -e "续期:     acme.sh cron + HTTP-01 @ $WEBROOT"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
