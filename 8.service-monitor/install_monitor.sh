#!/bin/bash

################################################################################
# 服务监控系统 - 一键安装部署脚本
# 功能：自动安装和配置服务监控系统
################################################################################

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 打印带颜色的信息
print_info() {
    echo -e "${BLUE}[信息]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[成功]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

print_error() {
    echo -e "${RED}[错误]${NC} $1"
}

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 安装目录
INSTALL_DIR="/opt/service-monitor"

# 日志目录
LOG_DIR="/var/log/service-monitor"

################################################################################
# 检查运行环境
################################################################################

check_environment() {
    print_info "检查运行环境..."

    # 检查是否为 root 用户
    if [ "$EUID" -ne 0 ]; then
        print_error "请使用 root 用户运行此脚本"
        exit 1
    fi

    # 检查操作系统
    if [ ! -f /etc/os-release ]; then
        print_error "无法识别操作系统"
        exit 1
    fi

    # 显示系统信息
    source /etc/os-release
    print_success "操作系统: $PRETTY_NAME"

    # 检查必要命令
    local required_commands=("bash" "systemctl" "curl" "free" "df" "top")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            print_error "缺少必要命令: $cmd"
            exit 1
        fi
    done

    print_success "环境检查通过"
}

################################################################################
# 检查脚本文件完整性
################################################################################

check_script_files() {
    print_info "检查脚本文件完整性..."

    local missing_files=()

    # 检查主监控脚本
    if [ ! -f "${SCRIPT_DIR}/service_monitor.sh" ]; then
        missing_files+=("service_monitor.sh")
    fi

    # 检查邮件发送脚本
    if [ ! -f "${SCRIPT_DIR}/send_email.sh" ]; then
        missing_files+=("send_email.sh")
    fi

    # 检查配置文件
    if [ ! -f "${SCRIPT_DIR}/config.conf" ]; then
        missing_files+=("config.conf")
    fi

    # 如果有缺失文件，显示错误并退出
    if [ ${#missing_files[@]} -gt 0 ]; then
        print_error "缺少必要的脚本文件！"
        echo ""
        echo "缺失的文件："
        for file in "${missing_files[@]}"; do
            echo "  ❌ ${SCRIPT_DIR}/${file}"
        done
        echo ""
        print_error "请确保以下操作："
        echo ""
        echo "方式1: 上传完整目录到服务器"
        echo "  1) 在本地执行："
        echo "     scp -r 8.service-monitor root@your-server:/root/"
        echo ""
        echo "  2) SSH 登录服务器："
        echo "     ssh root@your-server"
        echo ""
        echo "  3) 进入目录并运行安装脚本："
        echo "     cd /root/8.service-monitor"
        echo "     ./install_monitor.sh"
        echo ""
        echo "方式2: 手动上传缺失的文件"
        for file in "${missing_files[@]}"; do
            echo "  scp 8.service-monitor/${file} root@your-server:${SCRIPT_DIR}/"
        done
        echo ""
        echo "  然后重新运行安装脚本"
        echo ""
        exit 1
    fi

    # 检查脚本是否有执行权限
    if [ ! -x "${SCRIPT_DIR}/service_monitor.sh" ]; then
        print_warning "service_monitor.sh 没有执行权限，正在添加..."
        chmod +x "${SCRIPT_DIR}/service_monitor.sh"
    fi

    if [ ! -x "${SCRIPT_DIR}/send_email.sh" ]; then
        print_warning "send_email.sh 没有执行权限，正在添加..."
        chmod +x "${SCRIPT_DIR}/send_email.sh"
    fi

    print_success "脚本文件检查通过"
}

################################################################################
# 创建安装目录
################################################################################

create_directories() {
    print_info "创建安装目录..."

    # 创建安装目录
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$LOG_DIR"

    print_success "目录创建完成"
}

################################################################################
# 复制脚本文件
################################################################################

install_scripts() {
    print_info "安装监控脚本..."

    # 复制主监控脚本
    cp "${SCRIPT_DIR}/service_monitor.sh" "$INSTALL_DIR/"
    chmod +x "${INSTALL_DIR}/service_monitor.sh"

    # 复制邮件发送脚本
    cp "${SCRIPT_DIR}/send_email.sh" "$INSTALL_DIR/"
    chmod +x "${INSTALL_DIR}/send_email.sh"

    # ==========================================================================
    # 配置文件处理逻辑（优先级顺序）
    # ==========================================================================
    # 优先级1: /root/config.conf（用户预先准备）
    # 优先级2: 服务器上已有配置 /opt/service-monitor/config.conf
    # 优先级3: 本地配置文件 ${SCRIPT_DIR}/config.conf
    # 优先级4: 使用模板配置（首次安装默认）
    # ==========================================================================

    local user_prepared_config="/root/config.conf"
    local installed_config="${INSTALL_DIR}/config.conf"
    local local_config="${SCRIPT_DIR}/config.conf"

    if [ -f "$installed_config" ]; then
        # ======================================================================
        # 场景1: 服务器上已有配置文件（非首次安装）
        # ======================================================================
        print_success "配置文件已存在: ${INSTALL_DIR}/config.conf"

        # 检查用户是否在 /root/ 准备了新配置
        if [ -f "$user_prepared_config" ]; then
            local user_smtp_user=$(grep "^SMTP_USER=" "$user_prepared_config" | cut -d'"' -f2)
            if [ -n "$user_smtp_user" ] && [ "$user_smtp_user" != "your-email@gmail.com" ]; then
                print_warning "检测到 /root/config.conf 配置文件"
                read -p "是否用 /root/config.conf 覆盖现有配置？(y/n) [默认: n]: " use_root_config
                if [ "$use_root_config" = "y" ] || [ "$use_root_config" = "Y" ]; then
                    cp "$user_prepared_config" "$installed_config"
                    print_success "已使用 /root/config.conf 更新配置"
                    # 清理用户准备的配置文件（可选）
                    read -p "是否删除 /root/config.conf？(y/n) [默认: y]: " remove_root_config
                    remove_root_config=${remove_root_config:-y}
                    if [ "$remove_root_config" = "y" ] || [ "$remove_root_config" = "Y" ]; then
                        rm -f "$user_prepared_config"
                        print_info "已删除 /root/config.conf"
                    fi
                else
                    print_info "保留服务器上的现有配置"
                fi
            fi
        else
            # 检查本地配置文件是否已修改
            if [ -f "$local_config" ]; then
                local local_smtp_user=$(grep "^SMTP_USER=" "$local_config" | cut -d'"' -f2)
                if [ -n "$local_smtp_user" ] && [ "$local_smtp_user" != "your-email@gmail.com" ]; then
                    print_warning "检测到本地配置文件已修改"
                    read -p "是否用本地配置覆盖服务器配置？(y/n) [默认: n]: " overwrite_config
                    if [ "$overwrite_config" = "y" ] || [ "$overwrite_config" = "Y" ]; then
                        cp "$local_config" "$installed_config"
                        print_success "已用本地配置覆盖服务器配置"
                    else
                        print_info "保留服务器上的现有配置"
                    fi
                else
                    print_info "保留服务器上的现有配置（本地配置未修改）"
                fi
            else
                print_info "保留服务器上的现有配置"
            fi
        fi
    else
        # ======================================================================
        # 场景2: 服务器上没有配置文件（首次安装）
        # ======================================================================
        print_info "首次安装，准备配置文件..."

        # 优先级1: 检查用户是否在 /root/ 准备了配置
        if [ -f "$user_prepared_config" ]; then
            local user_smtp_user=$(grep "^SMTP_USER=" "$user_prepared_config" | cut -d'"' -f2)

            if [ -n "$user_smtp_user" ] && [ "$user_smtp_user" != "your-email@gmail.com" ]; then
                # 用户已填写配置
                print_success "检测到用户预先准备的配置文件: /root/config.conf"
                cp "$user_prepared_config" "$installed_config"
                print_success "已使用 /root/config.conf 作为配置文件"

                # 显示配置摘要
                local server_name=$(grep "^SERVER_NAME=" "$installed_config" | cut -d'"' -f2)
                local smtp_server=$(grep "^SMTP_SERVER=" "$installed_config" | cut -d'"' -f2)
                local smtp_port=$(grep "^SMTP_PORT=" "$installed_config" | cut -d'"' -f2)
                local email_to=$(grep "^EMAIL_TO=" "$installed_config" | cut -d'"' -f2)

                echo ""
                echo "配置摘要："
                echo "  服务器名称: $server_name"
                echo "  SMTP服务器: $smtp_server:$smtp_port"
                echo "  发件邮箱: $user_smtp_user"
                echo "  收件邮箱: $email_to"
                echo ""

                # 询问是否删除 /root/config.conf
                read -p "是否删除 /root/config.conf？(y/n) [默认: y]: " remove_root_config
                remove_root_config=${remove_root_config:-y}
                if [ "$remove_root_config" = "y" ] || [ "$remove_root_config" = "Y" ]; then
                    rm -f "$user_prepared_config"
                    print_info "已删除 /root/config.conf"
                fi
            else
                # 用户准备了配置文件但未填写，使用本地配置
                print_warning "/root/config.conf 存在但未填写，使用本地配置"
                cp "$local_config" "$installed_config"
            fi
        else
            # 优先级2: 使用本地配置文件
            if [ -f "$local_config" ]; then
                cp "$local_config" "$installed_config"
                local local_smtp_user=$(grep "^SMTP_USER=" "$installed_config" | cut -d'"' -f2)

                if [ -n "$local_smtp_user" ] && [ "$local_smtp_user" != "your-email@gmail.com" ]; then
                    print_success "检测到本地配置文件已预先填写，将使用现有配置"
                else
                    print_warning "配置文件已复制到: ${INSTALL_DIR}/config.conf"
                    print_warning "请稍后配置监控项和邮件参数"
                fi
            else
                print_error "本地配置文件不存在: $local_config"
                exit 1
            fi
        fi

        print_info "提示：下次安装时，可以提前将配置文件放在 /root/config.conf"
    fi

    print_success "脚本安装完成"
}

################################################################################
# 配置交互式向导
################################################################################

configure_monitor() {
    print_info "开始配置向导..."

    local config_file="${INSTALL_DIR}/config.conf"

    # 读取当前配置值
    local current_server_name=$(grep "^SERVER_NAME=" "$config_file" | cut -d'"' -f2)
    local current_smtp_server=$(grep "^SMTP_SERVER=" "$config_file" | cut -d'"' -f2)
    local current_smtp_port=$(grep "^SMTP_PORT=" "$config_file" | cut -d'"' -f2)
    local current_smtp_user=$(grep "^SMTP_USER=" "$config_file" | cut -d'"' -f2)
    local current_smtp_pass=$(grep "^SMTP_PASS=" "$config_file" | cut -d'"' -f2)
    local current_email_to=$(grep "^EMAIL_TO=" "$config_file" | cut -d'"' -f2)
    local current_cpu_threshold=$(grep "^CPU_THRESHOLD=" "$config_file" | cut -d'"' -f2)
    local current_memory_threshold=$(grep "^MEMORY_THRESHOLD=" "$config_file" | cut -d'"' -f2)
    local current_disk_threshold=$(grep "^DISK_THRESHOLD=" "$config_file" | cut -d'"' -f2)

    # 检查配置文件是否已经配置过
    local is_configured=false
    if [ -n "$current_smtp_user" ] && [ "$current_smtp_user" != "your-email@gmail.com" ]; then
        is_configured=true
        print_success "检测到配置文件已存在且已配置"
        echo ""
        echo "当前配置："
        echo "  服务器名称: $current_server_name"
        echo "  SMTP服务器: $current_smtp_server:$current_smtp_port"
        echo "  发件邮箱: $current_smtp_user"
        echo "  收件邮箱: $current_email_to"
        echo "  CPU阈值: ${current_cpu_threshold}%"
        echo "  内存阈值: ${current_memory_threshold}%"
        echo "  磁盘阈值: ${current_disk_threshold}%"
        echo ""
    fi

    # 询问是否进入配置向导
    if [ "$is_configured" = true ]; then
        read -p "是否修改配置？(y/n) [默认: n]: " modify_config
        if [ "$modify_config" != "y" ] && [ "$modify_config" != "Y" ]; then
            print_info "保留现有配置"
            return
        fi
        echo ""
        print_info "进入配置修改模式（直接回车保持原值）"
    else
        read -p "是否现在配置监控参数？(y/n): " configure_now
        if [ "$configure_now" != "y" ] && [ "$configure_now" != "Y" ]; then
            print_warning "跳过配置，稍后可手动编辑: ${INSTALL_DIR}/config.conf"
            return
        fi
    fi

    echo ""

    # =========================================================================
    # 配置服务器名称
    # =========================================================================
    local server_name
    if [ -n "$current_server_name" ]; then
        read -p "服务器名称 [当前: $current_server_name]: " server_name
        server_name=${server_name:-$current_server_name}
    else
        read -p "服务器名称 [默认: $(hostname)]: " server_name
        server_name=${server_name:-$(hostname)}
    fi
    sed -i "s/^SERVER_NAME=.*/SERVER_NAME=\"$server_name\"/" "$config_file"

    # =========================================================================
    # 配置邮件服务器
    # =========================================================================
    echo ""
    print_info "=== 邮件告警配置 ==="

    # SMTP 服务器
    local smtp_server smtp_port smtp_ssl

    if [ -n "$current_smtp_server" ] && [ "$current_smtp_server" != "smtp.gmail.com" ]; then
        # 已有自定义配置，直接显示当前值
        read -p "SMTP服务器 [当前: $current_smtp_server]: " smtp_server
        smtp_server=${smtp_server:-$current_smtp_server}

        read -p "SMTP端口 [当前: $current_smtp_port]: " smtp_port
        smtp_port=${smtp_port:-$current_smtp_port}

        local current_smtp_ssl=$(grep "^SMTP_USE_SSL=" "$config_file" | cut -d'"' -f2)
        read -p "是否使用SSL? (y/n) [当前: $current_smtp_ssl]: " use_ssl
        use_ssl=${use_ssl:-$current_smtp_ssl}
        if [ "$use_ssl" = "y" ] || [ "$use_ssl" = "Y" ] || [ "$use_ssl" = "true" ]; then
            smtp_ssl="true"
        else
            smtp_ssl="false"
        fi
    else
        # 首次配置或使用默认值，显示选项
        echo "常用SMTP服务器："
        echo "  1) Gmail:     smtp.gmail.com:465 (SSL)"
        echo "  2) QQ邮箱:    smtp.qq.com:465 (SSL)"
        echo "  3) 163邮箱:   smtp.163.com:465 (SSL)"
        echo "  4) Outlook:   smtp-mail.outlook.com:587 (TLS)"
        echo "  5) 保持当前: $current_smtp_server:$current_smtp_port"
        echo "  6) 自定义"

        local default_choice="5"
        read -p "请选择邮箱类型 [1-6, 默认: $default_choice]: " email_choice
        email_choice=${email_choice:-$default_choice}

        case $email_choice in
            1)
                smtp_server="smtp.gmail.com"
                smtp_port="465"
                smtp_ssl="true"
                ;;
            2)
                smtp_server="smtp.qq.com"
                smtp_port="465"
                smtp_ssl="true"
                ;;
            3)
                smtp_server="smtp.163.com"
                smtp_port="465"
                smtp_ssl="true"
                ;;
            4)
                smtp_server="smtp-mail.outlook.com"
                smtp_port="587"
                smtp_ssl="false"
                sed -i "s/^SMTP_USE_TLS=.*/SMTP_USE_TLS=\"true\"/" "$config_file"
                ;;
            5)
                smtp_server="$current_smtp_server"
                smtp_port="$current_smtp_port"
                smtp_ssl=$(grep "^SMTP_USE_SSL=" "$config_file" | cut -d'"' -f2)
                ;;
            6)
                read -p "请输入SMTP服务器地址: " smtp_server
                read -p "请输入SMTP端口 [默认: 465]: " smtp_port
                smtp_port=${smtp_port:-465}
                read -p "是否使用SSL? (y/n) [默认: y]: " use_ssl
                use_ssl=${use_ssl:-y}
                if [ "$use_ssl" = "y" ] || [ "$use_ssl" = "Y" ]; then
                    smtp_ssl="true"
                else
                    smtp_ssl="false"
                fi
                ;;
            *)
                print_warning "无效选择，保持当前配置"
                smtp_server="$current_smtp_server"
                smtp_port="$current_smtp_port"
                smtp_ssl=$(grep "^SMTP_USE_SSL=" "$config_file" | cut -d'"' -f2)
                ;;
        esac
    fi

    sed -i "s/^SMTP_SERVER=.*/SMTP_SERVER=\"$smtp_server\"/" "$config_file"
    sed -i "s/^SMTP_PORT=.*/SMTP_PORT=\"$smtp_port\"/" "$config_file"
    sed -i "s/^SMTP_USE_SSL=.*/SMTP_USE_SSL=\"$smtp_ssl\"/" "$config_file"

    # =========================================================================
    # 配置邮箱账号
    # =========================================================================
    local smtp_user smtp_pass email_to

    if [ -n "$current_smtp_user" ]; then
        read -p "发件邮箱地址 [当前: $current_smtp_user]: " smtp_user
        smtp_user=${smtp_user:-$current_smtp_user}
    else
        read -p "发件邮箱地址: " smtp_user
    fi

    if [ -n "$current_smtp_pass" ] && [ "$current_smtp_pass" != "your-app-password" ]; then
        # 隐藏密码显示
        local masked_pass="${current_smtp_pass:0:4} **** **** ****"
        read -sp "邮箱密码（应用专用密码）[当前: $masked_pass, 回车保持不变]: " smtp_pass
        echo ""
        smtp_pass=${smtp_pass:-$current_smtp_pass}
    else
        read -sp "邮箱密码（应用专用密码）: " smtp_pass
        echo ""
    fi

    if [ -n "$current_email_to" ]; then
        read -p "收件邮箱地址 [当前: $current_email_to]: " email_to
        email_to=${email_to:-$current_email_to}
    else
        read -p "收件邮箱地址: " email_to
    fi

    sed -i "s/^SMTP_USER=.*/SMTP_USER=\"$smtp_user\"/" "$config_file"
    sed -i "s/^SMTP_PASS=.*/SMTP_PASS=\"$smtp_pass\"/" "$config_file"
    sed -i "s/^EMAIL_FROM=.*/EMAIL_FROM=\"服务监控 <$smtp_user>\"/" "$config_file"
    sed -i "s/^EMAIL_TO=.*/EMAIL_TO=\"$email_to\"/" "$config_file"

    # =========================================================================
    # 配置监控项（可选）
    # =========================================================================
    echo ""
    print_info "=== 监控项配置（可选，直接回车跳过）==="

    # Systemd 服务
    local current_systemd=$(grep "^MONITOR_SYSTEMD_SERVICES=" "$config_file" | cut -d'"' -f2)
    if [ -n "$current_systemd" ]; then
        echo "当前监控的systemd服务: $current_systemd"
        read -p "是否修改？(y/n) [默认: n]: " modify_systemd
        if [ "$modify_systemd" = "y" ] || [ "$modify_systemd" = "Y" ]; then
            read -p "systemd服务（格式: nginx:Nginx;v2ray:V2Ray）: " systemd_services
            if [ -n "$systemd_services" ]; then
                sed -i "s|^MONITOR_SYSTEMD_SERVICES=.*|MONITOR_SYSTEMD_SERVICES=\"$systemd_services\"|" "$config_file"
            fi
        fi
    else
        read -p "systemd服务（格式: nginx:Nginx;v2ray:V2Ray，留空跳过）: " systemd_services
        if [ -n "$systemd_services" ]; then
            sed -i "s|^MONITOR_SYSTEMD_SERVICES=.*|MONITOR_SYSTEMD_SERVICES=\"$systemd_services\"|" "$config_file"
        fi
    fi

    # Docker 容器
    local current_docker=$(grep "^MONITOR_DOCKER_CONTAINERS=" "$config_file" | cut -d'"' -f2)
    if [ -n "$current_docker" ]; then
        echo "当前监控的Docker容器: $current_docker"
        read -p "是否修改？(y/n) [默认: n]: " modify_docker
        if [ "$modify_docker" = "y" ] || [ "$modify_docker" = "Y" ]; then
            read -p "Docker容器（格式: container1:描述1;container2:描述2）: " docker_containers
            if [ -n "$docker_containers" ]; then
                sed -i "s|^MONITOR_DOCKER_CONTAINERS=.*|MONITOR_DOCKER_CONTAINERS=\"$docker_containers\"|" "$config_file"
            fi
        fi
    else
        read -p "Docker容器（格式: container1:描述1，留空跳过）: " docker_containers
        if [ -n "$docker_containers" ]; then
            sed -i "s|^MONITOR_DOCKER_CONTAINERS=.*|MONITOR_DOCKER_CONTAINERS=\"$docker_containers\"|" "$config_file"
        fi
    fi

    # =========================================================================
    # 资源监控阈值
    # =========================================================================
    echo ""
    print_info "=== 资源监控阈值 ==="

    local cpu_threshold memory_threshold disk_threshold

    read -p "CPU告警阈值（百分比）[当前: $current_cpu_threshold]: " cpu_threshold
    cpu_threshold=${cpu_threshold:-$current_cpu_threshold}
    sed -i "s/^CPU_THRESHOLD=.*/CPU_THRESHOLD=\"$cpu_threshold\"/" "$config_file"

    read -p "内存告警阈值（百分比）[当前: $current_memory_threshold]: " memory_threshold
    memory_threshold=${memory_threshold:-$current_memory_threshold}
    sed -i "s/^MEMORY_THRESHOLD=.*/MEMORY_THRESHOLD=\"$memory_threshold\"/" "$config_file"

    read -p "磁盘告警阈值（百分比）[当前: $current_disk_threshold]: " disk_threshold
    disk_threshold=${disk_threshold:-$current_disk_threshold}
    sed -i "s/^DISK_THRESHOLD=.*/DISK_THRESHOLD=\"$disk_threshold\"/" "$config_file"

    echo ""
    print_success "配置已更新"
    print_info "配置文件位置: $config_file"
}

