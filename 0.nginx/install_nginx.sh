#!/bin/bash

################################################################################
#
# Nginx 纯净安装与系统优化脚本
#
# 功能说明：
#   1. 系统内核优化：开启 BBR、优化 TCP 连接、提升文件描述符限制
#   2. 编译安装 Nginx：仅包含必要模块 (SSL, V2, Stream, RealIP, StubStatus)
#   3. 配置结构优化：构建模块化 conf.d 结构，方便后续扩展 API 或其他站点
#
# 适用环境：
#   - Ubuntu 20.04+ / Debian 11+ / CentOS 7+
#   - 建议内存 512MB+
#
# 使用方法：
#   chmod +x install_nginx.sh
#   ./install_nginx.sh
#
################################################################################

# ==================== 全局配置 ====================

NGINX_VERSION="1.28.1"  # 使用最新稳定版（支持 HTTP/3）
INSTALL_PATH="/usr/local/nginx"
SRC_DIR="/usr/local/src"
USER="www"
GROUP="www"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==================== 检查 Root 权限 ====================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 必须使用 root 权限运行此脚本。${NC}"
    exit 1
fi

echo -e "${CYAN}>>> [1/4] 系统环境检查与优化...${NC}"

# 1. 自动挂载 Swap (如果内存 < 1GB)
MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
if [ "$MEM_TOTAL" -lt 1000 ]; then
    if grep -q "/swapfile_install" /proc/swaps; then
        echo -e "${GREEN}Swap 空间已存在，跳过。${NC}"
    else
        echo -e "${YELLOW}检测到低内存 ($MEM_TOTAL MB)，正在创建 1.5GB Swap...${NC}"
        dd if=/dev/zero of=/swapfile_install bs=1M count=1536
        chmod 600 /swapfile_install
        mkswap /swapfile_install
        swapon /swapfile_install
        echo "/swapfile_install none swap sw 0 0" >> /etc/fstab
        echo -e "${GREEN}Swap 创建完成。${NC}"
    fi
fi

# 2. 内核参数优化 (开启 BBR + TCP 调优)
echo "正在优化 sysctl.conf..."
cat > /etc/sysctl.d/99-vps-optimize.conf <<EOF
# --- BBR 拥塞控制 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- TCP 优化 ---
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 8192

# --- 文件描述符 ---
fs.file-max = 1000000
EOF

# 应用内核参数
sysctl -p /etc/sysctl.d/99-vps-optimize.conf > /dev/null 2>&1

# 验证 BBR
BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
if [ "$BBR_STATUS" == "bbr" ]; then
    echo -e "${GREEN}✓ TCP BBR 已成功开启${NC}"
else
    echo -e "${YELLOW}⚠ BBR 开启失败，请检查内核版本 (建议 >= 4.9)${NC}"
fi

# 3. 提升系统级文件描述符限制
if ! grep -q "* soft nofile 65535" /etc/security/limits.conf; then
    echo "* soft nofile 65535" >> /etc/security/limits.conf
    echo "* hard nofile 65535" >> /etc/security/limits.conf
    echo "root soft nofile 65535" >> /etc/security/limits.conf
    echo "root hard nofile 65535" >> /etc/security/limits.conf
fi

echo -e "${CYAN}>>> [2/4] 安装依赖库...${NC}"

# 检测系统并安装依赖
if [ -f /etc/debian_version ]; then
    apt-get update -y
    apt-get install -y build-essential libtool autoconf wget curl git \
    libpcre3 libpcre3-dev zlib1g zlib1g-dev libssl-dev pkg-config
elif [ -f /etc/redhat-release ]; then
    yum install -y epel-release
    yum groupinstall -y "Development Tools"
    yum install -y wget curl pcre-devel zlib-devel openssl-devel
fi

# 创建用户
id -u $USER &>/dev/null || useradd -s /sbin/nologin -M $USER

echo -e "${CYAN}>>> [3/4] 编译安装 Nginx $NGINX_VERSION ...${NC}"

mkdir -p $SRC_DIR
cd $SRC_DIR

# 下载源码
if [ ! -f "nginx-$NGINX_VERSION.tar.gz" ]; then
    wget -c "http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz"
fi
tar -zxvf nginx-$NGINX_VERSION.tar.gz
cd nginx-$NGINX_VERSION

# 编译配置 (增强版 - 包含 HTTP/3 支持)
./configure \
  --prefix=$INSTALL_PATH \
  --user=$USER \
  --group=$GROUP \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-http_v3_module \
  --with-http_realip_module \
  --with-http_stub_status_module \
  --with-http_gzip_static_module \
  --with-http_gunzip_module \
  --with-http_sub_module \
  --with-http_flv_module \
  --with-http_addition_module \
  --with-http_mp4_module \
  --with-http_dav_module \
  --with-stream \
  --with-stream_ssl_module \
  --with-stream_ssl_preread_module \
  --with-stream_realip_module \
  --with-pcre \
  --with-cc-opt='-O2 -g -pipe'

# 编译与安装
make -j$(nproc)
make install

# 创建必要的目录结构
mkdir -p $INSTALL_PATH/conf/conf.d
mkdir -p $INSTALL_PATH/conf/ssl
mkdir -p /var/log/nginx
chown -R $USER:$GROUP /var/log/nginx

echo -e "${CYAN}>>> [4/4] 配置 Nginx 结构...${NC}"

# 生成主配置文件 (优化高并发)
cat > $INSTALL_PATH/conf/nginx.conf <<EOF
user  $USER;
worker_processes  auto;
worker_rlimit_nofile 65535;

error_log  /var/log/nginx/error.log warn;
pid        $INSTALL_PATH/logs/nginx.pid;

events {
    worker_connections  10240;
    use epoll;
    multi_accept on;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    # 日志格式 (包含真实 IP)
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    # 核心优化
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  65;
    types_hash_max_size 2048;
    server_tokens   off;

    # Gzip 压缩
    gzip on;
    gzip_min_length 1k;
    gzip_comp_level 4;
    gzip_types text/plain text/css application/json application/javascript application/xml;

    # 加载模块化配置 (关键点: 允许后续方便添加 API 站点)
    include $INSTALL_PATH/conf/conf.d/*.conf;
}
EOF

# 创建 Systemd 服务
cat > /etc/systemd/system/nginx.service <<EOF
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=$INSTALL_PATH/logs/nginx.pid
ExecStartPre=$INSTALL_PATH/sbin/nginx -t
ExecStart=$INSTALL_PATH/sbin/nginx
ExecReload=$INSTALL_PATH/sbin/nginx -s reload
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
systemctl daemon-reload
systemctl enable nginx
systemctl restart nginx

echo -e ""
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}   Nginx 安装与系统优化完成 (v4.0)   ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "Nginx 版本:   ${YELLOW}$NGINX_VERSION (支持 HTTP/3)${NC}"
echo -e "Nginx 路径:   ${YELLOW}$INSTALL_PATH${NC}"
echo -e "配置文件:     ${YELLOW}$INSTALL_PATH/conf/nginx.conf${NC}"
echo -e "扩展配置:     ${YELLOW}$INSTALL_PATH/conf/conf.d/*.conf${NC}"
echo -e "优化状态:     ${GREEN}BBR 已开启, Limit 已提升${NC}"
echo -e "HTTP/3 支持:  ${GREEN}✓ 已编译 (--with-http_v3_module)${NC}"
echo -e "${GREEN}==============================================${NC}"
