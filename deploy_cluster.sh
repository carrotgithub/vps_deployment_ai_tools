#!/bin/bash

################################################################################
#
# VPS 集群全流程部署引导脚本
#
# 功能说明：
#   按顺序引导用户选择并安装 VPS 集群各组件，自动处理依赖关系
#
# 使用方法：
#   chmod +x deploy_cluster.sh
#   ./deploy_cluster.sh
#
# 依赖关系：
#   0.nginx     → 必选（所有服务的基础）
#   01.docker   → 推荐（Docker 容器服务的前置依赖）
#   1-3 服务    → 可选（独立服务）
#   8.监控      → 可选（独立服务）
#
################################################################################

# ==================== 颜色定义 ====================
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

# ==================== 全局变量 ====================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLED_SERVICES=()
NGINX_INSTALLED=false
DOCKER_INSTALLED=false
NEWAPI_INSTALLED=false
CLIPROXYAPI_INSTALLED=false

# ==================== 辅助函数 ====================

# 引入 Docker 安装脚本（提供 ensure_docker 函数）
DOCKER_INSTALLER="$SCRIPT_DIR/01.docker/install_docker.sh"
if [ -f "$DOCKER_INSTALLER" ]; then
    source "$DOCKER_INSTALLER"
fi

print_header() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                              ║"
    echo "║                    🚀 VPS 集群全流程部署引导工具                              ║"
    echo "║                                                                              ║"
    echo "║                         版本: v1.0  |  2026-01-16                            ║"
    echo "║                                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_divider() {
    echo -e "${DIM}────────────────────────────────────────────────────────────────────────────────${NC}"
}

