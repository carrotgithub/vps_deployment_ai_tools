#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC2034
################################################################################
#
# HongBox（洪盒）— AI 原生服务器部署工具
# 版本: v4.0.0
#
# 功能说明：
#   通过 plan/preflight/apply/status/doctor 命令部署 AI 工具集群
#
# 使用方法：
#   chmod +x install.sh
#   ./install.sh plan --services new-api --domain api.example.com
#   ./install.sh preflight --profile deploy.env
#   sudo ./install.sh apply --profile deploy.env --yes
#   ./install.sh -h                # 显示帮助
#   ./install.sh --version         # 显示版本
#
# 远程安装：
#   curl -fsSL https://.../install.sh | sudo bash
#
# 可用组件：
#   1. Maintenance        - 服务器维护基线：fail2ban / swap / 日志限制
#   2. Nginx (HTTP/3)     - 高性能 Web 服务器 + 反向代理
#   3. Docker 容器环境    - Docker Engine + Compose 插件
#   4. CliproxyAPI        - 轻量 AI API 转发代理（默认 Docker Compose，可选裸机）
#   5. New-API            - AI 模型网关与资产管理系统
#   6. Pi 编程助手       - 终端 AI 编程助手
#
################################################################################

set -euo pipefail

# ==================== 版本与仓库信息 ====================
readonly VERSION="4.0.0"
readonly HONGAIBOX_REPO="YoungHong1992/hong-ai-box"

show_bootstrap_help() {
    cat <<EOF
HongBox v${VERSION} — AI-native server deployment toolkit

用法:
  ./install.sh plan --services new-api --domain api.example.com
  ./install.sh preflight --profile deploy.env
  sudo ./install.sh apply --profile deploy.env --yes
  ./install.sh status
  ./install.sh doctor --profile deploy.env
  ./install.sh -h
  ./install.sh --version

远程安装:
  curl -fsSL https://raw.githubusercontent.com/${HONGAIBOX_REPO}/main/install.sh | bash

说明:
  无参数运行只显示帮助，不进入终端菜单。请让 AI agent 先生成 plan/preflight，
  人工确认后再执行 apply --yes。
EOF
}

# --version/--help 不依赖完整仓库，允许单文件下载后直接查询。
for arg in "$@"; do
    case "$arg" in
        -h|--help) show_bootstrap_help; exit 0 ;;
        --version) echo "v${VERSION}"; exit 0 ;;
    esac
done

# ==================== 路径解析 / 单文件自举 ====================
resolve_install_dir() {
    local source_path="${BASH_SOURCE[0]:-$0}"
    cd "$(dirname "$source_path")" 2>/dev/null && pwd || pwd
}

INSTALL_DIR="$(resolve_install_dir)"

bootstrap_full_repo() {
    local ref="${HONGAIBOX_REF:-main}"
    local tmp_dir archive_url archive_file root_dir status

    echo "[INFO] 未检测到完整仓库，正在下载 hong-ai-box (${ref})..." >&2

    if ! command -v tar &>/dev/null; then
        echo "[ERROR] 缺少 tar，无法解压完整安装包。" >&2
        exit 1
    fi

    tmp_dir="$(mktemp -d)"
    archive_file="$tmp_dir/hong-ai-box.tar.gz"

    if [[ "$ref" == v* ]]; then
        archive_url="https://github.com/${HONGAIBOX_REPO}/archive/refs/tags/${ref}.tar.gz"
    else
        archive_url="https://github.com/${HONGAIBOX_REPO}/archive/refs/heads/${ref}.tar.gz"
    fi

    if command -v curl &>/dev/null; then
        curl -fsSL "$archive_url" -o "$archive_file"
    elif command -v wget &>/dev/null; then
        wget -qO "$archive_file" "$archive_url"
    else
        echo "[ERROR] 缺少 curl/wget，无法下载完整安装包。" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    tar -xzf "$archive_file" -C "$tmp_dir"
    root_dir="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"

    if [ -z "$root_dir" ] \
        || [ ! -f "$root_dir/install.sh" ] \
        || [ ! -f "$root_dir/maintenance/install.sh" ] \
        || [ ! -f "$root_dir/nginx/install.sh" ] \
        || [ ! -f "$root_dir/docker/install.sh" ] \
        || [ ! -f "$root_dir/cliproxyapi/install.sh" ] \
        || [ ! -f "$root_dir/new-api/install.sh" ] \
        || [ ! -f "$root_dir/pi-coding-agent/install.sh" ] \
        || [ ! -f "$root_dir/lib/common.sh" ] \
        || [ ! -f "$root_dir/lib/crypto.sh" ] \
        || [ ! -f "$root_dir/lib/credentials.sh" ]; then
        echo "[ERROR] 下载的安装包不完整。" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    chmod +x "$root_dir/install.sh"

    set +e
    if [ -r /dev/tty ]; then
        bash "$root_dir/install.sh" "$@" < /dev/tty
    else
        bash "$root_dir/install.sh" "$@"
    fi
    status=$?
    set -e

    rm -rf "$tmp_dir"
    exit "$status"
}

# ==================== 完整仓库检测 ====================
if [ ! -f "$INSTALL_DIR/maintenance/install.sh" ] \
    || [ ! -f "$INSTALL_DIR/nginx/install.sh" ] \
    || [ ! -f "$INSTALL_DIR/docker/install.sh" ] \
    || [ ! -f "$INSTALL_DIR/cliproxyapi/install.sh" ] \
    || [ ! -f "$INSTALL_DIR/new-api/install.sh" ] \
    || [ ! -f "$INSTALL_DIR/pi-coding-agent/install.sh" ] \
    || [ ! -f "$INSTALL_DIR/lib/common.sh" ] \
    || [ ! -f "$INSTALL_DIR/lib/crypto.sh" ] \
    || [ ! -f "$INSTALL_DIR/lib/credentials.sh" ]; then
    bootstrap_full_repo "$@"
fi

# ==================== 自包含公共函数 ====================
# 本脚本可独立运行，不依赖外部公共库。
# shellcheck disable=SC2034
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
readonly COMMON_VERSION="4.0.0"
readonly DEPLOY_LOG_DIR="/var/log/vps-deploy"

print_header() {
    local title="${1:-部署工具}"
    clear 2>/dev/null || true
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    printf  "║           %-51s║\n" "$title"
    echo "║                                                              ║"
    printf  "║               版本: v%-40s║\n" "${COMMON_VERSION}"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_divider() {
    echo -e "${DIM}────────────────────────────────────────────────────────────────${NC}"
}

print_section() {
    echo ""
    echo -e "${BOLD}${BLUE}▶ $1${NC}"
    print_divider
}

setup_logging() {
    local script_name="${1:-deploy}"
    mkdir -p "$DEPLOY_LOG_DIR"
    DEPLOY_LOG_FILE="${DEPLOY_LOG_DIR}/${script_name}-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$DEPLOY_LOG_FILE") 2>&1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] === 日志开始: $DEPLOY_LOG_FILE ==="
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 脚本: $script_name"
}

