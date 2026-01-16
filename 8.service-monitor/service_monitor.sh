#!/bin/bash

################################################################################
# 轻量级服务监控脚本 - 主程序
# 功能：监控服务状态、系统资源、HTTP端点等，异常时发送邮件告警
# 设计：模块化架构，易于扩展新的监控项
################################################################################

# 注意：不使用 set -e，因为检查函数会返回非零值表示异常
# 但我们希望继续执行后续检查，最后统一发送告警邮件

# =============================================================================
# 全局配置
# =============================================================================

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 配置文件路径
CONFIG_FILE="${SCRIPT_DIR}/config.conf"

# 日志目录
LOG_DIR="/var/log/service-monitor"
LOG_FILE="${LOG_DIR}/monitor_$(date +%Y%m%d).log"

# 状态文件（记录上次状态，避免重复告警）
STATE_FILE="${LOG_DIR}/service_state.json"

# 临时文件（存储本次检测结果）
TEMP_RESULT_FILE="/tmp/monitor_result_$$.txt"
TEMP_ALERT_FILE="/tmp/monitor_alert_$$.txt"

# 告警级别颜色
COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'

# =============================================================================
# 工具函数
# =============================================================================

# 日志函数
log_info() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${COLOR_YELLOW}[WARN]${COLOR_RESET} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${COLOR_RED}[ERROR]${COLOR_RESET} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${COLOR_GREEN}[OK]${COLOR_RESET} $*" | tee -a "$LOG_FILE"
}

# 初始化日志目录
init_log_dir() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
        log_info "创建日志目录: $LOG_DIR"
    fi
}

# 加载配置文件
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件不存在: $CONFIG_FILE"
        echo "请先创建配置文件 config.conf"
        exit 1
    fi

    # 使用 source 加载配置
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    log_info "配置文件加载成功"
}

# 读取上次状态
load_previous_state() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo "{}"
    fi
}

# 保存当前状态
save_current_state() {
    local state_content="$1"
    echo "$state_content" > "$STATE_FILE"
}

# 检查状态是否变化（用于判断是否需要告警）
# 参数：$1=检查项名称, $2=当前状态(ok/fail)
check_state_changed() {
    local item_name="$1"
    local current_state="$2"

    # 读取上次状态
    local previous_states
    previous_states=$(load_previous_state)

    # 检查上次状态（使用简单的文本匹配）
    if echo "$previous_states" | grep -q "\"$item_name\":\"ok\""; then
        local prev_state="ok"
    elif echo "$previous_states" | grep -q "\"$item_name\":\"fail\""; then
        local prev_state="fail"
    else
        local prev_state="unknown"
    fi

    # 状态变化判断：
    # 1. 首次检测 (unknown -> fail) -> 需要告警
    # 2. 正常变异常 (ok -> fail) -> 需要告警
    # 3. 异常持续 (fail -> fail) -> 不告警（避免重复）
    # 4. 恢复正常 (fail -> ok) -> 记录但不告警（可选：发送恢复通知）
    if [ "$current_state" = "fail" ]; then
        if [ "$prev_state" = "ok" ] || [ "$prev_state" = "unknown" ]; then
            return 0  # 需要告警
        fi
    fi

    return 1  # 不需要告警
}

# =============================================================================
# 监控模块 - Systemd 服务
# =============================================================================

# 检查 systemd 服务状态
# 参数：$1=服务名称, $2=服务描述
check_systemd_service() {
    local service_name="$1"
    local service_desc="$2"
    local item_key="systemd:$service_name"

    # 执行检查
    if systemctl is-active --quiet "$service_name"; then
        log_success "✓ systemd服务 [$service_name] 运行正常"
        echo "{\"$item_key\":\"ok\"}" >> "$TEMP_RESULT_FILE"
        return 0
    else
        local status
        status=$(systemctl is-active "$service_name" 2>&1 || true)
        log_error "✗ systemd服务 [$service_name] 状态异常: $status"
        echo "{\"$item_key\":\"fail\"}" >> "$TEMP_RESULT_FILE"

        # 检查是否需要告警
        if check_state_changed "$item_key" "fail"; then
            echo "类型: systemd服务" >> "$TEMP_ALERT_FILE"
            echo "名称: $service_name" >> "$TEMP_ALERT_FILE"
            echo "描述: $service_desc" >> "$TEMP_ALERT_FILE"
            echo "状态: $status" >> "$TEMP_ALERT_FILE"
            echo "---" >> "$TEMP_ALERT_FILE"
        fi

        return 1
    fi
}

