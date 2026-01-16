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
#   1-4 服务    → 可选（独立服务）
#   5.cn2-proxy → 需要后端服务（2/3/4）
#   6-8 多cn2   → 需要先部署5
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
NEWAPI_INSTALLED=false
LITELLM_INSTALLED=false
CLIPROXYAPI_INSTALLED=false
CN2_PROXY_INSTALLED=false

# ==================== 辅助函数 ====================

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

install_v2ray() {
    print_section "安装 V2Ray 代理节点"

    echo -e "${WHITE}功能说明:${NC}"
    echo "  • V2Ray 是一款功能强大的代理工具，用于科学上网"
    echo "  • 使用 WebSocket + TLS 传输，流量伪装为正常 HTTPS 请求"
    echo "  • 自动生成随机 UUID 和 WebSocket 路径，增强安全性"
    echo "  • 内置静态伪装网站，访问域名显示'系统维护'页面"
    echo "  • 支持 Let's Encrypt 证书自动申请，失败自动降级为自签名"
    echo ""
    echo -e "${CYAN}适用场景:${NC}"
    echo "  • 需要部署代理节点用于科学上网"
    echo "  • 希望流量伪装为正常网站访问"
    echo ""
    echo -e "${YELLOW}前置要求:${NC}"
    echo "  • 需要一个已解析到本服务器的域名（例如: v2.example.com）"
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
    echo -e "${CYAN}适用场景:${NC}"
    echo "  • 需要简单的 AI API 转发功能"
    echo "  • 服务器资源有限（内存 < 1GB）"
    echo "  • 不需要复杂的用户管理和计费功能"
    echo ""
    echo -e "${MAGENTA}对比其他方案:${NC}"
    echo "  • CliproxyAPI: 轻量、简单、二进制部署"
    echo "  • New-API: 功能丰富、用户管理、计费系统（Docker）"
    echo "  • LiteLLM: 100+ 模型支持、负载均衡、成本控制（Docker）"
    echo ""
    echo -e "${YELLOW}前置要求:${NC}"
    echo "  • 需要一个已解析到本服务器的域名"
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

    # 检查 Docker
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}⚠ 检测到 Docker 未安装，安装脚本将自动安装 Docker${NC}"
    fi

    if confirm "是否安装 New-API？" "n"; then
        echo ""
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

install_litellm() {
    print_section "安装 LiteLLM (LLM 统一代理)"

    echo -e "${WHITE}功能说明:${NC}"
    echo "  • LiteLLM 是一个统一的 LLM API 代理服务器"
    echo "  • 支持 100+ AI 模型，包括 OpenAI、Claude、Gemini、Azure 等"
    echo "  • 提供 OpenAI 兼容的统一接口，简化客户端集成"
    echo "  • 内置负载均衡，支持多密钥轮询和故障转移"
    echo "  • 虚拟密钥管理，可为每个密钥设置预算限额"
    echo "  • Redis 缓存加速，减少重复请求费用"
    echo "  • Prometheus 监控指标，支持成本追踪"
    echo ""
    echo -e "${CYAN}适用场景:${NC}"
    echo "  • 需要统一多个 AI 服务商的 API"
    echo "  • 需要负载均衡和故障转移能力"
    echo "  • 需要预算控制和成本监控"
    echo "  • 开发者使用，需要 OpenAI 兼容接口"
    echo ""
    echo -e "${MAGENTA}与 New-API 的区别:${NC}"
    echo "  • New-API: 面向运营，完整的用户系统和计费"
    echo "  • LiteLLM: 面向开发者，统一接口和负载均衡"
    echo "  • 两者可以配合使用: New-API 作为前端，LiteLLM 作为后端"
    echo ""
    echo -e "${YELLOW}资源需求:${NC}"
    echo "  • 推荐内存: ≥ 1GB"
    echo "  • 需要安装 Docker"
    echo ""

    if confirm "是否安装 LiteLLM？" "n"; then
        echo ""
        cd "$SCRIPT_DIR/4.litellm"
        chmod +x install_litellm_docker.sh
        ./install_litellm_docker.sh

        if [ $? -eq 0 ]; then
            LITELLM_INSTALLED=true
            INSTALLED_SERVICES+=("LiteLLM")
            echo ""
            echo -e "${GREEN}✓ LiteLLM 安装成功！${NC}"
            echo -e "${DIM}配置信息已保存到: /opt/docker-services/litellm/litellm_info.txt${NC}"
        else
            echo -e "${YELLOW}⚠ LiteLLM 安装未完成${NC}"
        fi
    else
        echo -e "${DIM}跳过 LiteLLM 安装${NC}"
    fi

    wait_key
}

