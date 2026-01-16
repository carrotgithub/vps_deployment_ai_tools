# 服务监控系统

轻量级 VPS 服务器监控解决方案 - 纯 Bash 实现，无需额外依赖

## 快速开始

```bash
# 1. 上传到服务器
scp -r 8.service-monitor root@your-server:/root/

# 2. SSH 登录
ssh root@your-server

# 3. 准备配置（可选）
cp /root/8.service-monitor/config.conf /root/config.conf
vi /root/config.conf  # 填写邮箱配置

# 4. 运行安装
cd /root/8.service-monitor
chmod +x install_monitor.sh
./install_monitor.sh
```

## 主要功能

- ✅ **多维度监控**：Systemd 服务、Docker 容器、HTTP 端点、系统资源（CPU/内存/磁盘）、数据库连接
- ✅ **智能告警**：状态变化检测，避免重复告警，邮件通知
- ✅ **易于扩展**：模块化设计，配置文件驱动
- ✅ **轻量级**：纯 Bash，资源占用极低

## 文件说明

```
8.service-monitor/
├── service_monitor.sh              # 主监控脚本
├── send_email.sh                   # 邮件发送脚本
├── config.conf                     # 配置文件模板
├── install_monitor.sh              # 一键安装脚本
└── 服务监控系统-完整使用指南.md     # 完整文档 ⭐
```

## 完整文档

**请查阅：[服务监控系统-完整使用指南.md](./服务监控系统-完整使用指南.md)**

包含：
- 📖 功能特性详解
- ⚙️ 配置说明（含邮箱设置）
- 🚀 安装部署（三种方式）
- ✅ 测试验证
- 📧 Gmail/QQ/163 邮箱配置
- 🔧 故障排查
- 🛠️ 扩展开发示例

## 测试运行

```bash
# 手动运行一次
bash /opt/service-monitor/service_monitor.sh

# 查看日志
tail -f /var/log/service-monitor/monitor_$(date +%Y%m%d).log
```

## 常用命令

```bash
# 查看配置
cat /opt/service-monitor/config.conf

# 编辑配置
vi /opt/service-monitor/config.conf

# 查看定时任务
crontab -l | grep service_monitor

# 查看日志
tail -50 /var/log/service-monitor/monitor_$(date +%Y%m%d).log
```

## 配置示例

```bash
# 服务器名称
SERVER_NAME="生产服务器"

# 邮件配置（使用 Gmail 应用专用密码）
SMTP_SERVER="smtp.gmail.com"
SMTP_PORT="465"
SMTP_USER="your@gmail.com"
SMTP_PASS="xxxx xxxx xxxx xxxx"
EMAIL_TO="admin@example.com"

# 监控项
MONITOR_SYSTEMD_SERVICES="nginx:Nginx服务"
MONITOR_HTTP_ENDPOINTS="https://api.example.com|API检查|200|10"
MONITOR_CPU="true"
CPU_THRESHOLD="80"
```

## 许可证

MIT License