print_section() {
    echo ""
    echo -e "${BOLD}${BLUE}▶ $1${NC}"
    print_divider
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"

    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    read -p "$prompt" response
    response=${response:-$default}

    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

wait_key() {
    echo ""
    read -p "按 Enter 键继续..." key
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 必须使用 root 权限运行此脚本。${NC}"
        echo -e "${YELLOW}请使用: sudo ./deploy_cluster.sh${NC}"
        exit 1
    fi
}

# ==================== 服务安装函数 ====================

install_nginx() {
    print_section "安装 Nginx 1.28.1 (HTTP/3)"

    echo -e "${WHITE}功能说明:${NC}"
    echo "  • Nginx 1.28.1 源码编译安装，支持最新的 HTTP/3 (QUIC) 协议"
    echo "  • 自动开启 TCP BBR 拥塞控制算法，提升网络性能 20-30%"
    echo "  • 优化系统内核参数，提升文件描述符限制"
    echo "  • 构建模块化配置结构 (conf.d/)，方便后续服务扩展"
    echo "  • 编译 Stream 模块，支持四层 TCP/UDP 负载均衡"
    echo ""
    echo -e "${YELLOW}⚠️  这是所有后续服务的基础组件，必须安装！${NC}"
    echo ""
    echo -e "${DIM}预计安装时间: 5-10 分钟（取决于服务器性能）${NC}"
    echo ""

    if confirm "是否开始安装 Nginx？" "y"; then
        echo ""
        cd "$SCRIPT_DIR/0.nginx"
        chmod +x install_nginx.sh
        ./install_nginx.sh

        if [ $? -eq 0 ]; then
            NGINX_INSTALLED=true
            INSTALLED_SERVICES+=("Nginx 1.28.1")
            echo ""
            echo -e "${GREEN}✓ Nginx 安装成功！${NC}"
        else
            echo -e "${RED}✗ Nginx 安装失败，请检查错误信息。${NC}"
            exit 1
        fi
    else
        echo -e "${RED}Nginx 是必选组件，无法跳过。${NC}"
        exit 1
    fi

    wait_key
}

install_docker() {
    print_section "安装 Docker 容器环境"

    echo -e "${WHITE}功能说明:${NC}"
    echo "  • Docker 是容器化服务（如 New-API）的运行环境"
    echo "  • 包含 Docker Engine 和 Docker Compose 插件"
    echo "  • 自动修复 apt 源问题，支持多种 Linux 发行版"
    echo ""
    echo -e "${YELLOW}⚠️  New-API 等 Docker 服务必须依赖此组件！${NC}"
    echo ""

    if confirm "是否安装 Docker？" "y"; then
        echo ""

        if ensure_docker; then
            DOCKER_INSTALLED=true
            INSTALLED_SERVICES+=("Docker")
            echo ""
            echo -e "${GREEN}✓ Docker 环境就绪！${NC}"
        else
            echo -e "${RED}✗ Docker 安装失败，后续 Docker 服务将无法安装。${NC}"
        fi
    else
        echo -e "${YELLOW}跳过 Docker 安装（后续 Docker 服务将无法安装）${NC}"
    fi

    wait_key
}

install_v2ray() {
    print_section "安装 V2Ray 代理节点"

    echo -e "${WHITE}功能说明:${NC}"
    echo "  • V2Ray 是一款功能强大的代理工具，用于科学上网"
    echo "  • 使用 WebSocket + TLS 传输，流量伪装为正常 HTTPS 请求"
    echo "  • 自动生成随机 UUID 和 WebSocket 路径，增强安全性"
    echo "  • 内置静态伪装网站，访问域名显示'系统维护'页面"
    echo ""
    echo -e "${CYAN}支持的访问模式:${NC}"
    echo "  • 域名模式：自动申请 Let's Encrypt 证书（推荐）"
    echo "  • IP 模式：使用自签名证书，无需域名"
    echo "  • HTTP 模式：无 SSL 证书，仅限内网/开发环境"
    echo ""
    echo -e "${CYAN}适用场景:${NC}"
    echo "  • 需要部署代理节点用于科学上网"
    echo "  • 希望流量伪装为正常网站访问"
    echo ""
    echo -e "${YELLOW}前置要求:${NC}"
    echo "  • 域名模式：需要一个已解析到本服务器的域名"
    echo "  • IP 模式：无需域名，客户端需开启 AllowInsecure"
    echo "  • HTTP 模式：无需域名或证书，但数据传输不加密"
    echo "  • 确保 80 和 443 端口已开放"
    echo ""

    if confirm "是否安装 V2Ray 代理节点？" "n"; then
        echo ""
        cd "$SCRIPT_DIR/1.v2ray"
        chmod +x install_v2ray.sh install_web.sh

        echo -e "${CYAN}>>> 正在安装 V2Ray 核心...${NC}"
        ./install_v2ray.sh

        if [ $? -eq 0 ]; then
            echo ""
            echo -e "${CYAN}>>> 正在部署伪装网站...${NC}"
            ./install_web.sh

            INSTALLED_SERVICES+=("V2Ray 代理节点")
            echo ""
            echo -e "${GREEN}✓ V2Ray 安装成功！${NC}"
            echo -e "${DIM}连接信息已保存到: v2ray_node_info.txt${NC}"
        else
            echo -e "${YELLOW}⚠ V2Ray 安装未完成${NC}"
        fi
    else
        echo -e "${DIM}跳过 V2Ray 安装${NC}"
    fi

    wait_key
}

install_cliproxyapi() {
    print_section "安装 CliproxyAPI (AI API 转发服务)"

    echo -e "${WHITE}功能说明:${NC}"
    echo "  • CliproxyAPI 是一款轻量级的 AI API 转发代理服务"
    echo "  • 支持 OpenAI、Claude、Gemini 等主流 AI 模型的 API 转发"
    echo "  • 提供统一的 API 端点，简化客户端配置"
    echo "  • 支持多密钥管理，通过 Web 界面进行配置"
    echo "  • 二进制部署，资源占用极低（适合低配 VPS）"
    echo ""
    echo -e "${CYAN}支持的访问模式:${NC}"
    echo "  • 域名模式：自动申请 Let's Encrypt 证书（推荐）"
    echo "  • IP 模式：使用自签名证书，无需域名"
    echo "  • HTTP 模式：无 SSL 证书，仅限内网/开发环境"
    echo ""
    echo -e "${CYAN}适用场景:${NC}"
    echo "  • 需要简单的 AI API 转发功能"
    echo "  • 服务器资源有限（内存 < 1GB）"
    echo "  • 不需要复杂的用户管理和计费功能"
    echo ""
    echo -e "${MAGENTA}对比其他方案:${NC}"
    echo "  • CliproxyAPI: 轻量、简单、二进制部署"
    echo "  • New-API: 功能丰富、用户管理、计费系统（Docker）"
    echo ""
    echo -e "${YELLOW}前置要求:${NC}"
    echo "  • 域名模式：需要一个已解析到本服务器的域名"
    echo "  • IP 模式：无需域名，浏览器会提示不安全"
    echo "  • HTTP 模式：无需域名或证书，但数据传输不加密"
    echo "  • 至少准备一个 AI 服务商的 API 密钥"
    echo ""

    if confirm "是否安装 CliproxyAPI？" "n"; then
        echo ""
        cd "$SCRIPT_DIR/2.cliproxyapi"
        chmod +x install_cliproxyapi_v2.sh
        ./install_cliproxyapi_v2.sh

        if [ $? -eq 0 ]; then
            CLIPROXYAPI_INSTALLED=true
            INSTALLED_SERVICES+=("CliproxyAPI")
            echo ""
            echo -e "${GREEN}✓ CliproxyAPI 安装成功！${NC}"
        else
            echo -e "${YELLOW}⚠ CliproxyAPI 安装未完成${NC}"
        fi
    else
        echo -e "${DIM}跳过 CliproxyAPI 安装${NC}"
    fi

    wait_key
}

install_newapi() {
    print_section "安装 New-API (AI 模型网关)"

    echo -e "${WHITE}功能说明:${NC}"
    echo "  • New-API 是新一代大模型网关与 AI 资产管理系统"
    echo "  • 支持 OpenAI、Claude、Gemini、Azure 等多种模型聚合"
    echo "  • 提供完整的用户管理、令牌分组、权限控制功能"
    echo "  • 内置计费系统，支持按次数/按量收费和在线充值"
    echo "  • 可视化数据看板，实时统计 API 调用情况"
    echo "  • 支持 Discord、Telegram、OIDC 等多种授权登录方式"
    echo ""
    echo -e "${CYAN}支持的访问模式:${NC}"
    echo "  • 域名模式：自动申请 Let's Encrypt 证书（推荐）"
    echo "  • IP 模式：使用自签名证书，无需域名"
    echo "  • HTTP 模式：无 SSL 证书，仅限内网/开发环境"
    echo ""
    echo -e "${CYAN}适用场景:${NC}"
    echo "  • 需要完整的 AI API 管理平台"
    echo "  • 需要用户管理和计费功能"
    echo "  • 希望对外提供 AI API 服务"
    echo "  • 需要多模型统一管理"
    echo ""
    echo -e "${MAGENTA}技术栈:${NC}"
    echo "  • Docker Compose 部署"
    echo "  • PostgreSQL 数据库（推荐）或 MySQL"
    echo "  • Redis 缓存"
    echo ""
    echo -e "${YELLOW}资源需求:${NC}"
    echo "  • 推荐内存: ≥ 1GB"
    echo "  • 需要安装 Docker"
    echo ""

    if confirm "是否安装 New-API？" "n"; then
        echo ""

        # 检查 Docker 环境
        if ! command -v docker &> /dev/null; then
            echo -e "${YELLOW}未检测到 Docker，尝试自动安装...${NC}"
            if ! ensure_docker; then
                echo -e "${RED}Docker 安装失败，无法继续安装 New-API${NC}"
                wait_key
                return
            fi
            DOCKER_INSTALLED=true
            INSTALLED_SERVICES+=("Docker")
        fi

        cd "$SCRIPT_DIR/3.new-api"
        chmod +x install_newapi_docker.sh
        ./install_newapi_docker.sh

        if [ $? -eq 0 ]; then
            NEWAPI_INSTALLED=true
            INSTALLED_SERVICES+=("New-API")
            echo ""
            echo -e "${GREEN}✓ New-API 安装成功！${NC}"
            echo -e "${DIM}配置信息已保存到: /opt/docker-services/new-api/newapi_info.txt${NC}"
        else
            echo -e "${YELLOW}⚠ New-API 安装未完成${NC}"
        fi
    else
        echo -e "${DIM}跳过 New-API 安装${NC}"
    fi

    wait_key
}

# ==================== 主流程 ====================

print_summary() {
    print_header
    print_section "部署完成总结"

    if [ ${#INSTALLED_SERVICES[@]} -eq 0 ]; then
        echo -e "${YELLOW}本次未安装任何服务。${NC}"
    else
        echo -e "${GREEN}本次已安装以下服务:${NC}"
        echo ""
        for service in "${INSTALLED_SERVICES[@]}"; do
            echo -e "  ${GREEN}✓${NC} $service"
        done
    fi

    echo ""
    print_divider
    echo ""
    echo -e "${WHITE}常用管理命令:${NC}"
    echo ""
    echo "  Nginx:"
    echo "    systemctl status nginx"
    echo "    /usr/local/nginx/sbin/nginx -t"
    echo "    systemctl reload nginx"
    echo ""

    if [ "$NEWAPI_INSTALLED" = true ]; then
        echo "  New-API:"
        echo "    cd /opt/docker-services/new-api && docker compose ps"
        echo "    docker compose logs -f new-api"
        echo ""
    fi

    if [ "$CLIPROXYAPI_INSTALLED" = true ]; then
        echo "  CliproxyAPI:"
        echo "    systemctl status cliproxyapi"
        echo "    journalctl -u cliproxyapi -f"
        echo ""
    fi

    print_divider
    echo ""
    echo -e "${CYAN}感谢使用 VPS 集群部署工具！${NC}"
    echo ""
}

main() {
    # 检查 root 权限
    check_root

    # 显示欢迎界面
    print_header

    echo -e "${WHITE}欢迎使用 VPS 集群全流程部署引导工具！${NC}"
    echo ""
    echo "本工具将引导您按顺序部署 VPS 集群的各个组件。"
    echo ""
    echo -e "${CYAN}可用组件:${NC}"
    echo "  0. Nginx 1.28.1 (HTTP/3)  - 基础设施【必选】"
    echo "  01. Docker 容器环境        - 容器服务前置依赖【推荐】"
    echo "  1. V2Ray 代理节点          - 科学上网"
    echo "  2. CliproxyAPI            - 轻量 AI API 转发"
    echo "  3. New-API                - AI 模型网关（完整功能）"
    echo "  8. 服务监控               - 自动化监控告警"
    echo ""
    echo -e "${YELLOW}依赖关系:${NC}"
    echo "  • 0.Nginx 是所有服务的基础，必须首先安装"
    echo "  • 01.Docker 是 New-API 等容器服务的前置依赖"
    echo ""

    if ! confirm "是否开始部署？" "y"; then
        echo ""
        echo -e "${YELLOW}已取消部署。${NC}"
        exit 0
    fi

    # 步骤 1: 安装 Nginx（必选）
    install_nginx

    # 步骤 2: 安装 Docker（推荐）
    install_docker

    # 步骤 3: 可选服务
    print_header
    echo -e "${WHITE}接下来，请选择要安装的可选服务。${NC}"
    echo ""
    echo "您可以选择安装以下服务（按顺序提示）:"
    echo "  • V2Ray 代理节点（科学上网）"
    echo "  • CliproxyAPI（轻量 AI API 转发）"
    echo "  • New-API（完整 AI 网关）"
    echo ""
    wait_key

    install_v2ray
    install_cliproxyapi
    install_newapi

    # 显示总结
    print_summary
}

# ==================== 执行主函数 ====================
main "$@"