install_cn2_proxy() {
    print_section "安装 CN2 VPS 反向代理"

    # 检查是否有后端服务
    if [ "$NEWAPI_INSTALLED" = false ] && [ "$LITELLM_INSTALLED" = false ] && [ "$CLIPROXYAPI_INSTALLED" = false ]; then
        echo -e "${RED}⚠️  无法安装 CN2 反向代理！${NC}"
        echo ""
        echo "CN2 反向代理需要一个后端 API 服务作为转发目标。"
        echo "您需要先在性能服务器上安装以下服务之一："
        echo "  • New-API (3.new-api)"
        echo "  • LiteLLM (4.litellm)"
        echo "  • CliproxyAPI (2.cliproxyapi)"
        echo ""
        echo -e "${YELLOW}请先完成后端服务部署，再部署 CN2 反向代理。${NC}"
        wait_key
        return
    fi

    echo -e "${WHITE}功能说明:${NC}"
    echo "  • CN2 反向代理用于优化国内用户访问海外 API 服务的速度"
    echo "  • 利用 CN2 线路（中国电信精品网络）降低延迟"
    echo "  • 在 CN2 VPS 上部署 Nginx 反向代理，转发请求到性能服务器"
    echo "  • 支持 SSL 证书自动申请和配置"
    echo "  • 针对 SSE 流式传输进行优化"
    echo ""
    echo -e "${CYAN}适用场景:${NC}"
    echo "  • 您有一台 CN2 线路的 VPS（国内访问快）"
    echo "  • 您有一台性能服务器（海外，运行 AI 服务）"
    echo "  • 希望国内用户通过 CN2 节点访问，降低延迟"
    echo ""
    echo -e "${MAGENTA}部署架构:${NC}"
    echo ""
    echo "  用户（国内）"
    echo "      ↓"
    echo "  CN2 VPS (反向代理)"
    echo "  newapi.example.com"
    echo "      ↓ CN2 优质线路"
    echo "  性能服务器（海外）"
    echo "  api.example.com"
    echo "      ↓"
    echo "  AI 服务 (New-API / LiteLLM)"
    echo ""
    echo -e "${RED}⚠️  重要提示:${NC}"
    echo "  • 此脚本应在 CN2 VPS 上运行（不是性能服务器）"
    echo "  • 需要准备两个域名：CN2 入口域名 和 后端服务域名"
    echo "  • 后端服务必须已经部署并可访问"
    echo ""

    if confirm "确认这是 CN2 VPS 且后端服务已就绪？" "n"; then
        echo ""
        cd "$SCRIPT_DIR/5.cn2-proxy"
        chmod +x apply_ssl_cn2.sh test_proxy.sh

        echo -e "${CYAN}>>> 请输入 CN2 域名（用户访问的域名）:${NC}"
        read -p "域名: " cn2_domain

        if [ -z "$cn2_domain" ]; then
            echo -e "${RED}域名不能为空${NC}"
            wait_key
            return
        fi

        echo ""
        echo -e "${CYAN}>>> 正在申请 SSL 证书...${NC}"
        ./apply_ssl_cn2.sh -d "$cn2_domain"

        if [ $? -eq 0 ]; then
            CN2_PROXY_INSTALLED=true
            INSTALLED_SERVICES+=("CN2 反向代理")
            echo ""
            echo -e "${GREEN}✓ SSL 证书申请成功！${NC}"
            echo ""
            echo -e "${YELLOW}下一步操作:${NC}"
            echo "1. 编辑 Nginx 配置文件，设置后端服务器地址"
            echo "2. 复制配置: cp nginx_newapi_proxy.conf /usr/local/nginx/conf/conf.d/$cn2_domain.conf"
            echo "3. 编辑配置文件，修改 proxy_pass 目标地址"
            echo "4. 测试: /usr/local/nginx/sbin/nginx -t && systemctl reload nginx"
            echo "5. 验证: ./test_proxy.sh"
        else
            echo -e "${YELLOW}⚠ SSL 证书申请未完成${NC}"
        fi
    else
        echo -e "${DIM}跳过 CN2 反向代理安装${NC}"
    fi

    wait_key
}

