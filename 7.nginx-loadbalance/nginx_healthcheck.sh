#!/bin/bash

################################################################################
#
# Nginx Stream 健康检查脚本
#
# 功能说明：
#   1. 定期检查所有CN2节点的健康状态
#   2. 自动下线故障节点（在Nginx配置中添加down标记）
#   3. 自动上线恢复节点（移除down标记）
#   4. 发送告警通知
#
# 使用方法：
#   ./nginx_healthcheck.sh
#
#   或添加到cron（每分钟检查一次）：
#   * * * * * /root/nginx_healthcheck.sh >> /var/log/nginx_healthcheck_cron.log 2>&1
#
################################################################################

# ==================== 配置区域 ====================

# CN2节点列表（格式：IP:名称）
NODES=(
  "1.2.3.4:CN2-上海"
  "5.6.7.8:CN2-广州"
  "9.10.11.12:CN2-深圳"
)

# 健康检查配置
HEALTH_CHECK_URL="/health-proxy"
TIMEOUT=5
DOMAIN="newapi.example.com"  # 【需替换】替换为你的域名

# Nginx配置文件路径
NGINX_STREAM_CONF="/etc/nginx/stream.d/newapi_lb.conf"

# 日志文件
LOG_FILE="/var/log/nginx_healthcheck.log"

# 告警配置（可选）
ALERT_EMAIL=""  # 填入邮箱地址启用邮件告警
WEBHOOK_URL=""  # 填入Webhook URL启用告警

# ==================== 颜色定义 ====================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ==================== 函数定义 ====================

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_node() {
    local ip="$1"
    local url="https://$ip$HEALTH_CHECK_URL"

    curl -sf --max-time $TIMEOUT \
        -H "Host: $DOMAIN" \
        --resolve "$DOMAIN:443:$ip" \
        "$url" > /dev/null 2>&1

    return $?
}

is_node_down() {
    local ip="$1"
    grep -q "server $ip:443.*down" "$NGINX_STREAM_CONF"
    return $?
}

mark_node_down() {
    local ip="$1"
    local name="$2"

    if is_node_down "$ip"; then
        return 0  # 已经标记为down，无需重复操作
    fi

    # 在server行添加 down标记
    sed -i "/server $ip:443/ s/;/ down;/" "$NGINX_STREAM_CONF"

    # 重载Nginx
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1
        log_message "[DOWN] 节点 $name ($ip) 已下线"
        send_alert "节点下线" "$name ($ip) 健康检查失败，已自动下线"
        return 0
    else
        log_message "[ERROR] 配置错误，回滚节点 $name ($ip) 的下线操作"
        sed -i "/server $ip:443/ s/ down;/;/" "$NGINX_STREAM_CONF"
        return 1
    fi
}

mark_node_up() {
    local ip="$1"
    local name="$2"

    if ! is_node_down "$ip"; then
        return 0  # 已经是正常状态
    fi

    # 移除 down标记
    sed -i "/server $ip:443/ s/ down;/;/" "$NGINX_STREAM_CONF"

    # 重载Nginx
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1
        log_message "[UP] 节点 $name ($ip) 已恢复上线"
        send_alert "节点恢复" "$name ($ip) 健康检查恢复，已自动上线"
        return 0
    else
        log_message "[ERROR] 配置错误，回滚节点 $name ($ip) 的上线操作"
        sed -i "/server $ip:443/ s/;/ down;/" "$NGINX_STREAM_CONF"
        return 1
    fi
}

send_alert() {
    local title="$1"
    local message="$2"
    local full_message="[Nginx LB告警] $title\n$message\n时间: $(date '+%Y-%m-%d %H:%M:%S')"

    # 邮件告警
    if [ -n "$ALERT_EMAIL" ]; then
        echo -e "$full_message" | mail -s "[告警] $title" "$ALERT_EMAIL"
    fi

    # Webhook告警（企业微信格式）
    if [ -n "$WEBHOOK_URL" ]; then
        curl -s -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"$full_message\"}}" \
            > /dev/null 2>&1
    fi
}

# ==================== 主程序 ====================

log_message "====== 开始健康检查 ======"

total_nodes=${#NODES[@]}
healthy_count=0
down_count=0
failed_nodes=()

for node in "${NODES[@]}"; do
    IP="${node%%:*}"
    NAME="${node##*:}"

    if check_node "$IP"; then
        echo -e "${GREEN}[OK]${NC} $NAME ($IP)"
        mark_node_up "$IP" "$NAME"
        ((healthy_count++))
    else
        echo -e "${RED}[FAIL]${NC} $NAME ($IP)"
        mark_node_down "$IP" "$NAME"
        failed_nodes+=("$NAME ($IP)")
        ((down_count++))
    fi
done

log_message "健康检查完成: 健康=$healthy_count, 故障=$down_count, 总数=$total_nodes"

# 如果所有节点都故障，发送紧急告警
if [ $down_count -eq $total_nodes ]; then
    log_message "[CRITICAL] 所有CN2节点都已故障！"
    send_alert "严重告警：所有节点故障" "所有CN2节点健康检查都失败，服务可能完全不可用！"
fi

log_message "====== 健康检查结束 ======"

exit 0
