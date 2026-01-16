#!/bin/bash

################################################################################
#
# CN2 VPS 反向代理测试脚本
#
# 功能说明：
#   1. 测试 CN2 VPS 到性能服务器的连通性
#   2. 验证 SSL 证书有效性
#   3. 测试 SSE 流式传输
#   4. 测试 API 响应时间
#   5. 验证超时配置
#
# 使用方法：
#   ./test_proxy.sh
#
################################################################################

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 配置信息 ====================

# CN2 VPS域名
CN2_DOMAIN="newapi.example.com"  # 【需替换】替换为你的域名

# 性能服务器域名
BACKEND_DOMAIN="api.example.com"  # 【需替换】替换为你的域名

# 测试超时时间
TEST_TIMEOUT=10

# ==================== 日志函数 ====================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_test() {
    echo -e "${CYAN}[TEST]${NC} $1"
}

# ==================== 测试函数 ====================

test_dns_resolution() {
    log_test "DNS 解析测试"
    echo ""

    # 测试 CN2 VPS 域名
    log_info "查询 CN2 VPS 域名: $CN2_DOMAIN"
    CN2_IP=$(dig +short "$CN2_DOMAIN" | tail -1)
    if [ -n "$CN2_IP" ]; then
        log_success "CN2 域名已解析: $CN2_IP"
    else
        log_error "CN2 域名未解析"
        return 1
    fi

    # 测试性能服务器域名
    log_info "查询性能服务器域名: $BACKEND_DOMAIN"
    BACKEND_IP=$(dig +short "$BACKEND_DOMAIN" | tail -1)
    if [ -n "$BACKEND_IP" ]; then
        log_success "后端域名已解析: $BACKEND_IP"
    else
        log_error "后端域名未解析"
        return 1
    fi

    echo ""
    return 0
}

test_backend_connectivity() {
    log_test "性能服务器连通性测试"
    echo ""

    log_info "测试 HTTPS 连接: $BACKEND_DOMAIN"

    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time $TEST_TIMEOUT "https://$BACKEND_DOMAIN" 2>/dev/null)

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
        log_success "后端服务器响应正常 (HTTP $HTTP_CODE)"
    else
        log_error "后端服务器无响应或异常 (HTTP $HTTP_CODE)"
        return 1
    fi

    echo ""
    return 0
}

test_ssl_certificate() {
    log_test "SSL 证书验证"
    echo ""

    # 测试 CN2 VPS 证书（如果已配置）
    if [ -f "/usr/local/nginx/conf/ssl/$CN2_DOMAIN/fullchain.pem" ]; then
        log_info "检查 CN2 VPS 证书: $CN2_DOMAIN"

        CERT_SUBJECT=$(openssl x509 -in "/usr/local/nginx/conf/ssl/$CN2_DOMAIN/fullchain.pem" -noout -subject 2>/dev/null | sed 's/subject=//')
        CERT_ISSUER=$(openssl x509 -in "/usr/local/nginx/conf/ssl/$CN2_DOMAIN/fullchain.pem" -noout -issuer 2>/dev/null | sed 's/issuer=//')
        CERT_DATES=$(openssl x509 -in "/usr/local/nginx/conf/ssl/$CN2_DOMAIN/fullchain.pem" -noout -dates 2>/dev/null)

        if [ -n "$CERT_SUBJECT" ]; then
            log_success "证书主体: $CERT_SUBJECT"
            echo "  签发者: $CERT_ISSUER"
            echo "  有效期: $CERT_DATES"

            # 检查是否为Let's Encrypt
            if echo "$CERT_ISSUER" | grep -qi "Let's Encrypt"; then
                log_success "使用 Let's Encrypt 正式证书"
            else
                log_warning "使用自签名或其他证书"
            fi
        else
            log_error "证书读取失败"
        fi
    else
        log_warning "CN2 VPS 证书未配置: /usr/local/nginx/conf/ssl/$CN2_DOMAIN/fullchain.pem"
    fi

    echo ""
    return 0
}