install_multi_cn2() {
    print_section "多 CN2 协同方案"

    # 检查是否已部署 CN2 反向代理
    if [ "$CN2_PROXY_INSTALLED" = false ]; then
        echo -e "${RED}⚠️  无法配置多 CN2 协同！${NC}"
        echo ""
        echo "多 CN2 协同需要先在每台 CN2 VPS 上部署反向代理。"
        echo "请先完成以下步骤："
        echo "  1. 在每台 CN2 VPS 上运行 5.cn2-proxy 脚本"
        echo "  2. 确保所有 CN2 节点都能正常转发到后端服务"
        echo ""
        echo -e "${YELLOW}请先完成单节点部署，再配置多节点协同。${NC}"
        wait_key
        return
    fi

    echo -e "${WHITE}功能说明:${NC}"
    echo "  当您有多台 CN2 VPS 时，可以通过以下方案实现高可用和负载均衡："
    echo ""
    echo -e "${CYAN}方案 1: DNS 轮询（简单、零成本）${NC}"
    echo "  • 在 DNS 中为同一域名添加多条 A 记录"
    echo "  • DNS 服务器自动轮询返回不同 IP"
    echo "  • 优点: 配置简单，无额外成本"
    echo "  • 缺点: 无健康检查，故障切换慢（5-60分钟）"
    echo "  • 可用性: ~95%"
    echo ""
    echo -e "${CYAN}方案 2: Nginx 负载均衡（高可用、精确控制）${NC}"
    echo "  • 部署一台独立的负载均衡器 VPS"
    echo "  • 使用 Nginx Stream 模块进行四层代理"
    echo "  • 主动健康检查，秒级故障切换"
    echo "  • 优点: 完全可控，支持权重分配和会话保持"
    echo "  • 缺点: 需要额外 VPS（约 $10/月）"
    echo "  • 可用性: ~99.5%"
    echo ""

    echo "请选择要了解的方案:"
    echo "  1) DNS 轮询方案详情"
    echo "  2) Nginx 负载均衡方案详情"
    echo "  3) 跳过"
    echo ""
    read -p "请输入选项 [1-3]: " choice

    case $choice in
        1)
            echo ""
            echo -e "${GREEN}=== DNS 轮询方案 ===${NC}"
            echo ""
            echo "配置步骤:"
            echo "1. 在每台 CN2 VPS 上部署相同的反向代理配置"
            echo "2. 在 DNS 服务商添加多条 A 记录:"
            echo "   newapi.example.com → 1.2.3.4 (CN2-1)"
            echo "   newapi.example.com → 5.6.7.8 (CN2-2)"
            echo "   newapi.example.com → 9.10.11.12 (CN2-3)"
            echo "3. 设置 TTL 为 300 秒（5分钟）"
            echo ""
            echo "监控建议:"
            echo "  • 使用 6.dns-loadbalance/health_check.sh 定期检查节点健康"
            echo "  • 发现故障节点时手动删除 DNS 记录"
            echo ""
            echo -e "${DIM}详细文档: 6.dns-loadbalance/README.md${NC}"
            ;;
        2)
            echo ""
            echo -e "${GREEN}=== Nginx 负载均衡方案 ===${NC}"
            echo ""
            echo "配置步骤:"
            echo "1. 准备一台独立的 VPS 作为负载均衡器"
            echo "2. 在负载均衡器上安装 Nginx（需要 Stream 模块）"
            echo "3. 配置 Nginx Stream 上游服务器:"
            echo "   upstream cn2_backend {"
            echo "       least_conn;"
            echo "       server 1.2.3.4:443;"
            echo "       server 5.6.7.8:443;"
            echo "       server 9.10.11.12:443;"
            echo "   }"
            echo "4. 将域名解析到负载均衡器 IP"
            echo "5. 部署健康检查脚本自动管理节点状态"
            echo ""
            echo "配置文件:"
            echo "  • 7.nginx-loadbalance/newapi_lb.conf"
            echo "  • 7.nginx-loadbalance/nginx_healthcheck.sh"
            echo ""
            echo -e "${DIM}详细文档: 7.nginx-loadbalance/README.md${NC}"
            ;;
        *)
            echo -e "${DIM}跳过多 CN2 协同配置${NC}"
            ;;
    esac

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

    if [ "$LITELLM_INSTALLED" = true ]; then
        echo "  LiteLLM:"
        echo "    cd /opt/docker-services/litellm && docker compose ps"
        echo "    docker compose logs -f litellm"
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
    echo "  1. V2Ray 代理节点          - 科学上网"
    echo "  2. CliproxyAPI            - 轻量 AI API 转发"
    echo "  3. New-API                - AI 模型网关（完整功能）"
    echo "  4. LiteLLM                - LLM 统一代理"
    echo "  5. CN2 VPS 反向代理       - 网络优化（需要后端服务）"
    echo "  6-7. 多 CN2 协同          - 高可用方案"
    echo "  8. 服务监控               - 自动化监控告警"
    echo ""
    echo -e "${YELLOW}依赖关系:${NC}"
    echo "  • 0.Nginx 是所有服务的基础，必须首先安装"
    echo "  • 5.CN2反向代理 需要先部署 2/3/4 中的至少一个作为后端"
    echo "  • 6-7.多CN2协同 需要先完成 5.CN2反向代理部署"
    echo ""

    if ! confirm "是否开始部署？" "y"; then
        echo ""
        echo -e "${YELLOW}已取消部署。${NC}"
        exit 0
    fi

    # 步骤 1: 安装 Nginx（必选）
    install_nginx

    # 步骤 2-4: 可选服务
    print_header
    echo -e "${WHITE}接下来，请选择要安装的可选服务。${NC}"
    echo ""
    echo "您可以选择安装以下服务（按顺序提示）:"
    echo "  • V2Ray 代理节点（科学上网）"
    echo "  • CliproxyAPI（轻量 AI API 转发）"
    echo "  • New-API（完整 AI 网关）"
    echo "  • LiteLLM（LLM 统一代理）"
    echo ""
    wait_key

    install_v2ray
    install_cliproxyapi
    install_newapi
    install_litellm

    # 步骤 5: CN2 反向代理（需要后端服务）
    if [ "$NEWAPI_INSTALLED" = true ] || [ "$LITELLM_INSTALLED" = true ] || [ "$CLIPROXYAPI_INSTALLED" = true ]; then
        print_header
        echo -e "${WHITE}检测到您已安装 API 服务，是否需要配置 CN2 反向代理？${NC}"
        echo ""
        echo "CN2 反向代理用于优化国内用户访问速度。"
        echo "如果您有一台 CN2 线路的 VPS，可以在那台机器上部署反向代理。"
        echo ""
        echo -e "${YELLOW}注意: CN2 反向代理应在另一台 CN2 VPS 上部署，而不是当前服务器。${NC}"
        echo ""

        if confirm "是否需要了解 CN2 反向代理部署方法？" "n"; then
            install_cn2_proxy
        fi
    fi

    # 步骤 6-7: 多 CN2 协同
    if [ "$CN2_PROXY_INSTALLED" = true ]; then
        print_header
        echo -e "${WHITE}是否需要配置多 CN2 节点协同？${NC}"
        echo ""

        if confirm "是否了解多 CN2 协同方案？" "n"; then
            install_multi_cn2
        fi
    fi

    # 显示总结
    print_summary
}

# ==================== 执行主函数 ====================
main "$@"
