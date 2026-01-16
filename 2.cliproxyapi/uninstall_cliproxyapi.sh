#!/bin/bash

################################################################################
#
# CliproxyAPI 完全卸载脚本
#
# 功能说明：
#   - 停止并删除 Systemd 服务
#   - 删除程序文件
#   - 删除配置文件
#   - 删除数据目录
#   - 删除日志文件
#   - 删除 Nginx 配置（仅 CliproxyAPI 相关）
#   - 保留 SSL 证书（可选）
#   - 不影响其他服务（Nginx、V2Ray 等）
#
################################################################################

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 必须使用 root 权限运行此脚本。${NC}"
    exit 1
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}   CliproxyAPI 卸载程序${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# 询问是否继续
read -p "确认卸载 CliproxyAPI？此操作不可恢复。(y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}已取消卸载。${NC}"
    exit 0
fi

echo ""

# ==================== 1. 停止并删除 Systemd 服务 ====================

echo -e "${CYAN}>>> [1/6] 停止并删除 Systemd 服务...${NC}"

if systemctl list-units --full -all | grep -q "cliproxyapi.service"; then
    systemctl stop cliproxyapi 2>/dev/null
    systemctl disable cliproxyapi 2>/dev/null
    echo -e "${GREEN}✓ 服务已停止并禁用${NC}"
else
    echo -e "${YELLOW}⚠ 服务不存在，跳过${NC}"
fi

if [ -f /etc/systemd/system/cliproxyapi.service ]; then
    rm -f /etc/systemd/system/cliproxyapi.service
    systemctl daemon-reload
    echo -e "${GREEN}✓ 服务文件已删除${NC}"
else
    echo -e "${YELLOW}⚠ 服务文件不存在${NC}"
fi

# ==================== 2. 删除程序文件 ====================

echo -e "${CYAN}>>> [2/6] 删除程序文件...${NC}"

if [ -d /opt/cliproxyapi ]; then
    rm -rf /opt/cliproxyapi
    echo -e "${GREEN}✓ 程序目录已删除: /opt/cliproxyapi${NC}"
else
    echo -e "${YELLOW}⚠ 程序目录不存在${NC}"
fi

# ==================== 3. 删除配置文件 ====================

echo -e "${CYAN}>>> [3/6] 删除配置文件...${NC}"

if [ -d /etc/cliproxyapi ]; then
    # 显示配置文件内容供用户备份
    if [ -f /etc/cliproxyapi/config.yaml ]; then
        echo -e "${YELLOW}当前 API 密钥:${NC}"
        grep -A 2 "api-keys:" /etc/cliproxyapi/config.yaml | grep "sk-" | sed 's/^/  /'
    fi

    rm -rf /etc/cliproxyapi
    echo -e "${GREEN}✓ 配置目录已删除: /etc/cliproxyapi${NC}"
else
    echo -e "${YELLOW}⚠ 配置目录不存在${NC}"
fi

# ==================== 4. 删除数据目录 ====================

echo -e "${CYAN}>>> [4/6] 删除数据目录...${NC}"

if [ -d /var/lib/cliproxyapi ]; then
    rm -rf /var/lib/cliproxyapi
    echo -e "${GREEN}✓ 数据目录已删除: /var/lib/cliproxyapi${NC}"
else
    echo -e "${YELLOW}⚠ 数据目录不存在${NC}"
fi

# ==================== 5. 删除日志文件 ====================

echo -e "${CYAN}>>> [5/6] 删除日志文件...${NC}"

if [ -d /var/log/cliproxyapi ]; then
    rm -rf /var/log/cliproxyapi
    echo -e "${GREEN}✓ 日志目录已删除: /var/log/cliproxyapi${NC}"
else
    echo -e "${YELLOW}⚠ 日志目录不存在${NC}"
fi

# 清理 Nginx 日志
rm -f /var/log/nginx/cliproxyapi_*.log 2>/dev/null
echo -e "${GREEN}✓ Nginx 日志已清理${NC}"

# ==================== 6. 删除 Nginx 配置 ====================

echo -e "${CYAN}>>> [6/6] 删除 Nginx 配置...${NC}"

# 查找并删除 CliproxyAPI 相关的 Nginx 配置
NGINX_CONF_DIR="/usr/local/nginx/conf/conf.d"
CLIPROXY_CONFIGS=$(find "$NGINX_CONF_DIR" -name "*.conf" -exec grep -l "cliproxyapi\|8317" {} \; 2>/dev/null)

if [ -n "$CLIPROXY_CONFIGS" ]; then
    echo -e "${YELLOW}找到以下 Nginx 配置文件:${NC}"
    echo "$CLIPROXY_CONFIGS" | sed 's/^/  /'
    echo ""

    for conf in $CLIPROXY_CONFIGS; do
        # 提取域名（用于后续询问是否删除 SSL 证书）
        DOMAIN=$(grep "server_name" "$conf" | head -1 | awk '{print $2}' | sed 's/;//')
        echo -e "域名: ${YELLOW}$DOMAIN${NC}"

        rm -f "$conf"
        echo -e "${GREEN}✓ 已删除: $conf${NC}"

        # 询问是否删除 SSL 证书
        if [ -n "$DOMAIN" ] && [ -d "/usr/local/nginx/conf/ssl/$DOMAIN" ]; then
            echo ""
            read -p "是否删除 $DOMAIN 的 SSL 证书? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                rm -rf "/usr/local/nginx/conf/ssl/$DOMAIN"
                echo -e "${GREEN}✓ 已删除 SSL 证书: /usr/local/nginx/conf/ssl/$DOMAIN${NC}"
            else
                echo -e "${YELLOW}✓ 已保留 SSL 证书: /usr/local/nginx/conf/ssl/$DOMAIN${NC}"
            fi
        fi
    done

    # 测试并重载 Nginx
    if /usr/local/nginx/sbin/nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
        echo -e "${GREEN}✓ Nginx 已重载${NC}"
    else
        echo -e "${RED}⚠ Nginx 配置测试失败，请手动检查${NC}"
    fi
else
    echo -e "${YELLOW}⚠ 未找到 CliproxyAPI 相关的 Nginx 配置${NC}"
fi

# ==================== 7. 清理源码目录（可选） ====================

if [ -d /usr/local/src/CLIProxyAPI ]; then
    echo ""
    read -p "是否删除源码目录 /usr/local/src/CLIProxyAPI? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf /usr/local/src/CLIProxyAPI
        echo -e "${GREEN}✓ 源码目录已删除${NC}"
    fi
fi

# ==================== 完成 ====================

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}   卸载完成！${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${CYAN}已删除的组件:${NC}"
echo -e "  ✓ Systemd 服务"
echo -e "  ✓ 程序文件 (/opt/cliproxyapi)"
echo -e "  ✓ 配置文件 (/etc/cliproxyapi)"
echo -e "  ✓ 数据目录 (/var/lib/cliproxyapi)"
echo -e "  ✓ 日志文件 (/var/log/cliproxyapi)"
echo -e "  ✓ Nginx 配置"
echo ""
echo -e "${CYAN}保留的组件:${NC}"
echo -e "  ✓ Nginx 主程序"
echo -e "  ✓ 其他服务配置"
echo -e "  ✓ SSL 证书 (如已选择保留)"
echo ""
echo -e "${YELLOW}现在可以重新运行安装脚本:${NC}"
echo -e "  ./install_cliproxyapi.sh"
echo ""