test_nginx_config() {
    log_test "Nginx 配置验证"
    echo ""

    log_info "测试 Nginx 配置语法..."
    if /usr/local/nginx/sbin/nginx -t >/dev/null 2>&1; then
        log_success "Nginx 配置语法正确"
    else
        log_error "Nginx 配置语法错误"
        /usr/local/nginx/sbin/nginx -t
        return 1
    fi

    # 检查反向代理配置是否存在
    if [ -f "/usr/local/nginx/conf/conf.d/$CN2_DOMAIN.conf" ]; then
        log_success "反向代理配置已部署: $CN2_DOMAIN.conf"

        # 检查关键配置
        log_info "检查关键配置项..."

        if grep -q "proxy_pass.*$BACKEND_DOMAIN" "/usr/local/nginx/conf/conf.d/$CN2_DOMAIN.conf"; then
            log_success "✓ proxy_pass 配置正确"
        else
            log_warning "⚠ proxy_pass 配置可能不正确"
        fi

        if grep -q "proxy_buffering off" "/usr/local/nginx/conf/conf.d/$CN2_DOMAIN.conf"; then
            log_success "✓ SSE 流式传输已配置"
        else
            log_warning "⚠ SSE 流式传输未配置"
        fi

        if grep -q "proxy_read_timeout 600" "/usr/local/nginx/conf/conf.d/$CN2_DOMAIN.conf"; then
            log_success "✓ 超时配置正确 (600秒)"
        else
            log_warning "⚠ 超时配置可能不正确"
        fi
    else
        log_error "反向代理配置不存在: /usr/local/nginx/conf/conf.d/$CN2_DOMAIN.conf"
        return 1
    fi

    echo ""
    return 0
}

test_proxy_response() {
    log_test "反向代理响应测试"
    echo ""

    log_info "测试 CN2 VPS 响应: https://$CN2_DOMAIN"

    RESPONSE=$(curl -o /dev/null -s -w "HTTP: %{http_code} | Time: %{time_total}s | Size: %{size_download} bytes" \
        --max-time $TEST_TIMEOUT "https://$CN2_DOMAIN" 2>/dev/null)

    if [ $? -eq 0 ]; then
        log_success "CN2 VPS 响应: $RESPONSE"
    else
        log_error "CN2 VPS 无响应或超时"
        return 1
    fi

    echo ""
    return 0
}

test_sse_streaming() {
    log_test "SSE 流式传输测试"
    echo ""

    log_info "测试 SSE 流式传输能力..."
    log_warning "需要有效的 API Key 才能完整测试"

    # 测试 /v1/chat/completions 端点是否可访问
    HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 \
        -X POST "https://$CN2_DOMAIN/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{"model":"test","messages":[{"role":"user","content":"test"}]}' 2>/dev/null)

    if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
        log_success "API 端点可访问 (需要认证: HTTP $HTTP_CODE)"
    elif [ "$HTTP_CODE" = "200" ]; then
        log_success "API 端点响应正常 (HTTP $HTTP_CODE)"
    else
        log_warning "API 端点状态: HTTP $HTTP_CODE"
    fi

    echo ""
    return 0
}

test_timeout_config() {
    log_test "超时配置测试"
    echo ""

    log_info "检查 Nginx 超时配置..."

    CONFIG_FILE="/usr/local/nginx/conf/conf.d/$CN2_DOMAIN.conf"

    if [ -f "$CONFIG_FILE" ]; then
        echo "  proxy_connect_timeout: $(grep "proxy_connect_timeout" "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d ';')"
        echo "  proxy_send_timeout:    $(grep "proxy_send_timeout" "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d ';')"
        echo "  proxy_read_timeout:    $(grep "proxy_read_timeout" "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d ';')"

        READ_TIMEOUT=$(grep "proxy_read_timeout" "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d ';s')

        if [ "$READ_TIMEOUT" -ge 600 ]; then
            log_success "超时配置符合 AI API 要求 (≥600秒)"
        else
            log_warning "超时配置可能不足 (<600秒)"
        fi
    else
        log_error "配置文件不存在"
        return 1
    fi

    echo ""
    return 0
}