# =============================================================================
# 监控模块 - Docker 容器
# =============================================================================

# 检查 Docker 容器状态
# 参数：$1=容器名称, $2=容器描述
check_docker_container() {
    local container_name="$1"
    local container_desc="$2"
    local item_key="docker:$container_name"

    # 检查 Docker 是否安装
    if ! command -v docker &> /dev/null; then
        log_warn "Docker 未安装，跳过容器检查: $container_name"
        return 0
    fi

    # 检查容器状态
    local status
    status=$(docker inspect --format='{{.State.Status}}' "$container_name" 2>&1 || echo "not_found")

    if [ "$status" = "running" ]; then
        log_success "✓ Docker容器 [$container_name] 运行正常"
        echo "{\"$item_key\":\"ok\"}" >> "$TEMP_RESULT_FILE"
        return 0
    else
        log_error "✗ Docker容器 [$container_name] 状态异常: $status"
        echo "{\"$item_key\":\"fail\"}" >> "$TEMP_RESULT_FILE"

        if check_state_changed "$item_key" "fail"; then
            echo "类型: Docker容器" >> "$TEMP_ALERT_FILE"
            echo "名称: $container_name" >> "$TEMP_ALERT_FILE"
            echo "描述: $container_desc" >> "$TEMP_ALERT_FILE"
            echo "状态: $status" >> "$TEMP_ALERT_FILE"
            echo "---" >> "$TEMP_ALERT_FILE"
        fi

        return 1
    fi
}

# =============================================================================
# 监控模块 - HTTP 端点
# =============================================================================

# 检查 HTTP 端点
# 参数：$1=URL, $2=描述, $3=期望状态码(可选，默认200), $4=超时时间(可选，默认10秒)
check_http_endpoint() {
    local url="$1"
    local desc="$2"
    local expected_status="${3:-200}"
    local timeout="${4:-10}"
    local item_key="http:$url"

    # 使用 curl 检查 HTTP 端点
    local http_code
    http_code=$(curl -o /dev/null -s -w "%{http_code}" --connect-timeout "$timeout" --max-time "$timeout" "$url" 2>&1 || echo "000")

    if [ "$http_code" = "$expected_status" ]; then
        log_success "✓ HTTP端点 [$url] 响应正常 (HTTP $http_code)"
        echo "{\"$item_key\":\"ok\"}" >> "$TEMP_RESULT_FILE"
        return 0
    else
        log_error "✗ HTTP端点 [$url] 响应异常 (HTTP $http_code, 期望 $expected_status)"
        echo "{\"$item_key\":\"fail\"}" >> "$TEMP_RESULT_FILE"

        if check_state_changed "$item_key" "fail"; then
            echo "类型: HTTP端点" >> "$TEMP_ALERT_FILE"
            echo "名称: $url" >> "$TEMP_ALERT_FILE"
            echo "描述: $desc" >> "$TEMP_ALERT_FILE"
            echo "状态: HTTP $http_code (期望 $expected_status)" >> "$TEMP_ALERT_FILE"
            echo "---" >> "$TEMP_ALERT_FILE"
        fi

        return 1
    fi
}

# =============================================================================
# 监控模块 - 系统资源（CPU、内存、磁盘）
# =============================================================================

