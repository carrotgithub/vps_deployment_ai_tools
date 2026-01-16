#!/bin/bash

################################################################################
# 邮件告警发送脚本
# 功能：通过 SMTP 发送邮件告警
# 依赖：mailx 或 sendmail（使用系统自带工具，无需额外依赖）
################################################################################

set -e

# =============================================================================
# 参数接收
# =============================================================================

ALERT_COUNT="$1"
ALERT_FILE="$2"

# =============================================================================
# 配置文件加载
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.conf"

# 加载配置
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# =============================================================================
# 邮件发送函数
# =============================================================================

send_email() {
    local subject="$1"
    local body="$2"

    # 检查邮件配置是否完整
    if [ -z "$SMTP_SERVER" ] || [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASS" ] || [ -z "$EMAIL_TO" ]; then
        echo "[错误] 邮件配置不完整，跳过发送"
        echo "请在 config.conf 中配置以下变量："
        echo "  SMTP_SERVER, SMTP_PORT, SMTP_USER, SMTP_PASS, EMAIL_TO, EMAIL_FROM"
        return 1
    fi

    # 构建邮件内容
    local email_content
    email_content=$(cat <<EOF
From: ${EMAIL_FROM:-"服务监控 <${SMTP_USER}>"}
To: ${EMAIL_TO}
Subject: ${subject}
Content-Type: text/plain; charset=UTF-8

${body}

---
此邮件由服务监控系统自动发送
服务器: ${SERVER_NAME:-$(hostname)}
时间: $(date '+%Y-%m-%d %H:%M:%S')
EOF
)

    # 方法1：使用 curl 发送邮件（推荐，兼容性好）
    if command -v curl &> /dev/null; then
        echo "[信息] 使用 curl 发送邮件..."

        # 创建临时文件存储邮件内容
        local temp_mail="/tmp/monitor_email_$$.txt"
        echo "$email_content" > "$temp_mail"

        # 构建邮件URL
        local smtp_url
        if [ "${SMTP_USE_SSL:-true}" = "true" ]; then
            smtp_url="smtps://${SMTP_SERVER}:${SMTP_PORT:-465}"
        else
            smtp_url="smtp://${SMTP_SERVER}:${SMTP_PORT:-25}"
        fi

        # 发送邮件
        if curl --url "$smtp_url" \
                --ssl-reqd \
                --mail-from "$SMTP_USER" \
                --mail-rcpt "$EMAIL_TO" \
                --user "${SMTP_USER}:${SMTP_PASS}" \
                --upload-file "$temp_mail" \
                --silent --show-error; then
            echo "[成功] 邮件发送成功"
            rm -f "$temp_mail"
            return 0
        else
            echo "[失败] curl 发送邮件失败"
            rm -f "$temp_mail"
        fi
    fi

    # 方法2：使用 Python smtplib（备用方案）
    if command -v python3 &> /dev/null; then
        echo "[信息] 尝试使用 Python 发送邮件..."

        python3 <<PYEOF
import smtplib
from email.mime.text import MIMEText
from email.header import Header
import sys

try:
    # 创建邮件
    msg = MIMEText("""${body}""", 'plain', 'utf-8')
    msg['From'] = Header("${EMAIL_FROM:-服务监控}", 'utf-8')
    msg['To'] = Header("${EMAIL_TO}", 'utf-8')
    msg['Subject'] = Header("${subject}", 'utf-8')

    # 连接SMTP服务器
    use_ssl = "${SMTP_USE_SSL:-true}" == "true"
    if use_ssl:
        server = smtplib.SMTP_SSL("${SMTP_SERVER}", ${SMTP_PORT:-465}, timeout=10)
    else:
        server = smtplib.SMTP("${SMTP_SERVER}", ${SMTP_PORT:-25}, timeout=10)
        if "${SMTP_USE_TLS:-false}" == "true":
            server.starttls()

    # 登录并发送
    server.login("${SMTP_USER}", "${SMTP_PASS}")
    server.sendmail("${SMTP_USER}", ["${EMAIL_TO}"], msg.as_string())
    server.quit()

    print("[成功] Python 邮件发送成功")
    sys.exit(0)
except Exception as e:
    print(f"[失败] Python 发送邮件失败: {e}")
    sys.exit(1)
PYEOF

        if [ $? -eq 0 ]; then
            return 0
        fi
    fi

    # 方法3：使用 mailx（如果安装了）
    if command -v mailx &> /dev/null; then
        echo "[信息] 尝试使用 mailx 发送邮件..."

        # 配置 mailx SMTP
        echo "$body" | mailx -v \
            -S smtp="$SMTP_SERVER:${SMTP_PORT:-25}" \
            -S smtp-use-starttls \
            -S smtp-auth=login \
            -S smtp-auth-user="$SMTP_USER" \
            -S smtp-auth-password="$SMTP_PASS" \
            -S from="$EMAIL_FROM" \
            -s "$subject" \
            "$EMAIL_TO"

        if [ $? -eq 0 ]; then
            echo "[成功] mailx 邮件发送成功"
            return 0
        else
            echo "[失败] mailx 发送邮件失败"
        fi
    fi

    # 所有方法都失败
    echo "[错误] 所有邮件发送方法均失败"
    echo "[建议] 安装 curl 或确保 Python 3 可用"
    return 1
}

# =============================================================================
# 主函数
# =============================================================================

main() {
    # 检查参数
    if [ -z "$ALERT_COUNT" ] || [ -z "$ALERT_FILE" ]; then
        echo "用法: $0 <告警数量> <告警文件>"
        exit 1
    fi

    if [ ! -f "$ALERT_FILE" ]; then
        echo "[错误] 告警文件不存在: $ALERT_FILE"
        exit 1
    fi

    # 构建邮件主题
    local subject="【告警】服务器 ${SERVER_NAME:-$(hostname)} 检测到 ${ALERT_COUNT} 个服务异常"

    # 构建邮件正文
    local body
    body=$(cat <<EOF
服务器：${SERVER_NAME:-$(hostname)}
检测时间：$(date '+%Y-%m-%d %H:%M:%S')
异常服务数量：${ALERT_COUNT}

异常详情：
================================================================

$(cat "$ALERT_FILE")

================================================================

请及时登录服务器检查并处理异常。

监控脚本路径：${SCRIPT_DIR}/service_monitor.sh
日志路径：/var/log/service-monitor/
EOF
)

    # 发送邮件
    send_email "$subject" "$body"
}

# 执行主函数
main "$@"