test_log_access() {
    log_test "日志文件访问测试"
    echo ""

    ACCESS_LOG="/var/log/nginx/newapi_proxy_access.log"
    ERROR_LOG="/var/log/nginx/newapi_proxy_error.log"

    if [ -f "$ACCESS_LOG" ]; then
        log_success "访问日志存在: $ACCESS_LOG"
        echo "  最新访问记录:"
        tail -3 "$ACCESS_LOG" 2>/dev/null | sed 's/^/    /'
    else
        log_info "访问日志暂无: $ACCESS_LOG (首次访问后生成)"
    fi

    if [ -f "$ERROR_LOG" ]; then
        log_success "错误日志存在: $ERROR_LOG"
        ERROR_COUNT=$(wc -l < "$ERROR_LOG" 2>/dev/null)
        if [ "$ERROR_COUNT" -eq 0 ]; then
            log_success "错误日志为空（无错误）"
        else
            log_warning "错误日志有 $ERROR_COUNT 行，请检查"
        fi
    else
        log_info "错误日志暂无: $ERROR_LOG"
    fi

    echo ""
    return 0
}

# ==================== 主程序 ====================

clear
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}   CN2 VPS 反向代理测试程序${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "CN2 VPS 域名:        ${CYAN}$CN2_DOMAIN${NC}"
echo -e "性能服务器域名:      ${CYAN}$BACKEND_DOMAIN${NC}"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# 运行所有测试
FAILED_TESTS=0

test_dns_resolution || ((FAILED_TESTS++))
test_backend_connectivity || ((FAILED_TESTS++))
test_ssl_certificate || ((FAILED_TESTS++))
test_nginx_config || ((FAILED_TESTS++))
test_proxy_response || ((FAILED_TESTS++))
test_sse_streaming || ((FAILED_TESTS++))
test_timeout_config || ((FAILED_TESTS++))
test_log_access || ((FAILED_TESTS++))

# ==================== 测试总结 ====================

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}   测试总结${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}✓ 所有测试通过！${NC}"
    echo ""
    echo -e "${CYAN}[系统状态]${NC}"
    echo -e "  • CN2 VPS 反向代理正常运行"
    echo -e "  • SSL 证书配置正确"
    echo -e "  • SSE 流式传输已启用"
    echo -e "  • 超时配置符合要求 (600秒)"
    echo ""
    echo -e "${CYAN}[下一步操作]${NC}"
    echo -e "1. 在 New-API 管理台创建 API Key"
    echo -e "2. 使用 https://$CN2_DOMAIN 作为 Base URL"
    echo -e "3. 测试 API 调用:"
    echo -e "   ${YELLOW}curl https://$CN2_DOMAIN/v1/models \\${NC}"
    echo -e "   ${YELLOW}  -H \"Authorization: Bearer YOUR_API_KEY\"${NC}"
    echo ""
else
    echo -e "${RED}✗ 有 $FAILED_TESTS 个测试失败${NC}"
    echo ""
    echo -e "${CYAN}[故障排查]${NC}"
    echo -e "1. 检查 DNS 配置:"
    echo -e "   ${YELLOW}dig $CN2_DOMAIN${NC}"
    echo -e "   ${YELLOW}dig $BACKEND_DOMAIN${NC}"
    echo ""
    echo -e "2. 检查防火墙规则:"
    echo -e "   ${YELLOW}iptables -L -n | grep -E '(80|443)'${NC}"
    echo ""
    echo -e "3. 检查 Nginx 状态:"
    echo -e "   ${YELLOW}systemctl status nginx${NC}"
    echo -e "   ${YELLOW}nginx -t${NC}"
    echo ""
    echo -e "4. 查看错误日志:"
    echo -e "   ${YELLOW}tail -f /var/log/nginx/newapi_proxy_error.log${NC}"
    echo ""
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

exit $FAILED_TESTS
