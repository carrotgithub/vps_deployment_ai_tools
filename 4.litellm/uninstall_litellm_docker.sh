#!/bin/bash

################################################################################
#
# LiteLLM Docker 卸载脚本
#
# 功能说明：
#   1. 停止并删除所有 LiteLLM 容器
#   2. 删除 Docker 数据卷（可选备份）
#   3. 删除配置文件和目录
#   4. 删除 Nginx 配置
#   5. 删除 SSL 证书（可选）
#   6. 清理共享网络（如无其他容器使用）
#
# ⚠️  警告：
#   - 此操作将删除所有 LiteLLM 数据（包括数据库）
#   - 删除前会提示备份选项
#   - 不影响 New-API、CliproxyAPI 等其他服务
#
# 使用方法：
#   chmod +x uninstall_litellm_docker.sh
#   ./uninstall_litellm_docker.sh
#
################################################################################

# ==================== 全局配置 ====================

SERVICE_DIR="/opt/docker-services/litellm"
BACKUP_DIR="/backup/litellm-uninstall-$(date +%Y%m%d_%H%M%S)"
DOCKER_NETWORK="ai-services"

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

log_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

# ==================== 环境检查 ====================

if [ "$EUID" -ne 0 ]; then
    log_error "必须使用 root 权限运行此脚本。"
    exit 1
fi

# 检查服务是否存在
if [ ! -d "$SERVICE_DIR" ]; then
    log_error "未检测到 LiteLLM 安装目录: $SERVICE_DIR"
    log_info "服务可能已被卸载或未安装"
    exit 1
fi

# 统一使用 docker compose（新版）或 docker-compose（旧版）
if docker compose version &> /dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

# ==================== 欢迎横幅 ====================

clear
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}   LiteLLM Docker 卸载程序${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}⚠️  警告：此操作将删除以下内容${NC}"
echo ""
echo "  • 所有 LiteLLM 容器（litellm, litellm-postgres, litellm-redis）"
echo "  • 所有数据库数据（PostgreSQL）"
echo "  • 所有 Redis 缓存数据"
echo "  • 配置文件和日志（包括 config.yaml）"
echo "  • Nginx 配置文件"
echo "  • SSL 证书（可选）"
echo ""
echo -e "${GREEN}✓ 不会影响的服务${NC}"
echo ""
echo "  • New-API 服务"
echo "  • CliproxyAPI 服务"
echo "  • 其他 Docker 服务"
echo "  • Nginx 主程序"
echo ""
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

read -p "是否继续卸载 LiteLLM？(yes/NO): " CONFIRM

if [[ ! "$CONFIRM" == "yes" ]]; then
    log_info "卸载已取消。"
    exit 0
fi

# ==================== 检测当前状态 ====================

log_step "[1/7] 检测当前服务状态..."

cd "$SERVICE_DIR"

# 获取域名（从 Nginx 配置）
DOMAIN=$(find /usr/local/nginx/conf/conf.d/ -name "*litellm*.conf" 2>/dev/null | head -1 | xargs -I {} basename {} .conf 2>/dev/null)

if [ -z "$DOMAIN" ]; then
    DOMAIN="unknown"
    log_warning "未检测到域名配置"
else
    log_info "检测到域名: $DOMAIN"
fi

# 检查容器状态
RUNNING_CONTAINERS=$($COMPOSE_CMD ps -q 2>/dev/null | wc -l)

if [ "$RUNNING_CONTAINERS" -gt 0 ]; then
    log_info "检测到 $RUNNING_CONTAINERS 个运行中的容器"
    $COMPOSE_CMD ps
else
    log_info "没有运行中的容器"
fi

echo ""

# ==================== 备份数据 ====================

log_step "[2/7] 数据备份..."

read -p "是否备份数据库和配置？(Y/n): " BACKUP_CHOICE