################################################################################
# 设置定时任务
################################################################################

setup_cron() {
    print_info "设置定时任务..."

    # 读取监控间隔
    local interval
    interval=$(grep "^MONITOR_INTERVAL=" "${INSTALL_DIR}/config.conf" | cut -d'"' -f2)
    interval=${interval:-5}

    # 创建 cron 任务
    local cron_line="*/${interval} * * * * ${INSTALL_DIR}/service_monitor.sh >> ${LOG_DIR}/cron.log 2>&1"

    # 检查 cron 任务是否已存在
    if crontab -l 2>/dev/null | grep -q "service_monitor.sh"; then
        print_info "定时任务已存在，跳过创建"
    else
        # 添加 cron 任务
        (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
        print_success "定时任务已创建（每 ${interval} 分钟执行一次）"
    fi

    # 启动 cron 服务
    if command -v systemctl &> /dev/null; then
        systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
        systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || true
    fi
}

################################################################################
# 测试运行
################################################################################

test_monitor() {
    print_info "执行测试运行..."

    # 执行一次监控
    bash "${INSTALL_DIR}/service_monitor.sh"

    if [ $? -eq 0 ]; then
        print_success "测试运行成功"
        print_info "日志文件: ${LOG_DIR}/monitor_$(date +%Y%m%d).log"
    else
        print_error "测试运行失败，请检查配置"
    fi
}

################################################################################
# 显示安装信息
################################################################################

show_install_info() {
    echo ""
    echo "================================================================"
    print_success "服务监控系统安装完成！"
    echo "================================================================"
    echo ""
    echo "安装路径: ${INSTALL_DIR}"
    echo "配置文件: ${INSTALL_DIR}/config.conf"
    echo "日志目录: ${LOG_DIR}"
    echo ""
    echo "常用命令："
    echo "  手动执行监控:   bash ${INSTALL_DIR}/service_monitor.sh"
    echo "  查看日志:       tail -f ${LOG_DIR}/monitor_\$(date +%Y%m%d).log"
    echo "  编辑配置:       vi ${INSTALL_DIR}/config.conf"
    echo "  查看定时任务:   crontab -l | grep service_monitor"
    echo ""
    echo "下一步："
    echo "  1. 编辑配置文件设置监控项和邮件参数"
    echo "  2. 测试邮件发送是否正常"
    echo "  3. 根据需要调整监控阈值"
    echo ""
    echo "================================================================"
}

################################################################################
# 主函数
################################################################################

main() {
    echo "================================================================"
    echo "           服务监控系统 - 一键安装部署脚本"
    echo "================================================================"
    echo ""

    # 环境检查
    check_environment

    # 检查脚本文件完整性
    check_script_files

    # 创建目录
    create_directories

    # 安装脚本
    install_scripts

    # 配置向导
    configure_monitor

    # 设置定时任务
    read -p "是否设置定时任务（cron）？(y/n): " setup_cron_choice
    if [ "$setup_cron_choice" = "y" ] || [ "$setup_cron_choice" = "Y" ]; then
        setup_cron
    fi

    # 测试运行
    read -p "是否立即测试运行？(y/n): " test_choice
    if [ "$test_choice" = "y" ] || [ "$test_choice" = "Y" ]; then
        test_monitor
    fi

    # 显示安装信息
    show_install_info
}

# 执行主函数
main "$@"