# 检查 CPU 使用率
# 参数：$1=告警阈值（百分比，默认90）
check_cpu_usage() {
    local threshold="${1:-90}"
    local item_key="resource:cpu"

    # 获取 CPU 使用率（使用多次采样取平均，避免瞬时波动）
    local cpu_usage

    # 方法1: 使用 vmstat 2次采样（第二次数据更准确）
    if command -v vmstat &> /dev/null; then
        # vmstat 输出的最后一列是 idle%，我们要的是 100 - idle
        local cpu_idle
        cpu_idle=$(vmstat 1 2 | tail -1 | awk '{print $15}')
        if [ -n "$cpu_idle" ] && [ "$cpu_idle" -ge 0 ] 2>/dev/null; then
            cpu_usage=$(awk "BEGIN {printf \"%.1f\", 100 - $cpu_idle}")
        fi
    fi

    # 方法2: 如果 vmstat 不可用，使用 top（多次采样）
    if [ -z "$cpu_usage" ]; then
        # top 输出格式：%Cpu(s):  0.1 us,  0.2 sy,  0.0 ni, 99.7 id, ...
        # 提取 id（idle）百分比，计算使用率 = 100 - idle
        local cpu_idle
        cpu_idle=$(top -bn2 -d1 | grep "Cpu(s)" | tail -1 | sed "s/.*, *\([0-9.]*\) id.*/\1/")

        if [ -n "$cpu_idle" ]; then
            cpu_usage=$(awk "BEGIN {printf \"%.1f\", 100 - $cpu_idle}")
        else
            log_warn "无法获取 CPU 使用率"
            return 0
        fi
    fi

    # 转换为整数比较（同时处理阈值）
    local cpu_int=${cpu_usage%.*}
    local threshold_int=${threshold%.*}

    # 如果是小数且小于1，转换为0（避免空值）
    cpu_int=${cpu_int:-0}
    threshold_int=${threshold_int:-0}

    if [ "$cpu_int" -lt "$threshold_int" ]; then
        log_success "✓ CPU使用率正常: ${cpu_usage}% (阈值: ${threshold}%)"
        echo "{\"$item_key\":\"ok\"}" >> "$TEMP_RESULT_FILE"
        return 0
    else
        log_error "✗ CPU使用率过高: ${cpu_usage}% (阈值: ${threshold}%)"
        echo "{\"$item_key\":\"fail\"}" >> "$TEMP_RESULT_FILE"

        if check_state_changed "$item_key" "fail"; then
            echo "类型: 系统资源" >> "$TEMP_ALERT_FILE"
            echo "名称: CPU使用率" >> "$TEMP_ALERT_FILE"
            echo "描述: CPU负载过高" >> "$TEMP_ALERT_FILE"
            echo "状态: 当前 ${cpu_usage}%, 阈值 ${threshold}%" >> "$TEMP_ALERT_FILE"
            echo "---" >> "$TEMP_ALERT_FILE"
        fi

        return 1
    fi
}

# 检查内存使用率
# 参数：$1=告警阈值（百分比，默认90）
check_memory_usage() {
    local threshold="${1:-90}"
    local item_key="resource:memory"

    # 获取内存使用率
    local mem_info
    mem_info=$(free | grep Mem)
    local total=$(echo "$mem_info" | awk '{print $2}')
    local used=$(echo "$mem_info" | awk '{print $3}')
    local mem_usage=$((used * 100 / total))

    if [ "$mem_usage" -lt "$threshold" ]; then
        log_success "✓ 内存使用率正常: ${mem_usage}% (阈值: ${threshold}%)"
        echo "{\"$item_key\":\"ok\"}" >> "$TEMP_RESULT_FILE"
        return 0
    else
        log_error "✗ 内存使用率过高: ${mem_usage}% (阈值: ${threshold}%)"
        echo "{\"$item_key\":\"fail\"}" >> "$TEMP_RESULT_FILE"

        if check_state_changed "$item_key" "fail"; then
            echo "类型: 系统资源" >> "$TEMP_ALERT_FILE"
            echo "名称: 内存使用率" >> "$TEMP_ALERT_FILE"
            echo "描述: 内存负载过高" >> "$TEMP_ALERT_FILE"
            echo "状态: 当前 ${mem_usage}%, 阈值 ${threshold}%" >> "$TEMP_ALERT_FILE"
            echo "---" >> "$TEMP_ALERT_FILE"
        fi

        return 1
    fi
}

# 检查磁盘使用率
# 参数：$1=挂载点, $2=告警阈值（百分比，默认90）
check_disk_usage() {
    local mount_point="${1:-/}"
    local threshold="${2:-90}"
    local item_key="resource:disk:$mount_point"

    # 获取磁盘使用率
    local disk_usage
    disk_usage=$(df -h "$mount_point" | tail -1 | awk '{print $5}' | sed 's/%//')

    if [ "$disk_usage" -lt "$threshold" ]; then
        log_success "✓ 磁盘使用率正常 [$mount_point]: ${disk_usage}% (阈值: ${threshold}%)"
        echo "{\"$item_key\":\"ok\"}" >> "$TEMP_RESULT_FILE"
        return 0
    else
        log_error "✗ 磁盘使用率过高 [$mount_point]: ${disk_usage}% (阈值: ${threshold}%)"
        echo "{\"$item_key\":\"fail\"}" >> "$TEMP_RESULT_FILE"

        if check_state_changed "$item_key" "fail"; then
            echo "类型: 系统资源" >> "$TEMP_ALERT_FILE"
            echo "名称: 磁盘使用率 ($mount_point)" >> "$TEMP_ALERT_FILE"
            echo "描述: 磁盘空间不足" >> "$TEMP_ALERT_FILE"
            echo "状态: 当前 ${disk_usage}%, 阈值 ${threshold}%" >> "$TEMP_ALERT_FILE"
            echo "---" >> "$TEMP_ALERT_FILE"
        fi

        return 1
    fi
}