if [[ ! "$BACKUP_CHOICE" =~ ^[Nn]$ ]]; then
    log_info "正在备份数据到: $BACKUP_DIR"

    mkdir -p "$BACKUP_DIR"

    # 备份配置文件
    if [ -f "$SERVICE_DIR/docker-compose.yml" ]; then
        cp "$SERVICE_DIR/docker-compose.yml" "$BACKUP_DIR/"
        log_success "已备份 docker-compose.yml"
    fi

    if [ -f "$SERVICE_DIR/config.yaml" ]; then
        cp "$SERVICE_DIR/config.yaml" "$BACKUP_DIR/"
        log_success "已备份 config.yaml"
    fi

    if [ -f "$SERVICE_DIR/litellm_info.txt" ]; then
        cp "$SERVICE_DIR/litellm_info.txt" "$BACKUP_DIR/"
        log_success "已备份 litellm_info.txt"
    fi

    # 备份数据库（如果容器运行中）
    if $COMPOSE_CMD ps | grep -q "Up"; then
        log_info "正在导出数据库..."

        if $COMPOSE_CMD ps | grep -q "postgres"; then
            if $COMPOSE_CMD exec -T postgres pg_dump -U litellm litellm > "$BACKUP_DIR/database_backup.sql" 2>/dev/null; then
                log_success "PostgreSQL 数据库已备份"
            else
                log_warning "数据库备份失败（可能已停止）"
            fi
        fi
    else
        log_warning "容器未运行，跳过数据库备份"
    fi

    # 打包备份
    if [ -d "$BACKUP_DIR" ] && [ "$(ls -A $BACKUP_DIR)" ]; then
        tar -czf "${BACKUP_DIR}.tar.gz" -C "$(dirname $BACKUP_DIR)" "$(basename $BACKUP_DIR)" 2>/dev/null
        rm -rf "$BACKUP_DIR"
        log_success "备份已打包: ${BACKUP_DIR}.tar.gz"
    fi
else
    log_warning "跳过数据备份"
fi

echo ""

# ==================== 停止并删除容器 ====================

log_step "[3/7] 停止并删除容器..."

cd "$SERVICE_DIR"

if [ -f docker-compose.yml ]; then
    log_info "正在停止容器..."
    $COMPOSE_CMD down

    read -p "是否删除数据卷（包含数据库数据）？(y/N): " DELETE_VOLUMES

    if [[ "$DELETE_VOLUMES" =~ ^[Yy]$ ]]; then
        log_info "正在删除数据卷..."
        $COMPOSE_CMD down -v
        log_success "容器和数据卷已删除"
    else
        log_success "容器已删除（数据卷保留）"
        log_info "数据卷可手动删除: docker volume ls | grep litellm"
    fi
else
    log_warning "docker-compose.yml 不存在，跳过容器删除"
fi

echo ""

# ==================== 删除配置文件和目录 ====================

log_step "[4/7] 删除配置文件和目录..."

if [ -d "$SERVICE_DIR" ]; then
    log_info "正在删除服务目录: $SERVICE_DIR"
    rm -rf "$SERVICE_DIR"
    log_success "服务目录已删除"
else
    log_warning "服务目录不存在，跳过"
fi

echo ""

# ==================== 删除 Nginx 配置 ====================

log_step "[5/7] 删除 Nginx 配置..."

# 查找 Nginx 配置文件
NGINX_CONF=$(find /usr/local/nginx/conf/conf.d/ -name "*litellm*.conf" 2>/dev/null | head -1)

if [ -n "$NGINX_CONF" ] && [ -f "$NGINX_CONF" ]; then
    log_info "检测到 Nginx 配置: $NGINX_CONF"
    rm -f "$NGINX_CONF"
    log_success "Nginx 配置已删除"

    # 重载 Nginx
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl reload nginx
        log_success "Nginx 已重载"
    elif [ -f /usr/local/nginx/sbin/nginx ]; then
        /usr/local/nginx/sbin/nginx -s reload 2>/dev/null
        log_success "Nginx 已重载"
    fi
else
    log_warning "未找到 Nginx 配置文件"
fi

echo ""