log_info()    { echo -e "${BLUE}[INFO]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_debug()   { echo -e "${DIM}[DEBUG]${NC} $(date '+%H:%M:%S') $*" >&2; }

generate_password() {
    local length="${1:-32}"
    openssl rand -base64 48 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

generate_session_secret() {
    local length="${1:-48}"
    openssl rand -base64 64 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

generate_api_key() {
    local prefix="${1:-sk-}"
    local key_body
    key_body=$(openssl rand -base64 48 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 45)
    echo "${prefix}${key_body}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] 必须使用 root 权限运行此脚本。${NC}"
        echo -e "${YELLOW}请使用: sudo $0${NC}"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2; exit }' /etc/os-release
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

detect_os_version() {
    if [ -f /etc/os-release ]; then
        awk -F= '$1 == "VERSION_CODENAME" { gsub(/"/, "", $2); print $2; exit }' /etc/os-release
    else
        echo "unknown"
    fi
}

detect_server_ip() {
    local ip
    ip=$(curl -s --connect-timeout 5 https://api.ipify.org 2>/dev/null || \
         curl -s --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
         curl -s --connect-timeout 5 https://icanhazip.com 2>/dev/null || \
         hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "linux_amd64" ;;
        arm64|aarch64)  echo "linux_arm64" ;;
        *)              echo "unknown" ;;
    esac
}

check_port_available() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

ensure_port_available() {
    local port="$1"
    local service_name="${2:-服务}"
    if ! check_port_available "$port"; then
        log_error "端口 $port 已被占用，$service_name 无法使用此端口。"
        log_info "请先释放端口或修改脚本中的端口配置。"
        exit 1
    fi
    log_debug "端口 $port 可用"
}

check_command_available() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "缺少必要工具: $cmd，请安装后重试。"
        return 1
    fi
    return 0
}

ensure_commands() {
    local missing=""
    for cmd in "$@"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        log_error "缺少必要工具:${missing}"
        log_info "请运行: apt-get install -y${missing}"
        exit 1
    fi
}

detect_nginx_http3() {
    if command -v nginx &>/dev/null && nginx -V 2>&1 | grep -q "http_v3_module"; then
        return 0
    fi
    return 1
}

get_main_domain_email() {
    local domain="$1"
    local main_domain
    main_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
    echo "admin@${main_domain}"
}

is_valid_ssl_email() {
    local email="$1"
    [ -z "$email" ] && return 1
    echo "$email" | grep -qE "@(example\.com|localhost|test\.com)" && return 1
    return 0
}

ensure_acme_sh_config() {
    local domain="$1"
    local expected_email
    expected_email=$(get_main_domain_email "$domain")

    if [ ! -f ~/.acme.sh/acme.sh ]; then
        log_info "安装 acme.sh..."
        curl -s --connect-timeout 10 https://get.acme.sh | sh -s email="$expected_email" >/dev/null 2>&1 || true
        return 0
    fi

    if [ -f ~/.acme.sh/account.conf ]; then
        local current_email
        current_email=$(grep "^ACCOUNT_EMAIL=" ~/.acme.sh/account.conf 2>/dev/null | cut -d"'" -f2 || true)

        if ! is_valid_ssl_email "$current_email"; then
            log_info "修正 acme.sh 邮箱配置..."
            sed -i "s/^ACCOUNT_EMAIL=.*/ACCOUNT_EMAIL='$expected_email'/g" ~/.acme.sh/account.conf
            rm -rf ~/.acme.sh/ca/*/account.json 2>/dev/null || true
        fi
    fi
}

apply_ssl_certificate() {
    local domain="$1"
    local ssl_dir="$2"
    local mode="$3"

    mkdir -p "$ssl_dir"

    case "$mode" in
        http)
            log_info "HTTP 模式，跳过 SSL 证书配置。"
            echo "无 (HTTP 模式)"
            return 0
            ;;
        domain)
            log_info "申请 Let's Encrypt ECC-256 证书..."

            ensure_acme_sh_config "$domain"
            local safe_domain temp_conf default_site default_backup default_moved=false
            safe_domain=$(printf '%s' "$domain" | tr -c 'A-Za-z0-9_.-' '_')
            temp_conf="/etc/nginx/conf.d/00-acme-${safe_domain}.conf"
            default_site="/etc/nginx/sites-enabled/default"
            default_backup="/etc/nginx/sites-enabled/default.disabled-by-ssl"

            cat > "$temp_conf" <<NGINX_TEMP
server {
    listen 80;
    server_name $domain;
    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }
}
NGINX_TEMP

            mkdir -p /var/www/acme
            chmod 755 /var/www/acme
            if [ -f "$default_site" ]; then
                mv "$default_site" "$default_backup" 2>/dev/null && default_moved=true || true
            fi
            systemctl reload nginx >/dev/null 2>&1 || true

            if ~/.acme.sh/acme.sh --issue --server letsencrypt -d "$domain" --webroot /var/www/acme --keylength ec-256 >&2; then
                ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
                    --key-file       "$ssl_dir/key.pem" \
                    --fullchain-file "$ssl_dir/fullchain.pem" \
                    --reloadcmd     "systemctl reload nginx" >/dev/null 2>&1 || true

                if [ -f "$ssl_dir/fullchain.pem" ]; then
                    log_success "SSL 证书申请成功 (Let's Encrypt ECC-256)"
                    rm -f "$temp_conf"
                    if [ "$default_moved" = true ] && [ -f "$default_backup" ]; then
                        mv "$default_backup" "$default_site" 2>/dev/null || true
                    fi
                    systemctl reload nginx >/dev/null 2>&1 || true
                    echo "Let's Encrypt (ECC-256)"
                    return 0
                fi
            fi

            log_warning "Let's Encrypt 申请失败，降级为自签名证书..."
            rm -f "$temp_conf"
            if [ "$default_moved" = true ] && [ -f "$default_backup" ]; then
                mv "$default_backup" "$default_site" 2>/dev/null || true
            fi
            systemctl reload nginx >/dev/null 2>&1 || true
            ;;
        ip)
            log_info "生成自签名证书 (IP 模式)..."
            ;;
    esac

    local san
    if validate_ip "$domain" 2>/dev/null; then
        san="IP:$domain"
    else
        san="DNS:$domain"
    fi

    if openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$ssl_dir/key.pem" \
        -out "$ssl_dir/fullchain.pem" \
        -subj "/CN=$domain" \
        -addext "subjectAltName=$san" >/dev/null 2>&1; then
        log_success "自签名证书生成成功"
        echo "自签名证书"
    else
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$ssl_dir/key.pem" \
            -out "$ssl_dir/fullchain.pem" \
            -subj "/CN=$domain" >/dev/null 2>&1
        log_success "自签名证书生成成功 (兼容模式)"
        echo "自签名证书"
    fi
}

readonly NGINX_SSL_CONFIG='
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    add_header Strict-Transport-Security "max-age=31536000" always;'

readonly NGINX_REDIRECT_LOGIC='
    set $isRedcert 1;
    if ($server_port != 443) {
        set $isRedcert 2;
    }
    if ( $uri ~ /\.well-known/ ) {
        set $isRedcert 1;
    }
    if ($isRedcert != 1) {
        rewrite ^(.*)$ https://$host$1 permanent;
    }'

backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        local backup
        backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp -a "$file" "$backup"
        log_info "已备份: $backup"
    fi
}

find_nginx_conf_by_server_name() {
    local domain="$1"
    local conf_dir="${2:-/etc/nginx/conf.d}"
    local conf

    [ -d "$conf_dir" ] || return 1

    while IFS= read -r -d '' conf; do
        if awk -v domain="$domain" '
            {
                for (i = 1; i <= NF; i++) {
                    token = $i
                    gsub(/[{};]/, "", token)

                    if (in_server_name && token == domain) found = 1
                    if (in_server_name && $i ~ /;/) in_server_name = 0
                    if (token == "server_name") in_server_name = 1
                }
            }
            END { exit found ? 0 : 1 }
        ' "$conf"; then
            echo "$conf"
            return 0
        fi
    done < <(find "$conf_dir" -maxdepth 1 -type f -name "*.conf" -print0 2>/dev/null)

    return 1
}

detect_compose_cmd() {
    if docker compose version &>/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    else
        echo ""
    fi
}

wait_for_healthy() {
    local compose_cmd="$1"
    local service_dir="$2"
    local max_wait="${3:-60}"
    local interval="${4:-5}"
    shift 4
    local required_services=("$@")

    cd "$service_dir" || { log_error "无法进入目录: $service_dir"; return 1; }

    local waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        local all_healthy=true

        if [ "${#required_services[@]}" -eq 0 ]; then
            if $compose_cmd ps 2>/dev/null | grep -q "(healthy)"; then
                log_success "服务已健康运行 (${waited}s)"
                return 0
            fi
            all_healthy=false
        else
            for svc in "${required_services[@]}"; do
                if ! $compose_cmd ps 2>/dev/null | grep -q "${svc}.*(healthy)"; then
                    all_healthy=false
                    break
                fi
            done
        fi

        if [ "$all_healthy" = true ]; then
            log_success "所有指定服务已健康运行 (${waited}s)"
            return 0
        fi

        if ! $compose_cmd ps 2>/dev/null | grep -q "Up"; then
            log_warning "检测到容器未运行，继续等待..."
        fi

        sleep "$interval"
        waited=$((waited + interval))
    done

    log_warning "等待超时 (${max_wait}s)，请手动检查服务状态"
    $compose_cmd ps 2>/dev/null || true
    return 1
}

is_noninteractive() {
    [ "${HONGAIBOX_UNATTENDED:-}" = "1" ]
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"

    if [ "$default" = "y" ]; then
        printf "%s [Y/n]: " "$prompt"
    else
        printf "%s [y/N]: " "$prompt"
    fi

    read -r response
    response=${response:-$default}

    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

wait_key() {
    echo ""
    read -r -p "按 Enter 键继续..." _
}

validate_domain() {
    local domain="$1"
    if [ -z "$domain" ]; then
        log_error "域名不能为空。"
        return 1
    fi
    if ! [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        log_error "域名格式不正确: $domain"
        return 1
    fi
    return 0
}

validate_ip() {
    local ip="$1"
    local IFS=. octet

    if [ -z "$ip" ]; then
        log_error "IP 不能为空。"
        return 1
    fi

    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        for octet in $ip; do
            if [ "$octet" -gt 255 ]; then
                log_error "IPv4 地址格式不正确: $ip"
                return 1
            fi
        done
        return 0
    fi

    if [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]]; then
        return 0
    fi

    log_error "IP 地址格式不正确: $ip"
    return 1
}

validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "端口必须是 1-65535 的数字: $port"
        return 1
    fi
    return 0
}

validate_sni() {
    local sni="$1"
    validate_domain "$sni"
}

escape_double_quoted() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

select_access_mode() {
    echo "" >&2
    echo -e "${CYAN}>>> 请选择访问方式${NC}" >&2
    echo "" >&2
    echo "  1) 使用域名（推荐）- 自动申请 Let's Encrypt 证书" >&2
    echo "  2) 使用 IP 地址   - 自签名证书，无需域名" >&2
    echo "  3) 仅使用 HTTP    - 无 SSL 证书，仅限内网/开发环境" >&2
    echo "" >&2

    local mode
    while true; do
        read -r -p "请选择 [1/2/3]: " mode
        case "$mode" in
            1) echo "domain"; return 0 ;;
            2) echo "ip"; return 0 ;;
            3) echo "http"; return 0 ;;
            *) log_warning "无效选择，请重新输入" >&2 ;;
        esac
    done
}

get_domain_for_mode() {
    local mode="$1"

    case "$mode" in
        domain)
            local domain
            read -r -p "请输入域名 (例如 api.example.com): " domain
            validate_domain "$domain" || exit 1
            echo "$domain"
            ;;
        ip|http)
            local server_ip ip_confirm domain
            server_ip=$(detect_server_ip)
            if [ -z "$server_ip" ] || ! validate_ip "$server_ip"; then
                log_error "无法获取有效服务器 IP，请手动输入。" >&2
                while true; do
                    read -r -p "请输入服务器 IP 地址: " server_ip
                    validate_ip "$server_ip" && break
                done
            fi
            echo "" >&2
            echo -e "检测到服务器 IP: ${GREEN}$server_ip${NC}" >&2

            if [ "$mode" = "http" ]; then
                echo -e "${YELLOW}⚠️  HTTP 模式警告：${NC}" >&2
                echo -e "${YELLOW}   - 数据传输不加密，API Key 可能泄露${NC}" >&2
                echo -e "${YELLOW}   - 仅建议在内网或开发环境使用${NC}" >&2
            fi

            echo "" >&2
            read -r -p "确认使用此 IP？(y/n，或直接输入其他 IP): " ip_confirm

            case "$ip_confirm" in
                [Yy]|"") echo "$server_ip" ;;
                [Nn])
                    while true; do
                        read -r -p "请输入 IP 地址: " domain
                        validate_ip "$domain" && break
                    done
                    echo "$domain"
                    ;;
                *)
                    if validate_ip "$ip_confirm"; then
                        echo "$ip_confirm"
                    else
                        exit 1
                    fi
                    ;;
            esac
            ;;
    esac
}

# ==================== 帮助信息 ====================
show_help() {
    cat <<EOF
HongBox v${VERSION} — AI-native server deployment toolkit

用法:
  ./install.sh plan --services new-api --domain api.example.com
  ./install.sh preflight --profile deploy.env
  sudo ./install.sh apply --profile deploy.env --yes
  ./install.sh status
  ./install.sh doctor --profile deploy.env
  ./install.sh -h
  ./install.sh --version

AI 协作流程:
  1. 在对话中确认服务、域名、数据库和风险项
  2. 生成 .env profile 或明确 CLI 参数
  3. plan 输出部署计划
  4. preflight 检查环境
  5. 用户确认后 apply --yes 非交互执行
  6. status/doctor 检查状态和排障

可用组件:
  Maintenance              服务器维护基线：fail2ban / swap / 日志限制 / Docker 日志轮转
  Nginx (HTTP/3)           高性能 Web 服务器 + 反向代理
  Docker 容器环境          Docker Engine + Compose 插件
  CliproxyAPI              轻量 AI API 转发代理 (默认 Docker Compose，可选裸机)
  New-API                  AI 模型网关与资产管理系统 (需 ≥1GB 内存)
  Pi 编程助手              终端 AI 编程助手 (500MB 磁盘)

注意:
  - 需要 root 权限
  - 域名模式需要 DNS 已解析
  - apply 必须显式 --yes 或 HONGBOX_CONFIRM_APPLY=yes
  - 安装日志保存在 /var/log/vps-deploy/
EOF
    exit 0
}

# ==================== 参数解析 ====================
case "${1:-}" in
    plan|preflight|apply|status|doctor|help) ;;
    *)
        for arg in "$@"; do
            case "$arg" in
                -h|--help)    show_help ;;
                --version)    echo "v${VERSION}"; exit 0 ;;
                -*)           echo "未知参数: $arg"; echo "使用 -h 查看帮助"; exit 1 ;;
            esac
        done
        ;;
esac

# ==================== 全局状态 ====================

# Service IDs
readonly SVC_MAINTENANCE="maintenance"
readonly SVC_NGINX="nginx"
readonly SVC_DOCKER="docker"
readonly SVC_CLIPROXY="cliproxyapi"
readonly SVC_NEWAPI="newapi"
readonly SVC_PI="pi"

# Service definitions (order = dependency order)
declare -A SVC_NAME SVC_DESC SVC_HINT SVC_SCRIPT SVC_DEPENDS
SVC_NAME[$SVC_MAINTENANCE]="Maintenance"
SVC_DESC[$SVC_MAINTENANCE]="基础维护：fail2ban、swap、日志限制、Docker 日志轮转"
SVC_HINT[$SVC_MAINTENANCE]="基础维护"
SVC_SCRIPT[$SVC_MAINTENANCE]="$INSTALL_DIR/maintenance/install.sh"
SVC_DEPENDS[$SVC_MAINTENANCE]=""

SVC_NAME[$SVC_NGINX]="Nginx (HTTP/3)"
SVC_DESC[$SVC_NGINX]="Nginx 官方主线仓库安装，支持 HTTP/3 (QUIC)、TCP BBR 优化"
SVC_HINT[$SVC_NGINX]="512MB 内存"
SVC_SCRIPT[$SVC_NGINX]="$INSTALL_DIR/nginx/install.sh"
SVC_DEPENDS[$SVC_NGINX]=""

SVC_NAME[$SVC_DOCKER]="Docker 容器环境"
SVC_DESC[$SVC_DOCKER]="Docker Engine + Docker Compose 插件"
SVC_HINT[$SVC_DOCKER]="无额外需求"
SVC_SCRIPT[$SVC_DOCKER]="$INSTALL_DIR/docker/install.sh"
SVC_DEPENDS[$SVC_DOCKER]=""

SVC_NAME[$SVC_CLIPROXY]="CliproxyAPI"
SVC_DESC[$SVC_CLIPROXY]="轻量 AI API 转发代理，默认 Docker Compose，支持裸机 Systemd"
SVC_HINT[$SVC_CLIPROXY]="256MB 内存"
SVC_SCRIPT[$SVC_CLIPROXY]="$INSTALL_DIR/cliproxyapi/install.sh"
SVC_DEPENDS[$SVC_CLIPROXY]="$SVC_NGINX $SVC_DOCKER"

SVC_NAME[$SVC_NEWAPI]="New-API"
SVC_DESC[$SVC_NEWAPI]="AI 模型网关与资产管理系统，支持多模型聚合、计费、用户管理"
SVC_HINT[$SVC_NEWAPI]="≥ 1GB 内存"
SVC_SCRIPT[$SVC_NEWAPI]="$INSTALL_DIR/new-api/install.sh"
SVC_DEPENDS[$SVC_NEWAPI]="$SVC_NGINX $SVC_DOCKER"

SVC_NAME[$SVC_PI]="Pi 编程助手"
SVC_DESC[$SVC_PI]="极简终端 AI 编程助手，支持 Anthropic/OpenAI/Gemini/DeepSeek"
SVC_HINT[$SVC_PI]="500MB 磁盘"
SVC_SCRIPT[$SVC_PI]="$INSTALL_DIR/pi-coding-agent/install.sh"
SVC_DEPENDS[$SVC_PI]=""

# Ordered list for display
readonly ALL_SERVICES=(
    "$SVC_MAINTENANCE" "$SVC_NGINX" "$SVC_DOCKER"
    "$SVC_CLIPROXY" "$SVC_NEWAPI" "$SVC_PI"
)

# Runtime state
declare -A ALREADY_INSTALLED   # true if already present on system
declare -A TO_INSTALL          # true if user selected to install
declare -A FORCE_INSTALL       # true if installed service is explicitly selected for reinstall
declare -A SERVICE_DOMAIN      # per Web service domain/IP
declare -A INSTALL_FAILED      # true if service failed/skipped due dependency
INSTALL_ORDER=()               # resolved dependency order
INSTALL_RESULTS=()             # for summary
FAILED=0                       # non-zero when any service failed

# User config
ACCESS_MODE=""
DOMAIN=""                     # single Web service IP/domain fallback
ADMIN_PASSWORD=""              # cliproxyapi
CLIPROXY_DEPLOY_MODE="docker"  # docker | bare
DB_TYPE="postgresql"           # newapi

# ==================== 单轮状态重置 ====================

reset_iteration_state() {
    TO_INSTALL=()
    FORCE_INSTALL=()
    SERVICE_DOMAIN=()
    INSTALL_FAILED=()
    INSTALL_ORDER=()
    INSTALL_RESULTS=()
    FAILED=0

    ACCESS_MODE=""
    DOMAIN=""
    ADMIN_PASSWORD=""
    CLIPROXY_DEPLOY_MODE="docker"
    DB_TYPE="postgresql"

    # CliproxyAPI 默认 Docker Compose；裸机选择只在当前轮生效。
    SVC_DEPENDS[$SVC_CLIPROXY]="$SVC_NGINX $SVC_DOCKER"
}

prompt_return_home() {
    echo ""
    echo -e "${YELLOW}按 Enter 返回首页继续安装其他服务 | 输入 q 退出${NC}"
    echo ""

    local next_action
    read -r -p "请选择 [Enter/q]: " next_action
    case "$next_action" in
        [Qq]) return 1 ;;
        *)    return 0 ;;
    esac
}

# ==================== 服务检测 ====================

detect_installed_services() {
    ALREADY_INSTALLED=()
    if [ -z "${CLI_COMMAND:-}" ]; then
        echo ""
        echo -e "${CYAN}正在检测已安装的服务...${NC}"
    fi

    for svc in "${ALL_SERVICES[@]}"; do
        case "$svc" in
            "$SVC_MAINTENANCE")
                if [ -f /var/lib/hongaibox/maintenance.installed ]; then
                    ALREADY_INSTALLED[$svc]=true
                fi
                ;;
            "$SVC_NGINX")
                if command -v nginx &>/dev/null \
                    && nginx -t >/dev/null 2>&1 \
                    && systemctl is-active --quiet nginx 2>/dev/null; then
                    ALREADY_INSTALLED[$svc]=true
                fi
                ;;
            "$SVC_DOCKER")
                if command -v docker &>/dev/null \
                    && systemctl is-active --quiet docker 2>/dev/null \
                    && (docker compose version &>/dev/null || command -v docker-compose &>/dev/null); then
                    ALREADY_INSTALLED[$svc]=true
                fi
                ;;
            "$SVC_CLIPROXY")
                if [ -f /opt/docker-services/cliproxyapi/docker-compose.yml ] \
                    || [ -f /opt/cliproxyapi/version.txt ] \
                    || [ -f /etc/systemd/system/cliproxyapi.service ]; then
                    ALREADY_INSTALLED[$svc]=true
                fi
                ;;
            "$SVC_NEWAPI")
                if [ -f /opt/docker-services/new-api/docker-compose.yml ]; then
                    ALREADY_INSTALLED[$svc]=true
                fi
                ;;
            "$SVC_PI")
                if command -v pi &>/dev/null; then
                    ALREADY_INSTALLED[$svc]=true
                fi
                ;;
        esac
    done
}

# ==================== 显示服务面板 ====================

service_short_name() {
    case "$1" in
        "$SVC_MAINTENANCE") echo "Maintenance" ;;
        "$SVC_NGINX")    echo "Nginx" ;;
        "$SVC_DOCKER")   echo "Docker" ;;
        "$SVC_CLIPROXY") echo "CliproxyAPI" ;;
        "$SVC_NEWAPI")   echo "New-API" ;;
        "$SVC_PI")       echo "Pi" ;;
        *)                echo "$1" ;;
    esac
}

service_resource_hint() {
    case "$1" in
        "$SVC_MAINTENANCE") echo "Baseline" ;;
        "$SVC_NGINX")    echo "512MB RAM" ;;
        "$SVC_DOCKER")   echo "No extra" ;;
        "$SVC_CLIPROXY") echo "256MB RAM" ;;
        "$SVC_NEWAPI")   echo "1GB+ RAM" ;;
        "$SVC_PI")       echo "500MB disk" ;;
        *)                echo "-" ;;
    esac
}

repeat_char() {
    local char="$1"
    local count="$2"
    local i
    for ((i = 0; i < count; i++)); do
        printf '%s' "$char"
    done
}

text_display_width() {
    local text="$1"
    local bytes chars
    bytes=$(printf '%s' "$text" | wc -c | tr -d '[:space:]')
    chars=$(printf '%s' "$text" | wc -m | tr -d '[:space:]')
    echo $((chars + (bytes - chars) / 2))
}

pad_text() {
    local text="$1"
    local width="$2"
    local visible pad
    visible=$(text_display_width "$text")
    printf '%s' "$text"
    if [ "$visible" -lt "$width" ]; then
        pad=$((width - visible))
        printf '%*s' "$pad" ""
    fi
}

fit_text() {
    local text="$1"
    local width="$2"
    local visible ellipsis ellipsis_width result result_width char char_width i char_count

    visible=$(text_display_width "$text")
    if [ "$visible" -le "$width" ]; then
        pad_text "$text" "$width"
        return 0
    fi

    ellipsis="…"
    ellipsis_width=$(text_display_width "$ellipsis")
    result=""
    result_width=0
    char_count=${#text}

    for ((i = 0; i < char_count; i++)); do
        char="${text:i:1}"
        char_width=$(text_display_width "$char")
        if [ $((result_width + char_width + ellipsis_width)) -gt "$width" ]; then
            break
        fi
        result+="$char"
        result_width=$((result_width + char_width))
    done

    pad_text "${result}${ellipsis}" "$width"
}

show_service_panel() {
    clear 2>/dev/null || true
    print_header "洪哥的 AI 工具箱"

    echo -e "${WHITE}欢迎使用洪哥的 AI 工具箱部署脚本！${NC}"
    echo ""
    echo "本工具将引导您在云服务器上一键部署 AI 工具集群。"
    echo ""

    local col_index=4
    local col_service=14
    local col_status=8
    local col_desc=68
    local rule_index rule_service rule_status rule_desc
    rule_index=$(repeat_char "─" $((col_index + 2)))
    rule_service=$(repeat_char "─" $((col_service + 2)))
    rule_status=$(repeat_char "─" $((col_status + 2)))
    rule_desc=$(repeat_char "─" $((col_desc + 2)))

    echo -e "${CYAN}请选择要安装的服务${NC}"
    echo -e "${CYAN}┌${rule_index}┬${rule_service}┬${rule_status}┬${rule_desc}┐${NC}"
    printf "${CYAN}│${NC} ${BOLD}"
    pad_text "序号" "$col_index"
    printf "${NC} ${CYAN}│${NC} ${BOLD}"
    pad_text "服务" "$col_service"
    printf "${NC} ${CYAN}│${NC} ${BOLD}"
    pad_text "状态" "$col_status"
    printf "${NC} ${CYAN}│${NC} ${BOLD}"
    pad_text "组件说明" "$col_desc"
    printf "${NC} ${CYAN}│${NC}\n"
    echo -e "${CYAN}├${rule_index}┼${rule_service}┼${rule_status}┼${rule_desc}┤${NC}"

    local svc short_name status desc option_idx
    option_idx=1
    for svc in "${ALL_SERVICES[@]}"; do
        short_name=$(service_short_name "$svc")
        desc="${SVC_DESC[$svc]}"

        if [ "${ALREADY_INSTALLED[$svc]:-}" = "true" ]; then
            status="已安装"
        else
            status="未安装"
        fi

        printf "${CYAN}│${NC} "
        pad_text "$option_idx" "$col_index"
        printf " ${CYAN}│${NC} "
        pad_text "$short_name" "$col_service"
        printf " ${CYAN}│${NC} "

        if [ "$status" = "已安装" ]; then
            printf "${GREEN}"
            pad_text "$status" "$col_status"
            printf "${NC}"
        else
            printf "${DIM}"
            pad_text "$status" "$col_status"
            printf "${NC}"
        fi

        printf " ${CYAN}│${NC} "
        pad_text "$desc" "$col_desc"
        printf " ${CYAN}│${NC}\n"
        ((option_idx+=1))
    done

    echo -e "${CYAN}└${rule_index}┴${rule_service}┴${rule_status}┴${rule_desc}┘${NC}"
    echo -e "${DIM}提示: 已安装服务也可选择，确认后会强制覆盖/重新安装。${NC}"
    echo ""
}

# ==================== 选择服务 ====================

select_services() {
    local i=1 raw svc
    declare -A idx_to_svc

    # 每一轮只允许选择一个服务；序号与首页表格第一列一致。
    for svc in "${ALL_SERVICES[@]}"; do
        idx_to_svc[$i]="$svc"
        ((i++))
    done

    echo "  输入表格序号选择一个服务"
    echo "  已安装服务也可选择，确认后会强制覆盖/重新安装"
    echo "  输入 q 退出"
    echo ""

    while true; do
        read -r -p "请选择 [1-$((i-1)) / q]: " raw
        raw="${raw#"${raw%%[![:space:]]*}"}"
        raw="${raw%"${raw##*[![:space:]]}"}"

        case "$raw" in
            [Qq])  echo ""; log_info "已取消部署。"; exit 0 ;;
            "")   continue ;;
        esac

        if [[ "$raw" =~ [[:space:]] ]]; then
            echo -e "${YELLOW}每次只能选择一个服务，请只输入一个序号。${NC}" >&2
            continue
        fi

        if ! [[ "$raw" =~ ^[0-9]+$ ]] || [ "$raw" -lt 1 ] || [ "$raw" -ge "$i" ]; then
            echo -e "${YELLOW}无效选项: $raw${NC}" >&2
            continue
        fi

        svc="${idx_to_svc[$raw]}"
        TO_INSTALL[$svc]=true
        break
    done

    echo ""
    return 0
}

# ==================== 服务选择后的概览确认 ====================

selected_service_id() {
    local svc
    for svc in "${ALL_SERVICES[@]}"; do
        if [ "${TO_INSTALL[$svc]:-}" = "true" ]; then
            echo "$svc"
            return 0
        fi
    done
    return 1
}

overview_table_begin() {
    local col_item=16
    local col_value=74
    local rule_item rule_value
    rule_item=$(repeat_char "─" $((col_item + 2)))
    rule_value=$(repeat_char "─" $((col_value + 2)))

    echo -e "${CYAN}┌${rule_item}┬${rule_value}┐${NC}"
    printf "${CYAN}│${NC} ${BOLD}"
    fit_text "检查项" "$col_item"
    printf "${NC} ${CYAN}│${NC} ${BOLD}"
    fit_text "当前状态 / 配置" "$col_value"
    printf "${NC} ${CYAN}│${NC}\n"
    echo -e "${CYAN}├${rule_item}┼${rule_value}┤${NC}"
}

overview_item() {
    local label="$1"
    local value="$2"
    local col_item=16
    local col_value=74

    printf "${CYAN}│${NC} "
    fit_text "$label" "$col_item"
    printf " ${CYAN}│${NC} "
    fit_text "$value" "$col_value"
    printf " ${CYAN}│${NC}\n"
}

overview_table_end() {
    local col_item=16
    local col_value=74
    local rule_item rule_value
    rule_item=$(repeat_char "─" $((col_item + 2)))
    rule_value=$(repeat_char "─" $((col_value + 2)))
    echo -e "${CYAN}└${rule_item}┴${rule_value}┘${NC}"
}

active_swap_summary() {
    local summary
    summary=$(swapon --show=NAME,SIZE,USED --noheadings 2>/dev/null | awk '{print $1" "$2" used "$3}' | paste -sd '; ' - || true)
    echo "${summary:-未启用}"
}

service_active_text() {
    local unit="$1"
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        echo "运行中"
    elif systemctl list-unit-files "$unit" >/dev/null 2>&1; then
        echo "已安装，未运行"
    else
        echo "未安装"
    fi
}

compose_running_text() {
    local service_dir="$1"
    local compose_cmd
    compose_cmd=$(detect_compose_cmd)

    if [ ! -f "$service_dir/docker-compose.yml" ]; then
        echo "未部署"
        return 0
    fi
    if [ -z "$compose_cmd" ]; then
        echo "已部署，未检测到 Compose 命令"
        return 0
    fi
    if (cd "$service_dir" && $compose_cmd ps 2>/dev/null | grep -q "Up"); then
        echo "运行中"
    else
        echo "已部署，未运行或状态未知"
    fi
}

docker_log_rotation_text() {
    if [ ! -f /etc/docker/daemon.json ]; then
        echo "未配置"
        return 0
    fi
    if grep -q '"max-size"[[:space:]]*:[[:space:]]*"50m"' /etc/docker/daemon.json 2>/dev/null \
        && grep -q '"max-file"[[:space:]]*:[[:space:]]*"3"' /etc/docker/daemon.json 2>/dev/null; then
        echo "已配置 (50m × 3)"
    else
        echo "daemon.json 存在，但未检测到 hong-ai-box 默认轮转值"
    fi
}

show_maintenance_overview() {
    local fail2ban_state sshd_jail journald_state docker_logs marker_state
    fail2ban_state="未安装"
    if command -v fail2ban-client &>/dev/null; then
        fail2ban_state=$(service_active_text "fail2ban")
    fi

    sshd_jail="未启用或状态未知"
    if command -v fail2ban-client &>/dev/null && fail2ban-client status sshd >/dev/null 2>&1; then
        sshd_jail="已启用"
    fi

    if [ -f /etc/systemd/journald.conf.d/hongaibox.conf ]; then
        journald_state="已配置 (/etc/systemd/journald.conf.d/hongaibox.conf)"
    else
        journald_state="未配置"
    fi

    docker_logs=$(docker_log_rotation_text)
    marker_state="未记录"
    [ -f /var/lib/hongaibox/maintenance.installed ] && marker_state="已记录"

    overview_item "安装标记" "$marker_state"
    overview_item "fail2ban" "$fail2ban_state"
    overview_item "SSH jail" "$sshd_jail"
    overview_item "swap" "$(active_swap_summary)"
    overview_item "journald" "$journald_state"
    overview_item "Docker 日志" "$docker_logs"
}

show_nginx_overview() {
    local nginx_version nginx_test http3_state conf_count
    nginx_version=$(nginx -v 2>&1 | sed 's/^nginx version: //' || true)
    [ -z "$nginx_version" ] && nginx_version="未安装"

    if nginx -t >/dev/null 2>&1; then
        nginx_test="通过"
    else
        nginx_test="失败或未安装"
    fi

    if detect_nginx_http3; then
        http3_state="支持"
    else
        http3_state="未检测到"
    fi

    conf_count=$(find /etc/nginx/conf.d -maxdepth 1 -type f -name '*.conf' 2>/dev/null | wc -l | tr -d '[:space:]')
    overview_item "版本" "$nginx_version"
    overview_item "服务状态" "$(service_active_text nginx)"
    overview_item "配置测试" "$nginx_test"
    overview_item "HTTP/3" "$http3_state"
    overview_item "站点配置" "${conf_count:-0} 个 conf.d 配置"
}

show_docker_overview() {
    local docker_version compose_version running_count
    docker_version=$(docker --version 2>/dev/null || echo "未安装")
    compose_version=$(docker compose version 2>/dev/null || docker-compose --version 2>/dev/null || echo "未安装")
    if command -v docker &>/dev/null; then
        running_count=$(docker ps -q 2>/dev/null | wc -l | tr -d '[:space:]')
    else
        running_count="0"
    fi

    overview_item "Docker" "$docker_version"
    overview_item "服务状态" "$(service_active_text docker)"
    overview_item "Compose" "$compose_version"
    overview_item "运行容器" "${running_count:-0} 个"
    overview_item "日志轮转" "$(docker_log_rotation_text)"
}

show_cliproxy_overview() {
    local mode service_state conf_path credentials_file nginx_conf version_text
    mode="未部署"
    service_state="未运行"
    conf_path="-"
    credentials_file="未生成"
    version_text="-"

    if [ -f /opt/docker-services/cliproxyapi/docker-compose.yml ]; then
        mode="Docker Compose"
        service_state=$(compose_running_text /opt/docker-services/cliproxyapi)
        conf_path="/opt/docker-services/cliproxyapi/config.yaml"
        credentials_file="/opt/docker-services/cliproxyapi/hongaibox-credentials.txt"
        [ ! -f "$credentials_file" ] && credentials_file="未生成"
        version_text=$(cat /opt/docker-services/cliproxyapi/version.txt 2>/dev/null || echo "镜像版本未记录")
    elif [ -f /opt/cliproxyapi/version.txt ] || [ -f /etc/systemd/system/cliproxyapi.service ]; then
        mode="裸机 Systemd"
        service_state=$(service_active_text cliproxyapi)
        conf_path="/etc/cliproxyapi/config.yaml"
        credentials_file="/opt/cliproxyapi/hongaibox-credentials.txt"
        [ ! -f "$credentials_file" ] && credentials_file="未生成"
        version_text=$(cat /opt/cliproxyapi/version.txt 2>/dev/null || echo "未知")
    fi

    nginx_conf=$(find /etc/nginx/conf.d -maxdepth 1 -type f -name '*.conf' -exec grep -l 'CLI-PROXY-API-START' {} \; 2>/dev/null | paste -sd, - || true)
    [ -z "$nginx_conf" ] && nginx_conf="未检测到"

    overview_item "部署方式" "$mode"
    overview_item "运行状态" "$service_state"
    overview_item "版本/镜像" "$version_text"
    overview_item "配置文件" "$conf_path"
    overview_item "凭据文件" "$credentials_file"
    overview_item "Nginx 配置" "$nginx_conf"
}

show_newapi_overview() {
    local service_state credentials_file nginx_conf db_type
    service_state=$(compose_running_text /opt/docker-services/new-api)
    credentials_file="/opt/docker-services/new-api/hongaibox-credentials.txt"
    [ ! -f "$credentials_file" ] && credentials_file="未生成"

    nginx_conf=$(find /etc/nginx/conf.d -maxdepth 1 -type f -name '*.conf' -exec grep -l 'NEW-API-START' {} \; 2>/dev/null | paste -sd, - || true)
    [ -z "$nginx_conf" ] && nginx_conf="未检测到"

    db_type="未检测到"
    if [ -f /opt/docker-services/new-api/docker-compose.yml ]; then
        if grep -q 'postgres' /opt/docker-services/new-api/docker-compose.yml 2>/dev/null; then
            db_type="PostgreSQL"
        elif grep -q 'mysql' /opt/docker-services/new-api/docker-compose.yml 2>/dev/null; then
            db_type="MySQL"
        fi
    fi

    overview_item "部署状态" "$service_state"
    overview_item "数据库" "$db_type"
    overview_item "凭据文件" "$credentials_file"
    overview_item "Nginx 配置" "$nginx_conf"
    overview_item "服务目录" "/opt/docker-services/new-api"
}

show_pi_overview() {
    local pi_path pi_version
    pi_path=$(command -v pi 2>/dev/null || echo "未安装")
    pi_version="未安装"
    if command -v pi &>/dev/null; then
        pi_version=$(pi --version 2>/dev/null || pi -v 2>/dev/null || echo "已安装，版本未知")
    fi

    overview_item "命令路径" "$pi_path"
    overview_item "版本" "$pi_version"
    overview_item "用途" "终端 AI 编程助手"
}

show_selected_service_overview() {
    local svc installed action confirm_default
    svc=$(selected_service_id) || return 1
    installed="未安装"
    action="安装"
    confirm_default="y"
    if [ "${ALREADY_INSTALLED[$svc]:-}" = "true" ]; then
        installed="已安装"
        action="强制覆盖/重新安装"
        confirm_default="n"
    fi

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║            🔎 服务概览               ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}${SVC_NAME[$svc]}${NC} ${DIM}— ${SVC_DESC[$svc]}${NC}"
    echo ""
    overview_table_begin
    overview_item "当前状态" "$installed"

    case "$svc" in
        "$SVC_MAINTENANCE") show_maintenance_overview ;;
        "$SVC_NGINX")       show_nginx_overview ;;
        "$SVC_DOCKER")      show_docker_overview ;;
        "$SVC_CLIPROXY")    show_cliproxy_overview ;;
        "$SVC_NEWAPI")      show_newapi_overview ;;
        "$SVC_PI")          show_pi_overview ;;
    esac
    overview_table_end

    echo ""
    if [ "${ALREADY_INSTALLED[$svc]:-}" = "true" ]; then
        echo -e "${YELLOW}该服务已安装，继续将执行强制覆盖/重新安装。${NC}"
    fi

    if confirm "是否继续${action} ${SVC_NAME[$svc]}？" "$confirm_default"; then
        if [ "${ALREADY_INSTALLED[$svc]:-}" = "true" ]; then
            FORCE_INSTALL[$svc]=true
        fi
        echo ""
        return 0
    fi

    echo ""
    log_info "已取消本次选择，返回首页。"
    return 1
}

# ==================== 部署方式选择 ====================

configure_deployment_modes() {
    if [ "${TO_INSTALL[$SVC_CLIPROXY]:-}" != "true" ]; then
        CLIPROXY_DEPLOY_MODE="docker"
        SVC_DEPENDS[$SVC_CLIPROXY]="$SVC_NGINX $SVC_DOCKER"
        return
    fi

    if [ -n "${HONGAIBOX_CLIPROXY_DEPLOY_MODE:-}" ]; then
        case "${HONGAIBOX_CLIPROXY_DEPLOY_MODE,,}" in
            docker|compose|docker-compose)
                CLIPROXY_DEPLOY_MODE="docker"
                ;;
            bare|binary|systemd|native|host)
                CLIPROXY_DEPLOY_MODE="bare"
                ;;
            *)
                log_error "未知 CliproxyAPI 部署方式: $HONGAIBOX_CLIPROXY_DEPLOY_MODE"
                log_info "可用值: docker / bare"
                exit 1
                ;;
        esac
    else
        echo -e "${CYAN}>>> CliproxyAPI 部署方式${NC}"
        echo ""
        echo "  1) Docker Compose（推荐，默认）— 镜像升级简单，配置/数据集中在 /opt/docker-services/cliproxyapi"
        echo "  2) 裸机二进制 + Systemd       — 低开销，适合只单独运行 CPA"
        echo ""

        while true; do
            read -r -p "请选择 [1/2，默认 1]: " deploy_choice
            deploy_choice="${deploy_choice:-1}"
            case "$deploy_choice" in
                1) CLIPROXY_DEPLOY_MODE="docker"; break ;;
                2) CLIPROXY_DEPLOY_MODE="bare"; break ;;
                *) echo -e "${YELLOW}无效选择，请重新输入${NC}" ;;
            esac
        done
        echo ""
    fi

    if [ "$CLIPROXY_DEPLOY_MODE" = "docker" ]; then
        SVC_DEPENDS[$SVC_CLIPROXY]="$SVC_NGINX $SVC_DOCKER"
    else
        SVC_DEPENDS[$SVC_CLIPROXY]="$SVC_NGINX"
    fi
}

# ==================== 依赖解析 ====================

resolve_deps() {
    INSTALL_ORDER=()
    local -A seen

    resolve_one() {
        local svc="$1"
        local include_self="${2:-false}"
        local dep

        if [ "${seen[$svc]:-}" = "1" ]; then
            return
        fi
        seen[$svc]=1

        # 依赖服务仅在未安装时自动补齐；已安装依赖不重复执行。
        for dep in ${SVC_DEPENDS[$svc]}; do
            if [ -n "$dep" ] && [ "${ALREADY_INSTALLED[$dep]:-}" != "true" ]; then
                resolve_one "$dep" true
            fi
        done

        if [ "$include_self" = true ] || [ "${ALREADY_INSTALLED[$svc]:-}" != "true" ]; then
            INSTALL_ORDER+=("$svc")
        fi
    }

    for svc in "${ALL_SERVICES[@]}"; do
        if [ "${TO_INSTALL[$svc]:-}" = "true" ]; then
            resolve_one "$svc" true
        fi
    done
}

# ==================== 是否需要访问模式配置 ====================

is_web_service() {
    case "$1" in
        "$SVC_CLIPROXY"|"$SVC_NEWAPI") return 0 ;;
        *) return 1 ;;
    esac
}

web_service_count() {
    local count=0
    local svc
    for svc in "${INSTALL_ORDER[@]}"; do
        if is_web_service "$svc" \
            && { [ "${ALREADY_INSTALLED[$svc]:-}" != "true" ] || [ "${FORCE_INSTALL[$svc]:-}" = "true" ]; }; then
            ((count+=1))
        fi
    done
    echo "$count"
}

needs_access_mode() {
    local svc
    for svc in "${INSTALL_ORDER[@]}"; do
        if is_web_service "$svc" \
            && { [ "${ALREADY_INSTALLED[$svc]:-}" != "true" ] || [ "${FORCE_INSTALL[$svc]:-}" = "true" ]; }; then
            return 0
        fi
    done
    return 1
}

# ==================== 全局配置：访问模式 ====================

configure_access_mode() {
    local web_count svc
    web_count=$(web_service_count)

    echo ""
    echo -e "${CYAN}>>> 配置访问方式${NC}"
    echo ""

    if [ "$web_count" -gt 1 ]; then
        ACCESS_MODE="domain"
        echo -e "${YELLOW}检测到多个 Web 服务。为避免 Nginx 配置互相覆盖，必须为每个服务配置独立域名。${NC}"
        echo -e "${DIM}例如: cliproxy.example.com 与 newapi.example.com${NC}"
        echo ""
    else
        echo "  1) 使用域名（推荐） — 自动申请 Let's Encrypt 免费证书"
        echo "  2) 使用 IP 地址       — 自签名证书，无需域名"
        echo "  3) 仅使用 HTTP       — 无 SSL 证书，仅限内网/开发环境"
        echo ""

        while true; do
            read -r -p "请选择 [1/2/3]: " choice
            case "$choice" in
                1) ACCESS_MODE="domain"; break ;;
                2) ACCESS_MODE="ip"; break ;;
                3) ACCESS_MODE="http"; break ;;
                *) echo -e "${YELLOW}无效选择，请重新输入${NC}" ;;
            esac
        done
    fi

    case "$ACCESS_MODE" in
        domain)
            echo ""
            local svc domain existing_svc duplicate
            for svc in "${INSTALL_ORDER[@]}"; do
                if ! is_web_service "$svc" \
                    || { [ "${ALREADY_INSTALLED[$svc]:-}" = "true" ] && [ "${FORCE_INSTALL[$svc]:-}" != "true" ]; }; then
                    continue
                fi

                while true; do
                    read -r -p "请输入 ${SVC_NAME[$svc]} 域名 (例如 ${svc}.example.com): " domain
                    if ! validate_domain "$domain"; then
                        continue
                    fi

                    duplicate=false
                    for existing_svc in "${!SERVICE_DOMAIN[@]}"; do
                        if [ "${SERVICE_DOMAIN[$existing_svc]}" = "$domain" ]; then
                            duplicate=true
                            break
                        fi
                    done

                    if [ "$duplicate" = true ]; then
                        log_error "域名已被其他服务使用，请为每个 Web 服务使用独立域名。"
                        continue
                    fi

                    SERVICE_DOMAIN[$svc]="$domain"
                    break
                done
            done
            ;;
        ip|http)
            DOMAIN="$(detect_server_ip)"
            if [ -z "$DOMAIN" ] || ! validate_ip "$DOMAIN"; then
                echo ""
                while true; do
                    read -r -p "无法自动获取有效公网 IP，请手动输入: " DOMAIN
                    validate_ip "$DOMAIN" && break
                done
            fi

            if [ "$ACCESS_MODE" = "http" ]; then
                echo ""
                echo -e "${YELLOW}⚠️  HTTP 模式警告：数据传输不加密，API Key 可能泄露${NC}"
                echo -e "${YELLOW}   仅建议在内网或开发环境使用${NC}"
            fi

            echo ""
            echo -e "服务器 IP: ${GREEN}$DOMAIN${NC}"
            read -r -p "确认使用此 IP？(Y/n): " confirm_ip
            case "$confirm_ip" in
                [Nn])
                    while true; do
                        read -r -p "请输入 IP 地址: " DOMAIN
                        validate_ip "$DOMAIN" && break
                    done
                    ;;
            esac

            local single_svc=""
            for svc in "${INSTALL_ORDER[@]}"; do
                if is_web_service "$svc" \
                    && { [ "${ALREADY_INSTALLED[$svc]:-}" != "true" ] || [ "${FORCE_INSTALL[$svc]:-}" = "true" ]; }; then
                    single_svc="$svc"
                    break
                fi
            done
            [ -n "$single_svc" ] && SERVICE_DOMAIN[$single_svc]="$DOMAIN"
            ;;
    esac
}

# ==================== 服务级配置 ====================

configure_service() {
    local svc="$1"

    case "$svc" in
        "$SVC_CLIPROXY")
            echo ""
            echo -e "${CYAN}>>> CliproxyAPI 管理面板密码${NC}"
            echo "  留空将自动生成随机密码"
            echo ""
            read -r -p "管理密码 (留空=自动生成): " ADMIN_PASSWORD
            if [ -n "$ADMIN_PASSWORD" ]; then
                echo -e "${GREEN}已设置自定义密码${NC}"
            else
                echo -e "${DIM}将在安装时自动生成${NC}"
            fi
            ;;
        "$SVC_NEWAPI")
            echo ""
            echo -e "${CYAN}>>> New-API 数据库类型${NC}"
            echo "  1) PostgreSQL（推荐）"
            echo "  2) MySQL"
            echo ""
            while true; do
                read -r -p "请选择 [1/2]: " db_choice
                case "$db_choice" in
                    1) DB_TYPE="postgresql"; break ;;
                    2) DB_TYPE="mysql"; break ;;
                    *) echo -e "${YELLOW}无效选择${NC}" ;;
                esac
            done
            ;;
    esac
}

collect_service_configs() {
    for svc in "${INSTALL_ORDER[@]}"; do
        case "$svc" in
            "$SVC_CLIPROXY"|"$SVC_NEWAPI")
                configure_service "$svc"
                ;;
        esac
    done
}

# ==================== 确认总览 ====================

show_review() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║            📋 配置总览               ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""

    if needs_access_mode; then
        echo -e "${BOLD}全局配置:${NC}"
        case "$ACCESS_MODE" in
            domain) echo -e "  访问模式: ${GREEN}域名（Let's Encrypt）${NC}" ;;
            ip)     echo -e "  访问模式: ${GREEN}IP（自签名证书）${NC}" ;;
            http)   echo -e "  访问模式: ${GREEN}HTTP（无 SSL）${NC}" ;;
        esac

        local svc
        if [ "$ACCESS_MODE" = "domain" ]; then
            for svc in "${INSTALL_ORDER[@]}"; do
                if is_web_service "$svc" && [ -n "${SERVICE_DOMAIN[$svc]:-}" ]; then
                    echo -e "  ${SVC_NAME[$svc]}: ${GREEN}${SERVICE_DOMAIN[$svc]}${NC}"
                fi
            done
        else
            echo -e "  IP:       ${GREEN}$DOMAIN${NC}"
        fi
        echo ""
    fi

    echo -e "${BOLD}待安装服务 (${#INSTALL_ORDER[@]} 个):${NC}"
    echo ""

    for svc in "${INSTALL_ORDER[@]}"; do
        local short_name desc extra=""
        short_name=$(service_short_name "$svc")
        desc="${SVC_DESC[$svc]}"

        case "$svc" in
            "$SVC_CLIPROXY")
                if [ "$CLIPROXY_DEPLOY_MODE" = "docker" ]; then
                    extra="部署: Docker Compose"
                else
                    extra="部署: 裸机 Systemd"
                fi
                if [ -n "$ADMIN_PASSWORD" ]; then
                    extra="$extra，管理密码: 已设置"
                else
                    extra="$extra，管理密码: 自动生成"
                fi
                ;;
            "$SVC_NEWAPI")
                local db_label="PostgreSQL"
                [ "$DB_TYPE" = "mysql" ] && db_label="MySQL"
                extra="数据库: $db_label"
                ;;
        esac

        if [ "${FORCE_INSTALL[$svc]:-}" = "true" ]; then
            if [ -n "$extra" ]; then
                extra="强制覆盖安装，$extra"
            else
                extra="强制覆盖安装"
            fi
        fi

        printf "  ${GREEN}✓ %-14s${NC} ${DIM}— %s${NC}" "$short_name" "$desc"
        if [ -n "$extra" ]; then
            printf " ${YELLOW}(%s)${NC}" "$extra"
        fi
        printf "\n"
    done

    echo ""
    echo -e "${YELLOW}按 Enter 确认并开始安装 | 输入 n 取消${NC}"
    echo ""

    read -r -p "确认? [Y/n]: " confirm
    case "$confirm" in
        [Nn]) echo ""; log_info "部署已取消。"; exit 0 ;;
    esac
}

# ==================== 安装执行 ====================

run_install() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         🚀 正在安装服务...           ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""

    local total=${#INSTALL_ORDER[@]}
    local current=0

    for svc in "${INSTALL_ORDER[@]}"; do
        ((current+=1))
        local script="${SVC_SCRIPT[$svc]}"
        local name="${SVC_NAME[$svc]}"

        print_section "[$current/$total] 安装 $name"

        local dep dep_failed=false
        for dep in ${SVC_DEPENDS[$svc]}; do
            if [ "${INSTALL_FAILED[$dep]:-}" = "true" ]; then
                dep_failed=true
                break
            fi
        done
        if [ "$dep_failed" = true ]; then
            log_error "$name 依赖安装失败，已跳过"
            INSTALL_RESULTS+=("✗ $name — 依赖失败，已跳过")
            INSTALL_FAILED[$svc]=true
            FAILED=1
            echo ""
            continue
        fi

        if [ ! -f "$script" ]; then
            log_error "安装脚本不存在: $script"
            INSTALL_RESULTS+=("✗ $name — 脚本缺失")
            INSTALL_FAILED[$svc]=true
            FAILED=1
            continue
        fi

        chmod +x "$script"

        # Build env vars
        local -a extra_env=()
        extra_env+=("HONGAIBOX_UNATTENDED=1")

        local svc_domain="${SERVICE_DOMAIN[$svc]:-}"
        if is_web_service "$svc"; then
            [ -n "$ACCESS_MODE" ] && extra_env+=("HONGAIBOX_ACCESS_MODE=$ACCESS_MODE")
            [ -z "$svc_domain" ] && svc_domain="$DOMAIN"
            [ -n "$svc_domain" ] && extra_env+=("HONGAIBOX_DOMAIN=$svc_domain")
        fi

        case "$svc" in
            "$SVC_CLIPROXY")
                extra_env+=("HONGAIBOX_CLIPROXY_DEPLOY_MODE=$CLIPROXY_DEPLOY_MODE")
                [ -n "$ADMIN_PASSWORD" ] && extra_env+=("HONGAIBOX_ADMIN_PASSWORD=$ADMIN_PASSWORD")
                ;;
            "$SVC_NEWAPI")
                extra_env+=("HONGAIBOX_DB_TYPE=$DB_TYPE")
                ;;
            "$SVC_PI")
                extra_env+=("HONGAIBOX_NO_PROMPT=1")
                ;;
        esac

        # Component install.sh owns idempotency/repair/skip behavior.
        # The root installer only resolves order and passes collected config.
        # Execute component install.sh directly (not via 'bash') to preserve $0
        # for scripts that use BASH_SOURCE==$0 guards.
        if env "${extra_env[@]}" "$script"; then
            log_success "$name 安装成功"
            INSTALL_RESULTS+=("✓ $name")
            ALREADY_INSTALLED[$svc]=true
        else
            log_error "$name 安装失败"
            INSTALL_RESULTS+=("✗ $name — 失败")
            INSTALL_FAILED[$svc]=true
            FAILED=1
        fi

        echo ""
    done
}

# ==================== 总结 ====================

print_summary() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         部署完成总结                 ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""

    for result in "${INSTALL_RESULTS[@]}"; do
        if [[ "$result" == ✓* ]]; then
            echo -e "  ${GREEN}$result${NC}"
        else
            echo -e "  ${RED}$result${NC}"
        fi
    done

    echo ""
    print_divider
    echo ""
    echo -e "${WHITE}常用管理命令:${NC}"
    echo ""

    for svc in "${INSTALL_ORDER[@]}"; do
        case "$svc" in
            "$SVC_MAINTENANCE")
                echo "  Maintenance:"
                echo "    fail2ban-client status sshd  |  swapon --show"
                echo "    journalctl --disk-usage"
                echo ""
                ;;
            "$SVC_NGINX")
                echo "  Nginx:"
                echo "    systemctl status nginx  |  nginx -t  |  systemctl reload nginx"
                echo ""
                ;;
            "$SVC_DOCKER")
                echo "  Docker:"
                echo "    docker info  |  docker compose version"
                echo ""
                ;;
            "$SVC_NEWAPI")
                echo "  New-API:"
                echo "    cd /opt/docker-services/new-api && docker compose ps"
                echo "    docker compose logs -f new-api"
                echo ""
                ;;
            "$SVC_CLIPROXY")
                echo "  CliproxyAPI:"
                if [ "$CLIPROXY_DEPLOY_MODE" = "docker" ]; then
                    echo "    cd /opt/docker-services/cliproxyapi && docker compose ps"
                    echo "    docker compose logs -f cliproxyapi"
                else
                    echo "    systemctl status cliproxyapi"
                    echo "    journalctl -u cliproxyapi -f"
                fi
                echo ""
                ;;
            "$SVC_PI")
                echo "  Pi:"
                echo "    pi --help  |  pi -p \"你的问题\""
                echo ""
                ;;
        esac
    done

    print_divider
    echo ""
    echo -e "${CYAN}感谢使用洪哥的 AI 工具箱 v${VERSION}！${NC}"
    echo -e "${DIM}日志文件: $DEPLOY_LOG_FILE${NC}"
    echo ""
}

# ==================== AI/CLI 子命令 ====================

cli_usage() {
    cat <<EOF
HongBox v${VERSION} — AI-native server deployment toolkit

用法:
  ./install.sh plan --services new-api --domain api.example.com
  ./install.sh preflight --profile deploy.env
  sudo ./install.sh apply --profile deploy.env --yes
  ./install.sh status [--services all|new-api,cliproxyapi]
  ./install.sh doctor [--profile deploy.env]

通用参数:
  --profile FILE                  读取 .env 风格部署配置
  --services LIST                 逗号分隔服务: maintenance,nginx,docker,cliproxyapi,new-api,pi
  --access-mode MODE              domain | ip | http
  --domain VALUE                  单个 Web 服务域名/IP
  --cliproxy-domain VALUE         CliproxyAPI 专用域名
  --newapi-domain VALUE           New-API 专用域名
  --cliproxy-mode MODE            docker | bare
  --db-type TYPE                  postgresql | mysql
  --admin-password VALUE          CliproxyAPI 管理密码；省略则自动生成
  --yes                           apply 时确认执行计划

Profile 示例:
  HONGBOX_SERVICES="maintenance,nginx,docker,new-api"
  HONGBOX_ACCESS_MODE="domain"
  HONGBOX_NEWAPI_DOMAIN="api.example.com"
  HONGBOX_DB_TYPE="postgresql"
  HONGBOX_CONFIRM_APPLY="yes"

说明:
  plan/preflight/status/doctor 不执行安装。apply 只接受明确参数或 profile，
  并且需要 --yes 或 HONGBOX_CONFIRM_APPLY=yes 才会真正修改系统。
EOF
}

trim_value() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

normalize_service_id() {
    local svc
    svc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    svc="${svc//_/-}"
    case "$svc" in
        all) echo "all" ;;
        maintenance|maint|baseline) echo "$SVC_MAINTENANCE" ;;
        nginx) echo "$SVC_NGINX" ;;
        docker|compose) echo "$SVC_DOCKER" ;;
        cliproxy|cliproxyapi|cpa|cli-proxy-api) echo "$SVC_CLIPROXY" ;;
        newapi|new-api) echo "$SVC_NEWAPI" ;;
        pi|pi-coding-agent|coding-agent) echo "$SVC_PI" ;;
        *)
            echo "未知服务: $1" >&2
            return 1
            ;;
    esac
}

service_env_prefix() {
    case "$1" in
        "$SVC_CLIPROXY") echo "CLIPROXY" ;;
        "$SVC_NEWAPI")   echo "NEWAPI" ;;
        *)               echo "" ;;
    esac
}

load_profile_file() {
    local profile="$1"

    if [ ! -r "$profile" ]; then
        echo "[ERROR] profile 不存在或不可读: $profile" >&2
        exit 1
    fi

    set -a
    # shellcheck source=/dev/null
    . "$profile"
    set +a
}

CLI_COMMAND=""
CLI_PROFILE=""
CLI_SERVICES="${HONGBOX_SERVICES:-${HONGAIBOX_SERVICES:-}}"
CLI_ASSUME_YES=false
CLI_STATUS_SERVICES=""
CLI_CLIPROXY_DOMAIN="${HONGBOX_CLIPROXY_DOMAIN:-${HONGAIBOX_CLIPROXY_DOMAIN:-}}"
CLI_NEWAPI_DOMAIN="${HONGBOX_NEWAPI_DOMAIN:-${HONGAIBOX_NEWAPI_DOMAIN:-}}"

parse_cli_args() {
    CLI_COMMAND="$1"
    shift || true

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                cli_usage
                exit 0
                ;;
            --profile)
                CLI_PROFILE="${2:-}"
                shift 2
                ;;
            --services|--service)
                CLI_SERVICES="${2:-}"
                CLI_STATUS_SERVICES="$CLI_SERVICES"
                shift 2
                ;;
            --access-mode)
                ACCESS_MODE="${2:-}"
                shift 2
                ;;
            --domain)
                DOMAIN="${2:-}"
                shift 2
                ;;
            --cliproxy-domain)
                CLI_CLIPROXY_DOMAIN="${2:-}"
                shift 2
                ;;
            --newapi-domain|--new-api-domain)
                CLI_NEWAPI_DOMAIN="${2:-}"
                shift 2
                ;;
            --cliproxy-mode)
                CLIPROXY_DEPLOY_MODE="${2:-}"
                shift 2
                ;;
            --db-type)
                DB_TYPE="${2:-}"
                shift 2
                ;;
            --admin-password)
                ADMIN_PASSWORD="${2:-}"
                shift 2
                ;;
            --yes|-y)
                CLI_ASSUME_YES=true
                shift
                ;;
            *)
                echo "[ERROR] 未知参数: $1" >&2
                cli_usage >&2
                exit 1
                ;;
        esac
    done

    if [ -n "$CLI_PROFILE" ]; then
        load_profile_file "$CLI_PROFILE"
    fi

    CLI_SERVICES="${CLI_SERVICES:-${HONGBOX_SERVICES:-${HONGAIBOX_SERVICES:-}}}"
    ACCESS_MODE="${ACCESS_MODE:-${HONGBOX_ACCESS_MODE:-${HONGAIBOX_ACCESS_MODE:-}}}"
    DOMAIN="${DOMAIN:-${HONGBOX_DOMAIN:-${HONGAIBOX_DOMAIN:-}}}"
    CLIPROXY_DEPLOY_MODE="${CLIPROXY_DEPLOY_MODE:-${HONGBOX_CLIPROXY_MODE:-${HONGAIBOX_CLIPROXY_DEPLOY_MODE:-docker}}}"
    DB_TYPE="${DB_TYPE:-${HONGBOX_DB_TYPE:-${HONGAIBOX_DB_TYPE:-postgresql}}}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-${HONGBOX_ADMIN_PASSWORD:-${HONGAIBOX_ADMIN_PASSWORD:-}}}"
    CLI_CLIPROXY_DOMAIN="${CLI_CLIPROXY_DOMAIN:-${HONGBOX_CLIPROXY_DOMAIN:-${HONGAIBOX_CLIPROXY_DOMAIN:-}}}"
    CLI_NEWAPI_DOMAIN="${CLI_NEWAPI_DOMAIN:-${HONGBOX_NEWAPI_DOMAIN:-${HONGAIBOX_NEWAPI_DOMAIN:-}}}"

    if [ "${HONGBOX_CONFIRM_APPLY:-${HONGAIBOX_CONFIRM_APPLY:-}}" = "yes" ]; then
        CLI_ASSUME_YES=true
    fi
}

select_cli_services() {
    local raw="$1"
    local item svc

    if [ -z "$raw" ]; then
        echo "[ERROR] 缺少服务列表。请使用 --services 或在 profile 中设置 HONGBOX_SERVICES。" >&2
        exit 1
    fi

    raw="${raw// /}"
    IFS=',' read -r -a requested_services <<< "$raw"

    for item in "${requested_services[@]}"; do
        [ -z "$item" ] && continue
        svc="$(normalize_service_id "$item")" || exit 1
        if [ "$svc" = "all" ]; then
            for svc in "${ALL_SERVICES[@]}"; do
                TO_INSTALL[$svc]=true
            done
            return 0
        fi
        TO_INSTALL[$svc]=true
    done
}

validate_cli_config() {
    local svc web_count=0

    case "$ACCESS_MODE" in
        ""|domain|ip|http) ;;
        *)
            echo "[ERROR] --access-mode 只能是 domain、ip 或 http，当前: $ACCESS_MODE" >&2
            exit 1
            ;;
    esac

    case "$CLIPROXY_DEPLOY_MODE" in
        docker|compose|docker-compose) CLIPROXY_DEPLOY_MODE="docker" ;;
        bare|binary|systemd|native|host) CLIPROXY_DEPLOY_MODE="bare" ;;
        *)
            echo "[ERROR] --cliproxy-mode 只能是 docker 或 bare，当前: $CLIPROXY_DEPLOY_MODE" >&2
            exit 1
            ;;
    esac

    case "$DB_TYPE" in
        postgresql|postgres|pg) DB_TYPE="postgresql" ;;
        mysql) DB_TYPE="mysql" ;;
        *)
            echo "[ERROR] --db-type 只能是 postgresql 或 mysql，当前: $DB_TYPE" >&2
            exit 1
            ;;
    esac

    if [ "${TO_INSTALL[$SVC_CLIPROXY]:-}" = "true" ] && [ -n "$CLI_CLIPROXY_DOMAIN" ]; then
        SERVICE_DOMAIN[$SVC_CLIPROXY]="$CLI_CLIPROXY_DOMAIN"
    fi
    if [ "${TO_INSTALL[$SVC_NEWAPI]:-}" = "true" ] && [ -n "$CLI_NEWAPI_DOMAIN" ]; then
        SERVICE_DOMAIN[$SVC_NEWAPI]="$CLI_NEWAPI_DOMAIN"
    fi

    for svc in "${ALL_SERVICES[@]}"; do
        if [ "${TO_INSTALL[$svc]:-}" = "true" ] && is_web_service "$svc"; then
            web_count=$((web_count + 1))
        fi
    done

    if [ "$web_count" -gt 0 ] && [ -z "$ACCESS_MODE" ]; then
        ACCESS_MODE="domain"
    fi

    if [ "$web_count" -eq 1 ] && [ -n "$DOMAIN" ]; then
        for svc in "$SVC_CLIPROXY" "$SVC_NEWAPI"; do
            if [ "${TO_INSTALL[$svc]:-}" = "true" ] && [ -z "${SERVICE_DOMAIN[$svc]:-}" ]; then
                SERVICE_DOMAIN[$svc]="$DOMAIN"
            fi
        done
    fi

    if [ "$web_count" -gt 1 ] && [ "$ACCESS_MODE" != "domain" ]; then
        echo "[ERROR] 同时部署多个 Web 服务时必须使用 domain 模式并为每个服务提供独立域名。" >&2
        exit 1
    fi

    for svc in "${ALL_SERVICES[@]}"; do
        if [ "${TO_INSTALL[$svc]:-}" != "true" ] || ! is_web_service "$svc"; then
            continue
        fi

        if [ "$ACCESS_MODE" = "domain" ] && [ -z "${SERVICE_DOMAIN[$svc]:-}" ]; then
            echo "[ERROR] 缺少 ${SVC_NAME[$svc]} 域名。请提供 --domain、--$(service_env_prefix "$svc" | tr '[:upper:]' '[:lower:]')-domain 或 profile 变量。" >&2
            exit 1
        fi

        if [ "$ACCESS_MODE" = "domain" ]; then
            validate_domain "${SERVICE_DOMAIN[$svc]}" >/dev/null || exit 1
        elif [ "$ACCESS_MODE" = "ip" ] || [ "$ACCESS_MODE" = "http" ]; then
            if [ -z "${SERVICE_DOMAIN[$svc]:-}" ]; then
                SERVICE_DOMAIN[$svc]="$(detect_server_ip)"
            fi
            validate_ip "${SERVICE_DOMAIN[$svc]}" >/dev/null || exit 1
        fi
    done
}

prepare_cli_plan() {
    reset_iteration_state
    parse_cli_args "$@"
    detect_installed_services
    select_cli_services "$CLI_SERVICES"
    validate_cli_config
    HONGAIBOX_CLIPROXY_DEPLOY_MODE="$CLIPROXY_DEPLOY_MODE"
    configure_deployment_modes
    resolve_deps
}

print_cli_plan() {
    local svc dep domain_value

    echo "HongBox deployment plan"
    echo "Version: v${VERSION}"
    echo "Profile: ${CLI_PROFILE:-inline arguments/env}"
    echo ""
    echo "Requested services:"
    for svc in "${ALL_SERVICES[@]}"; do
        if [ "${TO_INSTALL[$svc]:-}" = "true" ]; then
            echo "  - $(service_short_name "$svc"): ${SVC_DESC[$svc]}"
        fi
    done

    echo ""
    echo "Install order:"
    if [ "${#INSTALL_ORDER[@]}" -eq 0 ]; then
        echo "  - Nothing to install"
    else
        for svc in "${INSTALL_ORDER[@]}"; do
            dep="${SVC_DEPENDS[$svc]}"
            [ -z "$dep" ] && dep="none"
            echo "  - $(service_short_name "$svc")"
            echo "    status: ${ALREADY_INSTALLED[$svc]:-false}"
            echo "    script: ${SVC_SCRIPT[$svc]}"
            echo "    dependencies: $dep"
            if is_web_service "$svc"; then
                domain_value="${SERVICE_DOMAIN[$svc]:-}"
                echo "    access_mode: ${ACCESS_MODE:-none}"
                echo "    endpoint: ${domain_value:-not set}"
            fi
            case "$svc" in
                "$SVC_CLIPROXY")
                    echo "    deploy_mode: $CLIPROXY_DEPLOY_MODE"
                    if [ -n "$ADMIN_PASSWORD" ]; then
                        echo "    admin_password: provided (hidden)"
                    else
                        echo "    admin_password: auto-generated"
                    fi
                    ;;
                "$SVC_NEWAPI")
                    echo "    database: $DB_TYPE"
                    ;;
            esac
        done
    fi

    echo ""
    echo "System changes expected:"
    echo "  - May install OS packages and enable systemd services"
    echo "  - May write files under /opt, /etc/nginx, /etc/docker, /var/log/vps-deploy, /var/lib/hongaibox"
    echo "  - Nginx configs are backed up before overwrite where supported"
    echo "  - Secret values are written to credential files and are not printed"
}

report_check() {
    local status="$1"
    local label="$2"
    local detail="${3:-}"
    printf '  [%s] %s' "$status" "$label"
    [ -n "$detail" ] && printf ' — %s' "$detail"
    printf '\n'
}

run_preflight_checks() {
    local failures=0 warnings=0 svc domain_value server_ip resolved_ips required
    local os arch

    os="$(detect_os)"
    arch="$(detect_arch)"
    echo "HongBox preflight"
    echo ""

    case "$os" in
        debian|ubuntu)
            report_check "ok" "OS" "$os"
            ;;
        *)
            report_check "fail" "OS" "$os is not a supported target"
            failures=$((failures + 1))
            ;;
    esac

    case "$arch" in
        linux_amd64|linux_arm64) report_check "ok" "Architecture" "$arch" ;;
        *)
            report_check "warn" "Architecture" "$arch"
            warnings=$((warnings + 1))
            ;;
    esac

    if [ "$EUID" -eq 0 ]; then
        report_check "ok" "Root privileges"
    else
        report_check "warn" "Root privileges" "apply must run with sudo/root"
        warnings=$((warnings + 1))
    fi

    for required in bash sed awk grep find xargs; do
        if command -v "$required" >/dev/null 2>&1; then
            report_check "ok" "Command $required"
        else
            report_check "fail" "Command $required" "missing"
            failures=$((failures + 1))
        fi
    done

    if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
        report_check "ok" "Downloader" "curl/wget available"
    else
        report_check "fail" "Downloader" "curl or wget required"
        failures=$((failures + 1))
    fi

    for svc in "${INSTALL_ORDER[@]}"; do
        if [ ! -x "${SVC_SCRIPT[$svc]}" ]; then
            if [ -f "${SVC_SCRIPT[$svc]}" ]; then
                report_check "warn" "$(service_short_name "$svc") script" "not executable; apply will chmod +x"
                warnings=$((warnings + 1))
            else
                report_check "fail" "$(service_short_name "$svc") script" "missing: ${SVC_SCRIPT[$svc]}"
                failures=$((failures + 1))
            fi
        else
            report_check "ok" "$(service_short_name "$svc") script" "${SVC_SCRIPT[$svc]}"
        fi
    done

    if needs_access_mode; then
        server_ip="$(detect_server_ip)"
        [ -n "$server_ip" ] && report_check "ok" "Detected server IP" "$server_ip" || report_check "warn" "Detected server IP" "not available"
        if [ -z "$server_ip" ]; then
            warnings=$((warnings + 1))
        fi

        for svc in "${INSTALL_ORDER[@]}"; do
            if ! is_web_service "$svc"; then
                continue
            fi
            domain_value="${SERVICE_DOMAIN[$svc]:-}"
            [ -z "$domain_value" ] && continue

            if [ "$ACCESS_MODE" = "domain" ]; then
                resolved_ips="$(getent ahosts "$domain_value" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, - || true)"
                if [ -z "$resolved_ips" ]; then
                    report_check "warn" "DNS $domain_value" "no A/AAAA records found from this host"
                    warnings=$((warnings + 1))
                elif [ -n "$server_ip" ] && ! printf '%s\n' "$resolved_ips" | tr ',' '\n' | grep -qx "$server_ip"; then
                    report_check "warn" "DNS $domain_value" "resolves to $resolved_ips, detected server IP is $server_ip"
                    warnings=$((warnings + 1))
                else
                    report_check "ok" "DNS $domain_value" "$resolved_ips"
                fi
            fi
        done

        for required in 80 443; do
            if check_port_available "$required"; then
                report_check "ok" "Port $required" "available"
            else
                report_check "warn" "Port $required" "currently in use; this can be normal if Nginx is already installed"
                warnings=$((warnings + 1))
            fi
        done
    fi

    echo ""
    echo "Preflight summary: $failures failure(s), $warnings warning(s)"
    [ "$failures" -eq 0 ]
}

print_cli_status() {
    local svc selected_filter="$1"

    detect_installed_services
    echo "HongBox status"
    echo ""
    printf '%-16s %-10s %s\n' "Service" "Installed" "Details"
    printf '%-16s %-10s %s\n' "-------" "---------" "-------"
    for svc in "${ALL_SERVICES[@]}"; do
        if [ -n "$selected_filter" ] && [ "$selected_filter" != "all" ] && ! [[ ",$selected_filter," == *",$svc,"* ]]; then
            continue
        fi
        printf '%-16s %-10s ' "$(service_short_name "$svc")" "${ALREADY_INSTALLED[$svc]:-false}"
        case "$svc" in
            "$SVC_MAINTENANCE") echo "marker: $([ -f /var/lib/hongaibox/maintenance.installed ] && echo present || echo missing)" ;;
            "$SVC_NGINX")       echo "$(nginx -v 2>&1 | sed 's/^nginx version: //' || echo unavailable)" ;;
            "$SVC_DOCKER")      echo "$(docker --version 2>/dev/null || echo unavailable)" ;;
            "$SVC_CLIPROXY")    echo "$(compose_running_text /opt/docker-services/cliproxyapi)" ;;
            "$SVC_NEWAPI")      echo "$(compose_running_text /opt/docker-services/new-api)" ;;
            "$SVC_PI")          echo "$(command -v pi 2>/dev/null || echo unavailable)" ;;
        esac
    done
}

run_cli_command() {
    local command="$1"
    shift || true

    case "$command" in
        help)
            cli_usage
            ;;
        plan)
            prepare_cli_plan "$command" "$@"
            print_cli_plan
            ;;
        preflight)
            prepare_cli_plan "$command" "$@"
            print_cli_plan
            echo ""
            run_preflight_checks
            ;;
        apply)
            prepare_cli_plan "$command" "$@"
            if [ "$CLI_ASSUME_YES" != "true" ]; then
                print_cli_plan
                echo ""
                echo "[ERROR] apply 需要显式确认。请在人工确认计划后追加 --yes，或设置 HONGBOX_CONFIRM_APPLY=yes。" >&2
                exit 1
            fi
            check_root
            setup_logging "hongbox"
            print_cli_plan
            echo ""
            run_preflight_checks
            echo ""
            run_install
            print_summary
            exit "$FAILED"
            ;;
        status)
            parse_cli_args "$command" "$@"
            local status_filter="" normalized item
            if [ -n "${CLI_STATUS_SERVICES:-$CLI_SERVICES}" ]; then
                local raw_services="${CLI_STATUS_SERVICES:-$CLI_SERVICES}"
                raw_services="${raw_services// /}"
                IFS=',' read -r -a status_items <<< "$raw_services"
                for item in "${status_items[@]}"; do
                    normalized="$(normalize_service_id "$item")" || exit 1
                    if [ "$normalized" = "all" ]; then
                        status_filter="all"
                        break
                    fi
                    status_filter="${status_filter}${status_filter:+,}${normalized}"
                done
            fi
            print_cli_status "$status_filter"
            ;;
        doctor)
            parse_cli_args "$command" "$@"
            if [ -z "${CLI_SERVICES:-}" ]; then
                print_cli_status "all"
                exit 0
            fi
            prepare_cli_plan "$command" "$@"
            print_cli_status "all"
            echo ""
            run_preflight_checks
            ;;
        *)
            echo "[ERROR] 未知命令: $command" >&2
            cli_usage >&2
            exit 1
            ;;
    esac
}

# ==================== 主流程 ====================

main() {
    check_root
    setup_logging "hongaibox"

    while true; do
        reset_iteration_state

        # ── Step 1: 检测 + 展示 ──
        detect_installed_services
        show_service_panel

        # ── Step 2: 选择服务 ──
        if ! select_services; then
            continue
        fi

        # ── Step 2.5: 服务概览 + 用户确认 ──
        if ! show_selected_service_overview; then
            continue
        fi

        # ── Step 3: 部署方式 + 依赖解析 ──
        configure_deployment_modes
        resolve_deps

        # ── Step 4: 全局配置 ──
        if needs_access_mode; then
            configure_access_mode
        fi

        # ── Step 5: 服务级配置 ──
        collect_service_configs

        # ── Step 6: 确认 ──
        show_review

        # ── Step 7: 安装 ──
        run_install

        # ── Step 8: 总结 ──
        print_summary

        local round_failed="$FAILED"
        if [ "$round_failed" -ne 0 ]; then
            log_error "部分服务安装失败，请根据上方日志排查。"
        fi

        if ! prompt_return_home; then
            if [ "$round_failed" -ne 0 ]; then
                exit 1
            fi
            exit 0
        fi
    done
}

# ==================== 执行 ====================
case "${1:-}" in
    plan|preflight|apply|status|doctor|help)
        run_cli_command "$@"
        ;;
    *)
        if [ "$#" -eq 0 ]; then
            cli_usage
            exit 0
        fi
        echo "[ERROR] 未知命令: $1" >&2
        cli_usage >&2
        exit 1
        ;;
esac