# =============================================================================
# 监控模块 - 数据库连接（PostgreSQL、Redis）
# =============================================================================

# 检查 PostgreSQL 连接
# 参数：$1=容器名称或主机, $2=数据库名, $3=用户名, $4=密码(可选)
check_postgres_connection() {
    local container_or_host="$1"
    local database="$2"
    local username="$3"
    local password="$4"
    local item_key="database:postgres:$container_or_host"

    # 判断是容器还是远程主机
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container_or_host}$"; then
        # Docker 容器方式连接
        if docker exec "$container_or_host" psql -U "$username" -d "$database" -c "SELECT 1;" &> /dev/null; then
            log_success "✓ PostgreSQL连接正常 [$container_or_host/$database]"
            echo "{\"$item_key\":\"ok\"}" >> "$TEMP_RESULT_FILE"
            return 0
        else
            log_error "✗ PostgreSQL连接失败 [$container_or_host/$database]"
            echo "{\"$item_key\":\"fail\"}" >> "$TEMP_RESULT_FILE"

            if check_state_changed "$item_key" "fail"; then
                echo "类型: 数据库连接" >> "$TEMP_ALERT_FILE"
                echo "名称: PostgreSQL ($container_or_host)" >> "$TEMP_ALERT_FILE"
                echo "描述: 数据库连接失败" >> "$TEMP_ALERT_FILE"
                echo "状态: 无法连接到数据库 $database" >> "$TEMP_ALERT_FILE"
                echo "---" >> "$TEMP_ALERT_FILE"
            fi

            return 1
        fi
    else
        log_warn "PostgreSQL 远程连接检查暂未实现，跳过: $container_or_host"
        return 0
    fi
}

# 检查 Redis 连接
# 参数：$1=容器名称或主机:端口
check_redis_connection() {
    local container_or_host="$1"
    local item_key="database:redis:$container_or_host"

    # 判断是容器还是远程主机
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container_or_host}$"; then
        # Docker 容器方式连接
        if docker exec "$container_or_host" redis-cli ping 2>/dev/null | grep -q "PONG"; then
            log_success "✓ Redis连接正常 [$container_or_host]"
            echo "{\"$item_key\":\"ok\"}" >> "$TEMP_RESULT_FILE"
            return 0
        else
            log_error "✗ Redis连接失败 [$container_or_host]"
            echo "{\"$item_key\":\"fail\"}" >> "$TEMP_RESULT_FILE"

            if check_state_changed "$item_key" "fail"; then
                echo "类型: 数据库连接" >> "$TEMP_ALERT_FILE"
                echo "名称: Redis ($container_or_host)" >> "$TEMP_ALERT_FILE"
                echo "描述: Redis连接失败" >> "$TEMP_ALERT_FILE"
                echo "状态: 无法连接到Redis" >> "$TEMP_ALERT_FILE"
                echo "---" >> "$TEMP_ALERT_FILE"
            fi

            return 1
        fi
    else
        log_warn "Redis 远程连接检查暂未实现，跳过: $container_or_host"
        return 0
    fi
}

# =============================================================================
# 告警发送
# =============================================================================

# 发送邮件告警
send_email_alert() {
    # 检查是否有告警
    if [ ! -f "$TEMP_ALERT_FILE" ] || [ ! -s "$TEMP_ALERT_FILE" ]; then
        log_info "没有新的告警需要发送"
        return 0
    fi

    # 统计告警数量
    local alert_count
    alert_count=$(grep -c "^---$" "$TEMP_ALERT_FILE" || echo "0")

    if [ "$alert_count" -eq 0 ]; then
        log_info "没有新的告警需要发送"
        return 0
    fi

    log_warn "检测到 $alert_count 个服务异常，准备发送告警邮件..."

    # 调用邮件发送脚本
    if [ -f "${SCRIPT_DIR}/send_email.sh" ]; then
        bash "${SCRIPT_DIR}/send_email.sh" "$alert_count" "$TEMP_ALERT_FILE"
    else
        log_error "邮件发送脚本不存在: ${SCRIPT_DIR}/send_email.sh"
        log_warn "告警详情："
        cat "$TEMP_ALERT_FILE" | tee -a "$LOG_FILE"
    fi
}

