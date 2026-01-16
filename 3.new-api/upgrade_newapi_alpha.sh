#!/bin/bash

################################################################################
#
# New-API Docker Alpha 版本升级脚本
#
# 功能说明：
#   1. 自动从 GitHub API 获取最新的 alpha 版本号
#   2. 备份当前配置
#   3. 拉取指定 alpha 版本镜像
#   4. 更新 docker-compose.yml 中的镜像标签
#   5. 重建服务容器（数据自动保留）
#
# 特点：
#   - 自动检测最新 alpha 版本
#   - 支持回滚到稳定版
#   - 保留所有数据和配置
#
# 使用方法：
#   chmod +x upgrade_newapi_alpha.sh
#   ./upgrade_newapi_alpha.sh
#
################################################################################

# ==================== 全局配置 ====================

DOCKER_ROOT="/opt/docker-services"
SERVICE_DIR="$DOCKER_ROOT/new-api"
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
BACKUP_DIR="$SERVICE_DIR/backups"

# GitHub API 配置
GITHUB_API="https://api.github.com/repos/QuantumNous/new-api/releases"
DOCKER_IMAGE="calciumion/new-api"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
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
echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${MAGENTA}   New-API Alpha 版本升级程序${NC}"
echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ==================== 获取当前版本 ====================

log_step "[1/6] 检测当前配置..."

cd "$SERVICE_DIR"

# 从 docker-compose.yml 提取当前镜像标签
CURRENT_IMAGE_TAG=$(grep -E "^\s+image:\s+calciumion/new-api" "$COMPOSE_FILE" | sed 's/.*image:\s*//' | tr -d '[:space:]')

if [ -z "$CURRENT_IMAGE_TAG" ]; then
    CURRENT_IMAGE_TAG="${DOCKER_IMAGE}:latest"
fi

log_info "当前镜像: ${YELLOW}$CURRENT_IMAGE_TAG${NC}"

# 获取当前镜像的创建时间
CURRENT_IMAGE_ID=$(docker images --format "{{.ID}}" "$CURRENT_IMAGE_TAG" 2>/dev/null | head -1)
if [ -n "$CURRENT_IMAGE_ID" ]; then
    CURRENT_CREATED=$(docker images --format "{{.CreatedAt}}" "$CURRENT_IMAGE_TAG" 2>/dev/null | head -1)
    log_info "镜像 ID: ${CURRENT_IMAGE_ID:0:12}"
    log_info "创建时间: $CURRENT_CREATED"
fi

echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}⚠️  Alpha 版本说明${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Alpha 版本包含最新功能，但可能存在不稳定因素。"
echo -e "建议在测试环境验证后再用于生产环境。"
echo ""

# 选择升级方式
echo -e "${CYAN}请选择升级方式:${NC}"
echo "  1) 自动升级到最新 Alpha 版本"
echo "  2) 查看可用的 Alpha 版本列表"
echo "  3) 手动输入版本号"
echo "  4) 回滚到稳定版 (latest)"
read -p "请选择 [1-4]: " -n 1 -r CHOICE
echo ""

# ==================== 获取最新版本信息 ====================

case $CHOICE in
    1)
        # 自动获取最新 alpha 版本
        log_step "[2/6] 获取最新 Alpha 版本信息..."

        LATEST_ALPHA=$(curl -s "$GITHUB_API" | grep -oP '"tag_name":\s*"v[0-9.]+-alpha\.[0-9]+"' | head -1 | grep -oP 'v[0-9.]+-alpha\.[0-9]+' || echo "")

        if [ -z "$LATEST_ALPHA" ]; then
            log_error "无法获取最新 Alpha 版本信息"
            log_info "请检查网络连接或手动输入版本号"
            exit 1
        fi

        TARGET_VERSION="$LATEST_ALPHA"
        log_success "最新 Alpha 版本: ${GREEN}$TARGET_VERSION${NC}"
        ;;

    2)
        # 显示可用版本列表
        log_step "[2/6] 获取可用版本列表..."

        echo ""
        echo -e "${CYAN}===== 最近发布的 Alpha 版本 =====${NC}"
        curl -s "$GITHUB_API" | grep -oP '"tag_name":\s*"v[0-9.]+-(alpha|beta)\.[0-9]+"' | head -10 | while read line; do
            VERSION=$(echo "$line" | grep -oP 'v[0-9.]+-(alpha|beta)\.[0-9]+')
            echo -e "  - ${GREEN}$VERSION${NC}"
        done
        echo ""

        read -p "请输入要安装的版本号 (例如 v0.10.6-alpha.2): " TARGET_VERSION

        if [ -z "$TARGET_VERSION" ]; then
            log_error "版本号不能为空"
            exit 1
        fi
        ;;

    3)
        # 手动输入版本号
        log_step "[2/6] 手动输入版本号..."
        read -p "请输入版本号 (例如 v0.10.6-alpha.2): " TARGET_VERSION

        if [ -z "$TARGET_VERSION" ]; then
            log_error "版本号不能为空"
            exit 1
        fi
        ;;

    4)
        # 回滚到稳定版
        log_step "[2/6] 准备回滚到稳定版..."
        TARGET_VERSION="latest"
        log_warning "将回滚到稳定版 (latest)"
        ;;

    *)
        log_error "无效选择"
        exit 1
        ;;
