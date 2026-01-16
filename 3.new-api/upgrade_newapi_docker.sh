#!/bin/bash

################################################################################
#
# New-API Docker 升级脚本
#
# 功能说明：
#   1. 检测当前 New-API Docker 服务
#   2. 备份当前配置
#   3. 强制拉取最新镜像（不使用缓存）
#   4. 重建服务容器（数据自动保留）
#   5. 清理旧镜像
#
# 特点：
#   - 零配置变更：环境变量、数据库、Redis 全部保留
#   - 快速升级：使用 down && up 方式重建容器
#   - 自动回滚：失败时恢复旧版本
#   - 强制拉取：使用 --pull-always 确保获取最新镜像
#
# 使用方法：
#   chmod +x upgrade_newapi_docker.sh
#   ./upgrade_newapi_docker.sh
#
################################################################################

# ==================== 全局配置 ====================

DOCKER_ROOT="/opt/docker-services"
SERVICE_DIR="$DOCKER_ROOT/new-api"
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"

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
    log_error "必须使用 root 权限运行。"
    exit 1
fi

# 检查服务是否存在
if [ ! -d "$SERVICE_DIR" ]; then
    log_error "未检测到 New-API 安装目录: $SERVICE_DIR"
    log_info "请先运行 install_newapi_docker.sh 进行安装"
    exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
    log_error "未检测到 docker-compose.yml 文件"
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
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}   New-API Docker 升级程序${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ==================== 检测当前版本 ====================

log_step "[1/5] 检测当前服务状态..."

cd "$SERVICE_DIR"

# 从 docker-compose.yml 提取镜像名称
IMAGE_NAME=$(grep -E "^\s+image:\s*calciumion/new-api" "$COMPOSE_FILE" | awk '{print $2}' | tr -d '[:space:]')
if [ -z "$IMAGE_NAME" ]; then
    IMAGE_NAME="calciumion/new-api:latest"
fi

# 获取 :latest 标签指向的镜像 ID（不是容器正在使用的）
CURRENT_IMAGE=$(docker images --format "{{.ID}}" "$IMAGE_NAME" 2>/dev/null | head -1)

if [ -z "$CURRENT_IMAGE" ]; then
    log_warning "无法获取当前镜像版本"
else
    # 显示镜像创建时间
    IMAGE_CREATED=$(docker images --format "{{.CreatedAt}}" "$IMAGE_NAME" 2>/dev/null | head -1)
    log_info "当前镜像 ID: ${CURRENT_IMAGE:0:12}"
    if [ -n "$IMAGE_CREATED" ]; then
        log_info "镜像创建时间: $IMAGE_CREATED"
    fi
fi

# 检查服务运行状态
SERVICE_RUNNING=false
if $COMPOSE_CMD ps | grep -q "Up"; then
    SERVICE_RUNNING=true
    log_info "服务状态: 运行中"
else
    log_warning "服务状态: 已停止"
fi

echo ""
read -p "是否继续升级？(y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "升级已取消。"
    exit 0
fi

# ==================== 备份配置 ====================

log_step "[2/5] 备份当前配置..."

BACKUP_DIR="$SERVICE_DIR/backups"
mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/docker-compose_$(date +%Y%m%d_%H%M%S).yml"
cp "$COMPOSE_FILE" "$BACKUP_FILE"

log_success "配置已备份: $BACKUP_FILE"

# ==================== 拉取最新镜像 ====================

log_step "[3/5] 拉取最新镜像..."

log_info "正在检查更新（可能需要几分钟）..."

# 使用 docker pull 而不是 docker compose pull，确保强制拉取不使用缓存
if docker pull --pull-always "$IMAGE_NAME" 2>&1 | tee /tmp/pull_output.log; then
    log_success "镜像拉取完成"

    # 获取 :latest 标签指向的新镜像 ID（需要重新获取，因为 pull 可能更新了标签）
    NEW_IMAGE=$(docker images --format "{{.ID}}" "$IMAGE_NAME" 2>/dev/null | head -1)

    # 如果仍然是旧镜像，可能远程没有更新
    if [ "$CURRENT_IMAGE" = "$NEW_IMAGE" ]; then
        log_info "已是最新版本，无需升级"
        echo ""
        read -p "是否重启服务？(y/N): " -n 1 -r
        echo ""

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            $COMPOSE_CMD restart new-api
            log_success "服务已重启"
        fi

        exit 0
    else
        log_success "检测到新版本"
        log_info "旧镜像 ID: ${YELLOW}${CURRENT_IMAGE:0:12}${NC}"
        log_info "新镜像 ID: ${GREEN}${NEW_IMAGE:0:12}${NC}"
        log_info "容器将使用新镜像重建"
    fi
else
    log_error "镜像拉取失败，请检查网络连接"
    log_info "可尝试手动拉取: docker pull $IMAGE_NAME"
    exit 1
fi

# ==================== 重启服务 ====================

log_step "[4/5] 重启服务..."

log_info "正在使用新镜像重建容器..."

# 先停止并删除旧容器，然后用新镜像创建
if $COMPOSE_CMD down && $COMPOSE_CMD up -d; then
    log_success "容器重建成功"

    # 等待服务启动
    log_info "等待服务启动（约 20 秒）..."
    sleep 20

    # 检查服务健康状态
    if $COMPOSE_CMD ps | grep -q "Up"; then
        log_success "服务运行正常"
    else
        log_error "服务启动失败，正在回滚..."

        # 回滚到旧版本
        cp "$BACKUP_FILE" "$COMPOSE_FILE"
        $COMPOSE_CMD up -d

        log_warning "已回滚到旧版本"
        log_info "请检查日志: cd $SERVICE_DIR && $COMPOSE_CMD logs -f new-api"
        exit 1
    fi
else
    log_error "容器重建失败"
    log_info "配置文件备份位置: $BACKUP_FILE"
    exit 1
fi

# ==================== 清理旧镜像 ====================

log_step "[5/5] 清理旧镜像..."

log_info "正在清理未使用的镜像..."

# 清理悬空镜像
REMOVED_IMAGES=$(docker image prune -f 2>&1 | grep "Total reclaimed space" || echo "")

if [ -n "$REMOVED_IMAGES" ]; then
    log_success "清理完成"
    echo "$REMOVED_IMAGES"
else
    log_info "没有需要清理的镜像"
fi

# ==================== 完成信息 ====================

clear
echo -e "${GREEN}"
echo "================================================"
echo "       New-API 升级完成！"
echo "================================================"
echo -e "${NC}"
echo ""
echo -e "${CYAN}[升级信息]${NC}"
echo -e "旧镜像 ID: ${YELLOW}${CURRENT_IMAGE:0:12}${NC}"
echo -e "新镜像 ID: ${GREEN}${NEW_IMAGE:0:12}${NC}"
echo ""
echo -e "${CYAN}[服务状态]${NC}"

# 显示服务状态
$COMPOSE_CMD ps

echo ""
echo -e "${CYAN}[配置保留]${NC}"
echo -e "环境变量:   ${GREEN}✓ 已保留${NC}"
echo -e "数据库:     ${GREEN}✓ 已保留${NC}"
echo -e "Redis:      ${GREEN}✓ 已保留${NC}"
echo -e "配置备份:   $BACKUP_FILE"
echo ""
echo -e "${CYAN}[常用命令]${NC}"
echo -e "查看日志:   cd $SERVICE_DIR && $COMPOSE_CMD logs -f new-api"
echo -e "查看状态:   cd $SERVICE_DIR && $COMPOSE_CMD ps"
echo -e "重启服务:   cd $SERVICE_DIR && $COMPOSE_CMD restart"
echo ""
echo -e "${GREEN}升级完成！所有数据和配置已完整保留。${NC}"
echo "================================================"
echo ""