# =============================================================================
# 主函数
# =============================================================================

main() {
    log_info "========================================="
    log_info "开始服务监控检查"
    log_info "========================================="

    # 初始化
    init_log_dir
    load_config

    # 清空临时文件
    > "$TEMP_RESULT_FILE"
    > "$TEMP_ALERT_FILE"

    # 执行监控检查（根据配置文件动态调用）
    # 这里提供调用示例，实际会从配置文件读取

    # 示例：监控 systemd 服务
    if [ -n "$MONITOR_SYSTEMD_SERVICES" ]; then
        log_info "--- 检查 Systemd 服务 ---"
        # 配置格式：服务名:描述;服务名:描述
        IFS=';' read -ra SERVICES <<< "$MONITOR_SYSTEMD_SERVICES"
        for service in "${SERVICES[@]}"; do
            IFS=':' read -r name desc <<< "$service"
            check_systemd_service "$name" "$desc" || true
        done
    fi

    # 示例：监控 Docker 容器
    if [ -n "$MONITOR_DOCKER_CONTAINERS" ]; then
        log_info "--- 检查 Docker 容器 ---"
        IFS=';' read -ra CONTAINERS <<< "$MONITOR_DOCKER_CONTAINERS"
        for container in "${CONTAINERS[@]}"; do
            IFS=':' read -r name desc <<< "$container"
            check_docker_container "$name" "$desc" || true
        done
    fi

    # 示例：监控 HTTP 端点
    if [ -n "$MONITOR_HTTP_ENDPOINTS" ]; then
        log_info "--- 检查 HTTP 端点 ---"
        IFS=';' read -ra ENDPOINTS <<< "$MONITOR_HTTP_ENDPOINTS"
        for endpoint in "${ENDPOINTS[@]}"; do
            IFS='|' read -r url desc status timeout <<< "$endpoint"
            check_http_endpoint "$url" "$desc" "${status:-200}" "${timeout:-10}" || true
        done
    fi

    # 示例：监控系统资源
    if [ "$MONITOR_CPU" = "true" ]; then
        log_info "--- 检查 CPU 使用率 ---"
        check_cpu_usage "${CPU_THRESHOLD:-90}" || true
    fi

    if [ "$MONITOR_MEMORY" = "true" ]; then
        log_info "--- 检查内存使用率 ---"
        check_memory_usage "${MEMORY_THRESHOLD:-90}" || true
    fi

    if [ "$MONITOR_DISK" = "true" ]; then
        log_info "--- 检查磁盘使用率 ---"
        # 支持多个挂载点，格式：/:/opt:/var
        IFS=':' read -ra MOUNT_POINTS <<< "${DISK_MOUNT_POINTS:-/}"
        for mount_point in "${MOUNT_POINTS[@]}"; do
            check_disk_usage "$mount_point" "${DISK_THRESHOLD:-90}" || true
        done
    fi

    # 示例：监控数据库连接
    if [ -n "$MONITOR_POSTGRES" ]; then
        log_info "--- 检查 PostgreSQL 连接 ---"
        IFS=';' read -ra POSTGRES_DBS <<< "$MONITOR_POSTGRES"
        for pg in "${POSTGRES_DBS[@]}"; do
            IFS='|' read -r container db user pass <<< "$pg"
            check_postgres_connection "$container" "$db" "$user" "$pass" || true
        done
    fi

    if [ -n "$MONITOR_REDIS" ]; then
        log_info "--- 检查 Redis 连接 ---"
        IFS=';' read -ra REDIS_INSTANCES <<< "$MONITOR_REDIS"
        for redis in "${REDIS_INSTANCES[@]}"; do
            check_redis_connection "$redis" || true
        done
    fi

    # 合并所有检查结果到状态文件
    if [ -f "$TEMP_RESULT_FILE" ]; then
        # 简单合并为 JSON（手动拼接）
        echo -n "{" > "$STATE_FILE"
        sed 's/^{//; s/}$//' "$TEMP_RESULT_FILE" | paste -sd ',' >> "$STATE_FILE"
        echo "}" >> "$STATE_FILE"
    fi

    # 发送告警
    send_email_alert

    # 清理临时文件
    rm -f "$TEMP_RESULT_FILE" "$TEMP_ALERT_FILE"

    log_info "========================================="
    log_info "监控检查完成"
    log_info "========================================="
}

# 执行主函数
main "$@"