esac

TARGET_IMAGE="${DOCKER_IMAGE}:${TARGET_VERSION}"

# 确认升级
echo ""
read -p "是否继续升级到 $TARGET_IMAGE ? (y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "升级已取消。"
    exit 0
fi

# ==================== 备份配置 ====================

log_step "[3/6] 备份当前配置..."

mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/docker-compose_$(date +%Y%m%d_%H%M%S).yml"
cp "$COMPOSE_FILE" "$BACKUP_FILE"

# 备份当前版本的 docker-compose.yml（用于回滚）
VERSION_BACKUP="$BACKUP_DIR/docker-compose_before_${TARGET_VERSION//\//_}_$(date +%Y%m%d_%H%M%S).yml"
cp "$COMPOSE_FILE" "$VERSION_BACKUP"

log_success "配置已备份: $BACKUP_FILE"
log_success "版本备份: $VERSION_BACKUP"

# ==================== 更新 docker-compose.yml ====================

log_step "[4/6] 更新 docker-compose.yml..."

# 使用 sed 替换镜像标签
sed -i "s|image:.*calciumion/new-api.*|image: ${TARGET_IMAGE}|g" "$COMPOSE_FILE"

log_success "镜像标签已更新为: ${GREEN}$TARGET_IMAGE${NC}"

# ==================== 拉取新镜像 ====================

log_step "[5/6] 拉取新镜像..."

log_info "正在拉取 ${TARGET_IMAGE}（可能需要几分钟）..."

if docker pull "$TARGET_IMAGE" 2>&1 | tee /tmp/alpha_pull.log; then
    log_success "镜像拉取完成"

    # 获取新镜像信息
    NEW_IMAGE_ID=$(docker images --format "{{.ID}}" "$TARGET_IMAGE" 2>/dev/null | head -1)
    NEW_CREATED=$(docker images --format "{{.CreatedAt}}" "$TARGET_IMAGE" 2>/dev/null | head -1)

    log_info "新镜像 ID: ${GREEN}${NEW_IMAGE_ID:0:12}${NC}"
    log_info "创建时间: $NEW_CREATED"
else
    log_error "镜像拉取失败"

    # 回滚配置文件
    cp "$VERSION_BACKUP" "$COMPOSE_FILE"
    log_warning "配置文件已回滚"

    exit 1
fi

# ==================== 重建服务 ====================

log_step "[6/6] 重建服务容器..."

log_info "正在使用新镜像重建容器..."

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
        cp "$VERSION_BACKUP" "$COMPOSE_FILE"
        $COMPOSE_CMD down
        $COMPOSE_CMD up -d

        log_warning "已回滚到旧版本"
        log_info "请检查日志: cd $SERVICE_DIR && $COMPOSE_CMD logs -f new-api"
        exit 1
    fi
else
    log_error "容器重建失败"

    # 回滚配置文件
    cp "$VERSION_BACKUP" "$COMPOSE_FILE"
    log_warning "配置文件已回滚"

    exit 1
fi

# ==================== 清理旧镜像 ====================

log_info "正在清理未使用的镜像..."

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
echo "       New-API Alpha 升级完成！"
echo "================================================"
echo -e "${NC}"
echo ""
echo -e "${CYAN}[版本信息]${NC}"
echo -e "原版本: ${YELLOW}$CURRENT_IMAGE_TAG${NC}"
echo -e "新版本: ${GREEN}$TARGET_IMAGE${NC}"
echo ""
echo -e "${CYAN}[镜像信息]${NC}"
echo -e "旧镜像 ID: ${YELLOW}${CURRENT_IMAGE_ID:0:12}${NC}"
echo -e "新镜像 ID: ${GREEN}${NEW_IMAGE_ID:0:12}${NC}"
echo ""
echo -e "${CYAN}[服务状态]${NC}"

# 显示服务状态
$COMPOSE_CMD ps

echo ""
echo -e "${CYAN}[配置保留]${NC}"
echo -e "环境变量:   ${GREEN}✓ 已保留${NC}"
echo -e "数据库:     ${GREEN}✓ 已保留${NC}"
echo -e "Redis:      ${GREEN}✓ 已保留${NC}"
echo -e "配置备份:   $VERSION_BACKUP"
echo ""
echo -e "${CYAN}[回滚方法]${NC}"
echo -e "如果需要回滚，运行:"
echo -e "  cp $VERSION_BACKUP $COMPOSE_FILE"
echo -e "  cd $SERVICE_DIR && $COMPOSE_CMD down && $COMPOSE_CMD up -d"
echo ""
echo -e "${CYAN}[常用命令]${NC}"
echo -e "查看日志:   cd $SERVICE_DIR && $COMPOSE_CMD logs -f new-api"
echo -e "查看状态:   cd $SERVICE_DIR && $COMPOSE_CMD ps"
echo -e "重启服务:   cd $SERVICE_DIR && $COMPOSE_CMD restart"
echo ""
echo -e "${GREEN}升级完成！所有数据和配置已完整保留。${NC}"
echo "================================================"
echo ""
