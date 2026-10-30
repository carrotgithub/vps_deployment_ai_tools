#!/bin/bash

################################################################################
# VLESS + Reality 卸载脚本
#
# 操作:
#   1. 停止并禁用 xray systemd 服务
#   2. 删除 xray 二进制、配置、日志
#   3. 删除信息文件
#   4. 若以 MODE=nginx 部署, 从 Nginx 443 分流表移除登记
#
# 环境变量:
#   KEEP_LOGS=1    保留 /var/log/xray 日志 (默认删除)
#   KEEP_INFO=1    保留 /root/reality.info.txt (默认删除)
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}必须使用 root 权限运行${NC}"
    exit 1
fi

KEEP_LOGS="${KEEP_LOGS:-0}"
KEEP_INFO="${KEEP_INFO:-0}"

echo -e "${CYAN}>>> 停止 xray 服务${NC}"
systemctl stop xray 2>/dev/null || true
systemctl disable xray 2>/dev/null || true

echo -e "${CYAN}>>> 删除文件${NC}"
rm -f /etc/systemd/system/xray.service
rm -f /usr/local/bin/xray
rm -rf /usr/local/etc/xray

if [ "$KEEP_LOGS" = "1" ]; then
    echo -e "${YELLOW}保留日志: /var/log/xray${NC}"
else
    rm -rf /var/log/xray
fi

if [ "$KEEP_INFO" = "1" ]; then
    echo -e "${YELLOW}保留信息文件: /root/reality.info.txt${NC}"
else
    rm -f /root/reality.info.txt /root/reality_qr.png
fi

systemctl daemon-reload

SNI_MAP_FILE="/usr/local/nginx/conf/stream.d/sni_map/reality.map"
if [ -f "$SNI_MAP_FILE" ]; then
    rm -f "$SNI_MAP_FILE"
    if /usr/local/nginx/sbin/nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
        echo -e "${GREEN}✓ 已从 Nginx 443 分流表移除 Reality${NC}"
    else
        echo -e "${RED}移除分流登记后 nginx -t 失败, 请手动检查${NC}"
    fi
fi

echo -e "${GREEN}✓ Reality 已完全卸载${NC}"
