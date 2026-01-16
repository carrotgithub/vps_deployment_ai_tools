#!/bin/bash

################################################################################
#
# 静态伪装站点部署脚本
#
# 功能说明：
#   1. 自动生成一个现代化的静态 HTML 页面
#   2. 科技感/维护页风格，体积小，加载快
#   3. 无需 GitHub 账号，无需下载，100% 成功率
#
# 前置条件：
#   - 建议在 install_v2ray.sh 之后运行
#
################################################################################

WEB_ROOT="/var/www/static"

# 颜色定义
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}>>> [1/2] 准备目录...${NC}"
mkdir -p $WEB_ROOT
# 清理旧文件
rm -rf $WEB_ROOT/*

echo -e "${CYAN}>>> [2/2] 生成静态页面...${NC}"

# 生成一个自包含的 HTML 文件 (无需外部 CSS/JS 资源)
cat > $WEB_ROOT/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>System Maintenance</title>
    <style>
        :root {
            --bg-color: #0f172a;
            --text-color: #e2e8f0;
            --accent-color: #38bdf8;
        }
        body {
            margin: 0;
            padding: 0;
            background-color: var(--bg-color);
            color: var(--text-color);
            font-family: 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            overflow: hidden;
        }
        .container {
            text-align: center;
            padding: 2rem;
            max-width: 600px;
        }
        .icon {
            font-size: 4rem;
            margin-bottom: 1rem;
            color: var(--accent-color);
            animation: pulse 2s infinite;
        }
        h1 {
            font-size: 2.5rem;
            margin-bottom: 0.5rem;
            font-weight: 300;
        }
        p {
            font-size: 1.1rem;
            color: #94a3b8;
            line-height: 1.6;
        }
        .status-bar {
            margin-top: 2rem;
            background: #1e293b;
            height: 4px;
            border-radius: 2px;
            overflow: hidden;
            position: relative;
        }
        .status-bar::after {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            height: 100%;
            width: 30%;
            background: var(--accent-color);
            animation: loading 1.5s ease-in-out infinite;
        }
        @keyframes pulse {
            0% { opacity: 1; transform: scale(1); }
            50% { opacity: 0.7; transform: scale(0.95); }
            100% { opacity: 1; transform: scale(1); }
        }
        @keyframes loading {
            0% { left: -30%; }
            100% { left: 100%; }
        }
        footer {
            margin-top: 3rem;
            font-size: 0.8rem;
            color: #475569;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="icon">☁️</div>
        <h1>System Maintenance</h1>
        <p>Our servers are currently undergoing scheduled maintenance to improve performance and security. We apologize for any inconvenience.</p>
        <p>Estimated completion: <strong>In Progress</strong></p>
        
        <div class="status-bar"></div>

        <footer>
            &copy; $(date +%Y) Cloud Infrastructure. All rights reserved.
        </footer>
    </div>
</body>
</html>
EOF

# 设置权限
chown -R www:www $WEB_ROOT
chmod -R 755 $WEB_ROOT

echo -e "${GREEN}✓ 静态网站部署完成 (路径: $WEB_ROOT)${NC}"
echo -e "访问您的域名即可看到伪装页面。"
