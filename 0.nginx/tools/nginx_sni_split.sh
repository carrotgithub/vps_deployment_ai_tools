#!/bin/bash

################################################################################
#
# Nginx TCP 443 按 SNI 分流 (stream + ssl_preread)
#
# 用途:
#   让 Reality 这类必须直接拿到 TLS 流量的服务, 与 Nginx 上的多个 HTTPS 网站共用 TCP 443。
#   开启后公网 TCP 443 由 Nginx stream 接收, 只读 SNI 不解密:
#     - stream.d/sni_map/*.map 里登记的域名 -> 对应本机端口 (例如 Reality)
#     - 其他域名                           -> 127.0.0.1:8443 上的网站
#   两层之间用 PROXY protocol 传客户端 IP, 网站日志和后端看到的仍是真实 IP。
#   UDP 443 (HTTP/3 / Hysteria2) 不经过这里。
#
# 用法:
#   bash nginx_sni_split.sh plan      # 只在临时副本上预演迁移, 打印差异和 nginx -t 结果, 不改真实配置
#   bash nginx_sni_split.sh enable    # 开启分流, 迁移 conf.d 里的 443 站点 (可重复执行, 会迁移新加的站点)
#   bash nginx_sni_split.sh disable   # 网站回到直接监听 443, 移除分流
#   bash nginx_sni_split.sh status
#
# 环境变量:
#   NGINX_PATH      Nginx 安装根      (默认 /usr/local/nginx)
#   BACKEND_PORT    网站本机端口      (默认 8443)
#   STREAM_TIMEOUT  分流层空闲超时    (默认 3600s, 不能小于站点里最长的 proxy_read_timeout)
#
# 对 conf.d/*.conf 的迁移:
#   listen 443 ssl [http2] [default_server];  -> include snippets/https_listen(_default).conf;
#   listen [::]:443 ssl ...;                  -> 删除, 由片段统一监听
#   if ($server_port != 443)                  -> if ($scheme = http)
#   443 站点里自带的 real_ip_header           -> 注释掉, 统一从 proxy_protocol 取真实 IP
#   listen 443 quic                           -> 不动
#
# 每次变更前把整个 conf 目录备份到 /root/nginx-backup/。nginx -t 或重启失败自动回滚。
#
################################################################################

set -euo pipefail

NGINX_PATH="${NGINX_PATH:-/usr/local/nginx}"
BACKEND_PORT="${BACKEND_PORT:-8443}"
STREAM_TIMEOUT="${STREAM_TIMEOUT:-3600s}"
ACTION="${1:-status}"

NGINX_BIN="$NGINX_PATH/sbin/nginx"
BACKUP_DIR="/root/nginx-backup"