# ==================== 删除 SSL 证书 ====================

log_step "[6/7] 删除 SSL 证书..."

if [ "$DOMAIN" != "unknown" ]; then
    SSL_DIR="/usr/local/nginx/conf/ssl/$DOMAIN"

    if [ -d "$SSL_DIR" ]; then
        read -p "是否删除 SSL 证书？($DOMAIN) (y/N): " DELETE_SSL

        if [[ "$DELETE_SSL" =~ ^[Yy]$ ]]; then
            rm -rf "$SSL_DIR"
            log_success "SSL 证书已删除"

            # 删除 acme.sh 证书记录
            if [ -f ~/.acme.sh/acme.sh ]; then
                ~/.acme.sh/acme.sh --remove -d "$DOMAIN" --ecc 2>/dev/null
                log_info "已清理 acme.sh 证书记录"
            fi
        else
            log_info "SSL 证书已保留: $SSL_DIR"
        fi
    else
        log_warning "未找到 SSL 证书目录"
    fi
else
    log_warning "无法确定域名，跳过 SSL 证书删除"
fi

echo ""

# ==================== 清理共享网络 ====================

log_step "[7/7] 清理共享网络..."

# 检查共享网络是否存在
if docker network ls | grep -q "$DOCKER_NETWORK"; then
    # 检查网络中是否还有其他容器
    NETWORK_CONTAINERS=$(docker network inspect "$DOCKER_NETWORK" -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)

    if [ -z "$NETWORK_CONTAINERS" ]; then
        log_info "共享网络 $DOCKER_NETWORK 中没有其他容器，可以删除"
        read -p "是否删除共享网络 $DOCKER_NETWORK？(y/N): " DELETE_NETWORK

        if [[ "$DELETE_NETWORK" =~ ^[Yy]$ ]]; then
            docker network rm "$DOCKER_NETWORK" 2>/dev/null
            log_success "共享网络已删除"
        else
            log_info "共享网络已保留"
        fi
    else
        log_info "共享网络 $DOCKER_NETWORK 中还有其他容器："
        echo "$NETWORK_CONTAINERS"
        log_info "网络已保留（供其他服务使用）"
    fi
else
    log_warning "共享网络 $DOCKER_NETWORK 不存在"
fi

echo ""

# ==================== 完成信息 ====================

clear
echo -e "${GREEN}"
echo "================================================"
echo "       LiteLLM 卸载完成！"
echo "================================================"
echo -e "${NC}"
echo ""
echo -e "${CYAN}[已删除的内容]${NC}"
echo -e "✓ 所有 LiteLLM 容器"
echo -e "✓ 服务目录: $SERVICE_DIR"
echo -e "✓ Nginx 配置"
if [[ "$DELETE_SSL" =~ ^[Yy]$ ]]; then
    echo -e "✓ SSL 证书: $DOMAIN"
fi
if [[ "$DELETE_VOLUMES" =~ ^[Yy]$ ]]; then
    echo -e "✓ 数据卷（包含数据库数据）"
fi
echo ""

if [[ ! "$BACKUP_CHOICE" =~ ^[Nn]$ ]]; then
    echo -e "${CYAN}[数据备份]${NC}"
    echo -e "备份文件: ${GREEN}${BACKUP_DIR}.tar.gz${NC}"
    echo ""
fi

echo -e "${CYAN}[保留的内容]${NC}"
echo -e "✓ Docker 主程序"
echo -e "✓ Nginx 主程序"
echo -e "✓ New-API 服务（如已安装）"
echo -e "✓ CliproxyAPI 服务（如已安装）"

if [[ ! "$DELETE_VOLUMES" =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${YELLOW}[注意]${NC}"
    echo -e "数据卷已保留，可手动清理："
    echo -e "  docker volume ls | grep litellm"
    echo -e "  docker volume rm litellm_postgres_data litellm_redis_data"
fi

echo ""
echo -e "${GREEN}卸载完成！系统已清理干净。${NC}"
echo "================================================"
echo ""
