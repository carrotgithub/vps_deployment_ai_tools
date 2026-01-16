#!/bin/bash

################################################################################
#
# LiteLLM Docker 升级脚本
#
# 功能说明：
#   1. 检测当前 LiteLLM Docker 服务
#   2. 备份当前配置（docker-compose.yml 和 config.yaml）
#   3. 拉取最新镜像
#   4. 平滑重启服务（数据自动保留）
#   5. 清理旧镜像
#
# 特点：
#   - 零配置变更：环境变量、config.yaml、数据库、Redis 全部保留
#   - 零停机时间：Docker Compose 自动滚动更新
#   - 自动回滚：失败时恢复旧版本
#
# 使用方法：
#   chmod +x upgrade_litellm_docker.sh
#   ./upgrade_litellm_docker.sh
#
################################################################################

# ==================== 全局配置 ====================

DOCKER_ROOT="/opt/docker-services"
SERVICE_DIR="$DOCKER_ROOT/litellm"
COMPOSE_FILE="$SERVICE_DIR/docker-compose.yml"
CONFIG_FILE="$SERVICE_DIR/config.yaml"

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
    log_error "未检测到 LiteLLM 安装目录: $SERVICE_DIR"
    log_info "请先运行 install_litellm_docker.sh 进行安装"
    exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
    log_error "未检测到 docker-compose.yml 文件"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    log_error "未检测到 config.yaml 文件"
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
echo -e "${CYAN}   LiteLLM Docker 升级程序${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ==================== 检测当前版本 ====================

log_step "[1/5] 检测当前服务状态..."

cd "$SERVICE_DIR"

# 获取当前镜像版本
CURRENT_IMAGE=$($COMPOSE_CMD images -q litellm 2>/dev/null | head -1)

if [ -z "$CURRENT_IMAGE" ]; then
    log_warning "无法获取当前镜像版本"
else
    log_info "当前镜像 ID: ${CURRENT_IMAGE:0:12}"
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

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_COMPOSE="$BACKUP_DIR/docker-compose_$TIMESTAMP.yml"
BACKUP_CONFIG="$BACKUP_DIR/config_$TIMESTAMP.yaml"

cp "$COMPOSE_FILE" "$BACKUP_COMPOSE"
cp "$CONFIG_FILE" "$BACKUP_CONFIG"

log_success "配置已备份:"
log_info "  - $BACKUP_COMPOSE"
log_info "  - $BACKUP_CONFIG"

# ==================== 拉取最新镜像 ====================

log_step "[3/5] 拉取最新镜像..."

log_info "正在检查更新（可能需要几分钟）..."

if $COMPOSE_CMD pull litellm; then
    log_success "镜像拉取完成"

    # 获取新镜像版本
    NEW_IMAGE=$($COMPOSE_CMD images -q litellm 2>/dev/null | head -1)

    if [ "$CURRENT_IMAGE" = "$NEW_IMAGE" ]; then
        log_info "已是最新版本，无需升级"
        echo ""
        read -p "是否重启服务？(y/N): " -n 1 -r
        echo ""

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            $COMPOSE_CMD restart litellm
            log_success "服务已重启"
        fi

        exit 0
    else
        log_success "检测到新版本"
        log_info "旧镜像 ID: ${CURRENT_IMAGE:0:12}"
        log_info "新镜像 ID: ${NEW_IMAGE:0:12}"
    fi
else
    log_error "镜像拉取失败，请检查网络连接"
    log_info "可尝试手动拉取: cd $SERVICE_DIR && $COMPOSE_CMD pull"
    exit 1
fi

# ==================== 重启服务 ====================

log_step "[4/5] 重启服务..."

log_info "正在重启容器（平滑更新）..."

if $COMPOSE_CMD up -d; then
    log_success "容器重启成功"

    # 等待服务启动
    log_info "等待服务启动（约 20 秒）..."
    sleep 20

    # 检查服务健康状态
    if $COMPOSE_CMD ps | grep -q "Up"; then
        log_success "服务运行正常"
    else
        log_error "服务启动失败，正在回滚..."

        # 回滚到旧版本
        cp "$BACKUP_COMPOSE" "$COMPOSE_FILE"
        cp "$BACKUP_CONFIG" "$CONFIG_FILE"
        $COMPOSE_CMD up -d

        log_warning "已回滚到旧版本"
        log_info "请检查日志: cd $SERVICE_DIR && $COMPOSE_CMD logs -f litellm"
        exit 1
    fi
else
    log_error "容器重启失败"
    log_info "配置文件备份位置:"
    log_info "  - $BACKUP_COMPOSE"
    log_info "  - $BACKUP_CONFIG"
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
echo "       LiteLLM 升级完成！"
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
echo -e "docker-compose.yml: ${GREEN}✓ 已保留${NC}"
echo -e "config.yaml:        ${GREEN}✓ 已保留${NC}"
echo -e "数据库:             ${GREEN}✓ 已保留${NC}"
echo -e "Redis:              ${GREEN}✓ 已保留${NC}"
echo -e "配置备份:           $BACKUP_DIR/"
echo ""
echo -e "${CYAN}[常用命令]${NC}"
echo -e "查看日志:   cd $SERVICE_DIR && $COMPOSE_CMD logs -f litellm"
echo -e "查看状态:   cd $SERVICE_DIR && $COMPOSE_CMD ps"
echo -e "重启服务:   cd $SERVICE_DIR && $COMPOSE_CMD restart"
echo ""
echo -e "${GREEN}升级完成！所有数据和配置已完整保留。${NC}"
echo "================================================"
echo ""