set_paths() {
    CONF="$1"
    CONF_D="$CONF/conf.d"
    SNIPPET_DIR="$CONF/snippets"
    STREAM_DIR="$CONF/stream.d"
    MAP_DIR="$STREAM_DIR/sni_map"
    LISTEN_SNIPPET="$SNIPPET_DIR/https_listen.conf"
    LISTEN_DEFAULT_SNIPPET="$SNIPPET_DIR/https_listen_default.conf"
    IPV6_MARK="$SNIPPET_DIR/.https_listen_ipv6"
    SPLIT_CONF="$STREAM_DIR/sni_split.conf"
}
set_paths "$NGINX_PATH/conf"
BACKUP_FILE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}>>> $*${NC}"; }
ok()   { echo -e "${GREEN}[ok] $*${NC}"; }
warn() { echo -e "${YELLOW}[!] $*${NC}"; }
err()  { echo -e "${RED}[x] $*${NC}" >&2; }
die()  { err "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "必须使用 root 权限运行"
[ -x "$NGINX_BIN" ] || die "未找到 $NGINX_BIN"
[[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || die "BACKEND_PORT 不是数字: $BACKEND_PORT"

backup_conf() {
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/conf-$(date +%Y%m%d%H%M%S).tar.gz"
    tar czf "$BACKUP_FILE" -C "$NGINX_PATH" conf
    ok "已备份 $CONF -> $BACKUP_FILE"
}

# $1=1 表示 nginx 已经按新配置重启过, 回滚后需要再重启
rollback() {
    local restarted=$1
    warn "回滚到 $BACKUP_FILE"
    rm -rf "$CONF.rollback"
    mv "$CONF" "$CONF.rollback"
    if tar xzf "$BACKUP_FILE" -C "$NGINX_PATH"; then
        rm -rf "$CONF.rollback"
    else
        rm -rf "$CONF"
        mv "$CONF.rollback" "$CONF"
        err "解包备份失败, 已保留回滚前的配置"
    fi
    if [ "$restarted" = "1" ]; then
        systemctl restart nginx || err "回滚后 nginx 仍无法启动, 请人工处理"
    fi
}

write_snippets() {
    local mode=$1 v6=0
    [ -f "$IPV6_MARK" ] && v6=1
    mkdir -p "$SNIPPET_DIR"
    local f extra
    for f in "$LISTEN_SNIPPET" "$LISTEN_DEFAULT_SNIPPET"; do
        extra=""
        [ "$f" = "$LISTEN_DEFAULT_SNIPPET" ] && extra=" default_server"
        {
            echo "# 由 0.nginx/tools/nginx_sni_split.sh 维护, 模式: $mode"
            if [ "$mode" = "split" ]; then
                echo "listen 127.0.0.1:${BACKEND_PORT} ssl proxy_protocol${extra};"
                echo "set_real_ip_from 127.0.0.1;"
                echo "real_ip_header proxy_protocol;"
                echo "port_in_redirect off;"
            else
                echo "listen 443 ssl${extra};"
                if [ "$v6" = "1" ]; then
                    echo "listen [::]:443 ssl${extra};"
                fi
            fi
        } > "$f"
    done
}

write_split_conf() {
    mkdir -p "$MAP_DIR"
    {
        echo "# 由 0.nginx/tools/nginx_sni_split.sh 维护。按 SNI 分流, 登记表见 sni_map/*.map"
        echo "map \$ssl_preread_server_name \$sni_split_backend {"
        echo "    include ${MAP_DIR}/*.map;"
        echo "    default 127.0.0.1:${BACKEND_PORT};"
        echo "}"
        echo ""
        echo "server {"
        echo "    listen 443;"
        if [ -f "$IPV6_MARK" ]; then
            echo "    listen [::]:443;"
        fi
        echo "    ssl_preread on;"
        echo "    proxy_pass \$sni_split_backend;"
        echo "    proxy_protocol on;"
        echo "    proxy_connect_timeout 5s;"
        echo "    proxy_timeout ${STREAM_TIMEOUT};"
        echo "}"
    } > "$SPLIT_CONF"
}

ensure_stream_block() {
    local main="$CONF/nginx.conf"
    if grep -qE '^[[:space:]]*stream[[:space:]]*\{' "$main"; then
        grep -qF "$STREAM_DIR/*.conf" "$main" \
            || die "nginx.conf 已有 stream 块但没有 include $STREAM_DIR/*.conf, 请手动合并"
    else
        printf '\nstream {\n    include %s/*.conf;\n}\n' "$STREAM_DIR" >> "$main"
        ok "nginx.conf 已追加 stream 块"
    fi
}

check_outside_conf_d() {
    local hits
    hits=$(grep -RnE '^[[:space:]]*listen[[:space:]]+([^[:space:];]*:)?443([[:space:]]|;)' "$CONF" \
            --include='*.conf' 2>/dev/null \
        | grep -v -E "^($CONF_D|$SNIPPET_DIR|$STREAM_DIR)/" \
        | grep -v -E '[[:space:]]quic' || true)
    if [ -n "$hits" ]; then
        err "conf.d 之外还有监听 443 的配置, 需要先手动迁走:"
        printf '%s\n' "$hits" >&2
        exit 1
    fi
}

# 输出: CHANGED <file> / WARN <msg> / ERROR <msg> / IPV6
migrate_sites() {
    python3 - "$CONF_D" "$LISTEN_SNIPPET" "$LISTEN_DEFAULT_SNIPPET" <<'PY'
import glob
import os
import re
import sys

conf_d, snippet, snippet_default = sys.argv[1:4]
LISTEN = re.compile(r'^(\s*)listen\s+(\S+)((?:\s+[^;#\s]+)*)\s*;\s*(#.*)?$')
SERVER_OPEN = re.compile(r'^\s*server\s*\{')
REALIP = re.compile(r'^(\s*)real_ip_header\s+(\S+)\s*;')
PORT_IF = re.compile(r'if\s*\(\s*\$server_port\s*!=\s*443\s*\)')
HTTP2_ON = re.compile(r'^\s*http2\s+on\s*;')
SNIPPET_INC = re.compile(r'^\s*include\s+\S*https_listen(_default)?\.conf\s*;')

errors, warnings, pending = [], [], []
ipv6 = False


def split_addr(addr):
    if addr.isdigit():
        return addr, ''
    host, _, port = addr.rpartition(':')
    return port, host


for path in sorted(glob.glob(os.path.join(conf_d, '*.conf'))):
    lines = open(path, encoding='utf-8', errors='replace').read().split('\n')

    blocks, depth, start = [], 0, None
    for i, line in enumerate(lines):
        code = line.split('#', 1)[0]
        if depth == 0 and SERVER_OPEN.match(code):
            start = i
        depth += code.count('{') - code.count('}')
        if start is not None and depth == 0:
            blocks.append((start, i))
            start = None

    repl = {}
    for s, e in blocks:
        rng = range(s, e + 1)
        is_https = any(SNIPPET_INC.match(lines[i]) for i in rng)
        has_http2_on = any(HTTP2_ON.match(lines[i]) for i in rng)
        for i in rng:
            raw = lines[i]
            if raw.lstrip().startswith('#'):
                continue
            m = LISTEN.match(raw)
            if not m:
                continue
            indent, addr, params = m.group(1), m.group(2), m.group(3).split()
            port, host = split_addr(addr)
            if port != '443' or 'quic' in params:
                continue
            if 'ssl' not in params:
                errors.append(f'{path}:{i + 1}: 443 监听没有 ssl, 无法自动迁移: {raw.strip()}')
                continue
            unknown = sorted(set(params) - {'ssl', 'http2', 'default_server'})
            if unknown:
                errors.append(f'{path}:{i + 1}: 不支持自动迁移的参数 {unknown}: {raw.strip()}')
                continue
            is_https = True
            if host.startswith('['):
                ipv6 = True
                repl[i] = []
                continue
            if host not in ('', '0.0.0.0', '*'):
                errors.append(f'{path}:{i + 1}: 绑定了具体地址, 请手动处理: {raw.strip()}')
                continue
            new = [f'{indent}include {snippet_default if "default_server" in params else snippet};']
            if 'http2' in params and not has_http2_on:
                new.append(f'{indent}http2 on;')
                has_http2_on = True
            repl[i] = new
        if not is_https:
            continue
        for i in rng:
            if i in repl:
                continue
            raw = lines[i]
            if raw.lstrip().startswith('#'):
                continue
            if PORT_IF.search(raw):
                repl[i] = [PORT_IF.sub('if ($scheme = http)', raw)]
                continue
            m = REALIP.match(raw)
            if m and m.group(2) != 'proxy_protocol':
                repl[i] = [f'{m.group(1)}# {raw.strip()}  # sni_split: 改由 https_listen.conf 从 proxy_protocol 取真实 IP']
                continue
            if re.match(r'^\s*port_in_redirect\s', raw):
                errors.append(f'{path}:{i + 1}: 已自带 port_in_redirect, 与片段冲突, 请删掉后重跑')
            if '$server_port' in raw:
                warnings.append(f'{path}:{i + 1}: 仍引用 $server_port, 分流后它的值是本机端口: {raw.strip()}')

    if repl:
        out = []
        for i, line in enumerate(lines):
            out.extend(repl[i] if i in repl else [line])
        pending.append((path, '\n'.join(out)))

for w in warnings:
    print('WARN ' + w)
if errors:
    for e in errors:
        print('ERROR ' + e)
    sys.exit(2)
for path, text in pending:
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)
    print('CHANGED ' + path)
if ipv6:
    print('IPV6')
PY
}

self_test() {
    local f name code
    for f in "$CONF_D"/*.conf; do
        grep -qE 'https_listen(_default)?\.conf' "$f" || continue
        name=$(grep -m1 -oE '^[[:space:]]*server_name[[:space:]]+[^;[:space:]]+' "$f" | awk '{print $2}' || true)
        if [ -z "$name" ] || [ "$name" = "_" ]; then
            continue
        fi
        if [[ "$name" == .* ]] || [[ "$name" == \*.* ]]; then
            name="test.${name#*.}"
        fi
        code=$(curl -sk -o /dev/null --max-time 10 -w '%{http_code}' \
            --resolve "${name}:443:127.0.0.1" "https://${name}/" 2>/dev/null || true)
        echo "  https://${name}/ -> ${code:-FAIL}"
    done
}

cmd_status() {
    if [ -f "$SPLIT_CONF" ]; then
        echo "模式: split (TCP 443 -> stream, 网站在 127.0.0.1:${BACKEND_PORT})"
    elif [ -f "$LISTEN_SNIPPET" ]; then
        echo "模式: normal (网站直接监听 443, 已使用 https_listen 片段)"
    else
        echo "模式: normal (未安装 https_listen 片段)"
    fi
    if compgen -G "$MAP_DIR/*.map" >/dev/null; then
        echo "分流登记:"
        cat "$MAP_DIR"/*.map | sed 's/^/  /'
    fi
    echo "TCP 监听:"
    ss -tlnpH "( sport = :443 or sport = :${BACKEND_PORT} )" | awk '{print "  "$4, $6}'
}

cmd_enable() {
    "$NGINX_BIN" -V 2>&1 | grep -q -- '--with-stream_ssl_preread_module' \
        || die "当前 Nginx 没有编译 stream_ssl_preread, 先用 00_install_nginx.sh 重装"
    command -v python3 >/dev/null 2>&1 || die "需要 python3"

    log "[1/5] 检查与备份"
    check_outside_conf_d
    local holder
    holder=$(ss -tlnpH "sport = :${BACKEND_PORT}" | grep -v nginx || true)
    [ -z "$holder" ] || die "127.0.0.1:${BACKEND_PORT} 已被其他进程占用: $holder"
    mkdir -p "$SNIPPET_DIR" "$MAP_DIR"
    backup_conf

    log "[2/5] 迁移 conf.d 站点"
    local out rc=0
    out=$(migrate_sites) || rc=$?
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | grep -v '^IPV6$' | sed 's/^/  /' || true
    fi
    if [ "$rc" -ne 0 ]; then
        rollback 0
        die "迁移中止, 配置未改动"
    fi
    if printf '%s\n' "$out" | grep -qx 'IPV6'; then
        touch "$IPV6_MARK"
    fi

    log "[3/5] 写入分流配置"
    ensure_stream_block
    write_snippets split
    write_split_conf
    local left
    left=$(grep -nE '^[[:space:]]*listen[[:space:]]+([^[:space:];]*:)?443[[:space:]]+[^;]*ssl' "$CONF_D"/*.conf || true)
    if [ -n "$left" ]; then
        rollback 0
        die "迁移后仍有站点直接监听 443 ssl: $left"
    fi

    log "[4/5] nginx -t 并重启"
    if ! "$NGINX_BIN" -t; then
        rollback 0
        die "nginx -t 失败, 已回滚"
    fi
    if ! systemctl restart nginx; then
        rollback 1
        die "nginx 重启失败, 已回滚"
    fi
    sleep 1
    if ! ss -tlnpH "sport = :443" | grep -q nginx \
        || ! ss -tlnpH "sport = :${BACKEND_PORT}" | grep -q nginx; then
        rollback 1
        die "重启后没有同时监听 443 和 ${BACKEND_PORT}, 已回滚"
    fi
    ok "nginx 已在 443 分流, 网站在 127.0.0.1:${BACKEND_PORT}"

    log "[5/5] 本机自检 (经 443 分流访问各站点)"
    self_test
    echo ""
    echo "备份: $BACKUP_FILE"
}

cmd_disable() {
    if [ ! -f "$SPLIT_CONF" ]; then
        ok "当前未开启分流"
        return 0
    fi
    if compgen -G "$MAP_DIR/*.map" >/dev/null; then
        warn "以下 SNI 仍登记在分流表里, 关闭后它们将无法通过 443 访问:"
        cat "$MAP_DIR"/*.map | sed 's/^/  /'
    fi
    backup_conf
    write_snippets normal
    rm -f "$SPLIT_CONF"
    if ! "$NGINX_BIN" -t; then
        rollback 0
        die "nginx -t 失败, 已回滚"
    fi
    if ! systemctl restart nginx; then
        rollback 1
        die "nginx 重启失败, 已回滚"
    fi
    ok "已关闭分流, 网站直接监听 443"
    warn "迁移时注释掉的 real_ip_header 不会自动恢复, 需要的话请手动打开"
}

cmd_plan() {
    command -v python3 >/dev/null 2>&1 || die "需要 python3"
    local real="$CONF" tmp rc=0
    tmp=$(mktemp -d)
    cp -a "$real" "$tmp/conf"
    sed -i "s|$real/|$tmp/conf/|g" "$tmp/conf/nginx.conf"
    (
        set_paths "$tmp/conf"
        check_outside_conf_d
        mkdir -p "$SNIPPET_DIR" "$MAP_DIR"
        out=$(migrate_sites) || { printf '%s\n' "$out"; exit 2; }
        printf '%s\n' "$out" | sed "s|$tmp/conf|$real|g"
        if printf '%s\n' "$out" | grep -qx 'IPV6'; then
            touch "$IPV6_MARK"
        fi
        ensure_stream_block >/dev/null
        write_snippets split
        write_split_conf
        echo "--- nginx -t (临时副本)"
        "$NGINX_BIN" -t -c "$CONF/nginx.conf" 2>&1 | sed "s|$tmp/conf|$real|g"
    ) || rc=$?
    echo "--- conf.d 差异"
    diff -ru "$real/conf.d" "$tmp/conf/conf.d" | sed "s|$tmp/conf|$real|g" || true
    rm -rf "$tmp"
    [ "$rc" -eq 0 ] || die "预演失败"
    ok "预演完成, 真实配置未改动"
}

case "$ACTION" in
    plan)    cmd_plan ;;
    enable)  cmd_enable ;;
    disable) cmd_disable ;;
    status)  cmd_status ;;
    *) die "用法: $0 plan|enable|disable|status" ;;
esac
