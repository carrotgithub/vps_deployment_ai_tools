#!/bin/bash

################################################################################
#
# DNS轮询健康检查脚本
#
# 功能说明：
#   1. 定期检查所有CN2节点的健康状态
#   2. 发现故障节点时发送告警
#   3. 生成健康报告
#
# 使用方法：
#   ./health_check.sh
#
#   或添加到cron：
#   */5 * * * * /root/health_check.sh >> /var/log/cn2_health.log 2>&1
#
################################################################################

# ==================== 配置区域 ====================

# CN2节点列表（格式：IP:名称）
NODES=(
  "1.2.3.4:CN2-上海"
  "5.6.7.8:CN2-广州"
  "9.10.11.12:CN2-深圳"
)

# 域名
DOMAIN="newapi.example.com"  # 【需替换】替换为你的域名

# 健康检查超时（秒）
TIMEOUT=5

# 告警邮箱（留空则不发送邮件）
ALERT_EMAIL=""

# Webhook URL（留空则不发送，支持企业微信/钉钉/Slack等）
WEBHOOK_URL=""

# ==================== 颜色定义 ====================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== 函数定义 ====================

check_node() {
    local ip="$1"
    local name="$2"
    local url="https://$ip/health-proxy"

    # 发送健康检查请求
    response=$(curl -sf --max-time $TIMEOUT \
        -H "Host: $DOMAIN" \
        --resolve "$DOMAIN:443:$ip" \
        "$url" 2>&1)

    return $?
}

send_alert() {
    local message="$1"

    # 邮件告警
    if [ -n "$ALERT_EMAIL" ]; then
        echo "$message" | mail -s "[告警] CN2节点异常" "$ALERT_EMAIL"
    fi

    # Webhook告警（企业微信格式）
    if [ -n "$WEBHOOK_URL" ]; then
        curl -s -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"$message\"}}" \
            > /dev/null 2>&1
    fi
}

# ==================== 主程序 ====================

echo "========================================"
echo " CN2节点健康检查"
echo " 检查时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""

total_nodes=${#NODES[@]}
healthy_count=0
failed_nodes=()

for node in "${NODES[@]}"; do
    IP="${node%%:*}"
    NAME="${node##*:}"

    echo -n "检查 $NAME ($IP) ... "

    if check_node "$IP" "$NAME"; then
        echo -e "${GREEN}[正常]${NC}"
        ((healthy_count++))
    else
        echo -e "${RED}[异常]${NC}"
        failed_nodes+=("$NAME ($IP)")
    fi
done

echo ""
echo "========================================"
echo " 检查结果"
echo "========================================"
echo "总节点数: $total_nodes"
echo -e "健康节点: ${GREEN}$healthy_count${NC}"
echo -e "异常节点: ${RED}$((total_nodes - healthy_count))${NC}"

# 如果有异常节点，发送告警
if [ ${#failed_nodes[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}异常节点列表:${NC}"
    for node in "${failed_nodes[@]}"; do
        echo "  - $node"
    done

    # 构造告警消息
    alert_msg="[CN2健康检查告警] 检测到 ${#failed_nodes[@]} 个节点异常:\n"
    for node in "${failed_nodes[@]}"; do
        alert_msg+="- $node\n"
    done
    alert_msg+="\n检查时间: $(date '+%Y-%m-%d %H:%M:%S')"

    # 发送告警
    send_alert "$alert_msg"

    echo ""
    echo -e "${YELLOW}建议操作:${NC}"
    echo "1. SSH登录异常节点检查Nginx状态"
    echo "2. 查看Nginx错误日志: tail -50 /var/log/nginx/newapi_proxy_error.log"
    echo "3. 如果长时间无法修复，建议临时删除该节点的DNS记录"
fi

echo ""
echo "========================================"

# 返回状态码（0=全部健康，1=有异常）
if [ $healthy_count -eq $total_nodes ]; then
    exit 0
else
    exit 1
fi
