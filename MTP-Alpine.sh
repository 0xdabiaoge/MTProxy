#!/bin/bash

#================================================================
# MTProxy 增强版安装脚本 (Alpine 系统专用最终修复版)
#
# 功能:
# - 专为 Alpine Linux 适配，使用 apk 和 OpenRC。
# - 一键安装，并自动配置 OpenRC 守护进程，实现开机自启和稳定运行。
# - 菜单式交互，包含安装、卸载、重启和状态查看。
# - 版本: v1.0.11
#================================================================

#------------------[ 脚本核心逻辑 ]------------------

# 检查是否使用 bash 运行
if [ -z "$BASH_VERSION" ]; then
    echo "错误: 请使用 bash 运行此脚本 (例如: bash MTP_Alpine.sh)"
    exit 1
fi

#彩色输出
red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}
green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}
yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

# 变量定义
WORKDIR="/home/mtproxy"
CONFIG_FILE="${WORKDIR}/mtg.conf"
MTG_BINARY="mtg"
SERVICE_NAME="mtproxy"
SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
PID_FILE="/run/${SERVICE_NAME}.pid"
# 获取脚本自身的路径
SCRIPT_PATH=$(readlink -f "$0")


# --- 功能函数 ---

# 检查服务是否在运行 (通过 OpenRC)
is_service_running() {
    if [ -f "$SERVICE_FILE" ]; then
        # rc-service status 返回 0 表示正在运行
        rc-service ${SERVICE_NAME} status >/dev/null 2>&1
        return $?
    fi
    return 1 # 如果服务文件不存在，则肯定没在运行
}

# 启动服务
start_mtproxy(){
    if [ -f "$SERVICE_FILE" ]; then
        yellow "通过 OpenRC 启动服务..."
        rc-service ${SERVICE_NAME} start
        sleep 2
        if ! is_service_running; then
             red "服务启动失败！请检查日志文件: ${WORKDIR}/mtg.log"
             exit 1
        fi
    else
        red "错误: 未找到 OpenRC 服务文件，请先执行安装。"
        exit 1
    fi
}

# 停止服务
stop_mtproxy(){
    if [ -f "$SERVICE_FILE" ]; then
        yellow "通过 OpenRC 停止服务..."
        rc-service ${SERVICE_NAME} stop
    fi
    # 确保进程被杀死 (作为后备)
    pkill -f "${WORKDIR}/${MTG_BINARY}" > /dev/null 2>&1
    # 强制删除 PID 文件，防止状态残留
    rm -f "${PID_FILE}"
    green "服务已停止。"
}

# 安装
install_mtproxy(){
    # 检查是否为 root 用户
    if [ "$EUID" -ne 0 ]; then
      red "错误: 请以 root 用户权限运行此脚本！"
      exit 1
    fi
    
    if [ -d "$WORKDIR" ]; then
        yellow "检测到已安装 MTProxy，如果继续，将会覆盖安装。"
        read -p "是否继续? (y/n): " confirm
        if [[ $confirm != "y" ]]; then
            green "操作已取消。"
            exit 0
        fi
    fi

    # 1. 自定义配置
    yellow "--- 开始进行交互式配置 ---"
    
    while true; do
        read -p "请输入您想使用的代理端口 ( 默认: 8443 ): " PORT
        [ -z "$PORT" ] && PORT="8443"
        if [[ "$PORT" -gt 0 && "$PORT" -le 65535 ]]; then
            green "端口设置为: $PORT"
            break
        else
            red "端口输入无效，请输入 1-65535 之间的数字。"
        fi
    done

    while true; do
        read -p "请输入您要伪装的域名 (默认: www.microsoft.com): " FAKE_DOMAIN
        [ -z "$FAKE_DOMAIN" ] && FAKE_DOMAIN="www.microsoft.com"
        if [ -n "$FAKE_DOMAIN" ]; then
            green "伪装域名设置为: $FAKE_DOMAIN"
            break
        else
            red "伪装域名不能为空。"
        fi
    done

    # 2. 安装依赖 (Alpine apk)
    yellow "正在为 Alpine 系统安装必要的依赖工具..."
    if command -v apk &> /dev/null; then
        apk update
        apk add bash curl wget openssl coreutils procps-ng bind-tools tar
    else
        red "错误: 这不是一个 Alpine 系统，或者 apk 命令不可用。"
        exit 1
    fi
    green "依赖安装完成。"

    # 3. 创建工作目录
    yellow "正在创建工作目录: $WORKDIR"
    stop_mtproxy # 停止旧服务
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
    cd "$WORKDIR" || exit

    # 4. 下载 MTProxy 程序
    yellow "正在下载 MTProxy 代理程序 (v1.0.11)..."
    ARCH=$(uname -m)
    case $ARCH in
        "x86_64") ARCH="amd64" ;;
        "aarch64") ARCH="arm64" ;;
        *) red "错误: 此脚本优化版暂不支持您的系统架构: $ARCH"; exit 1 ;;
    esac

    MTG_URL="https://github.com/9seconds/mtg/releases/download/v1.0.11/mtg-1.0.11-linux-${ARCH}.tar.gz"
    wget -q -O mtg.tar.gz "$MTG_URL"
    if [ $? -ne 0 ]; then
        red "下载代理程序失败，请检查网络或访问 Github 的能力。"
        exit 1
    fi

    tar xzf mtg.tar.gz "mtg-1.0.11-linux-${ARCH}/mtg" --strip-components=1
    rm mtg.tar.gz
    chmod +x "$MTG_BINARY"
    green "代理程序下载完成。"

    # 5. 生成配置并保存
    yellow "正在生成配置..."
    SECRET=$( (date +%s%N; ps -ef; echo $$) | sha256sum | head -c 32 )
    TLS_SECRET="ee${SECRET}$(echo -n ${FAKE_DOMAIN} | xxd -p -c 256)"
    
    echo "PORT=${PORT}" > $CONFIG_FILE
    echo "TLS_SECRET=${TLS_SECRET}" >> $CONFIG_FILE
    green "配置文件已保存至: $CONFIG_FILE"

    # 6. 安装并启动 OpenRC 守护进程 (最终修复版)
    yellow "正在安装并启动 OpenRC 守护进程..."
    
    SERVICE_CONTENT="#!/sbin/openrc-run
description=\"MTProxy Service\"

depend() {
    need net
}

# 静态变量
WORKDIR=\"${WORKDIR}\"
CONFIG_FILE=\"\${WORKDIR}/mtg.conf\"
MTG_BINARY=\"\${WORKDIR}/mtg\"
LOG_FILE=\"\${WORKDIR}/mtg.log\"
PID_FILE=\"${PID_FILE}\"

command=\"\${MTG_BINARY}\"
command_background=true
pidfile=\"\${PID_FILE}\"

# 在启动前运行
start_pre() {
    # 检查配置是否存在
    if [ ! -f \"\${CONFIG_FILE}\" ]; then
        eerror \"Configuration file \${CONFIG_FILE} not found.\"
        return 1
    fi
    # 动态加载配置
    source \"\${CONFIG_FILE}\"
    
    # 检查程序是否存在且可执行
    if [ ! -x \"\${command}\" ]; then
        eerror \"MTProxy binary \${command} not found or not executable.\"
        return 1
    fi
    
    # 设置最终的启动参数
    command_args=\"run -b 0.0.0.0:\${PORT} \${TLS_SECRET} >> \${LOG_FILE} 2>&1\"
}
"
    echo -e "${SERVICE_CONTENT}" > $SERVICE_FILE
    chmod +x $SERVICE_FILE
    
    rc-update add ${SERVICE_NAME} default
    rc-service ${SERVICE_NAME} start
    
    # 7. 显示结果
    sleep 2 # 给服务一点启动时间
    if ! is_service_running; then
        red "守护进程启动失败，请检查日志文件: ${WORKDIR}/mtg.log"
        exit 1
    fi
    green "✅ MTProxy 已通过守护进程成功安装并启动！"

    PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com || curl -s https://ipv4.icanhazip.com)
    if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == *"html"* ]]; then
        red "错误: 无法获取有效的公网 IP 地址。"
    else
        show_status
    fi
}

# 卸载 (增强版)
uninstall_mtproxy(){
    red "警告: 此操作将彻底删除 MTProxy 服务、所有相关文件以及快捷命令。"
    read -p "确定要继续吗? (y/n): " confirm
    if [[ $confirm != "y" ]]; then
        green "操作已取消。"
        return
    fi
    
    yellow "正在停止并卸载 MTProxy..."
    if [ -f "$SERVICE_FILE" ]; then
        rc-service ${SERVICE_NAME} stop
        rc-update del ${SERVICE_NAME} default
        rm -f "$SERVICE_FILE"
        green "OpenRC 服务已卸载。"
    fi
    pkill -f "${WORKDIR}/${MTG_BINARY}" > /dev/null 2>&1
    if [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
        green "安装目录已删除。"
    fi

    if [ -f "/usr/local/bin/mtp" ]; then
        rm -f "/usr/local/bin/mtp"
        green "快捷命令 /usr/local/bin/mtp 已删除。"
    fi

    if [ -f "/usr/local/bin/mtp.sh" ]; then
        rm -f "/usr/local/bin/mtp.sh"
        green "脚本文件 /usr/local/bin/mtp.sh 已删除。"
    fi

    green "✅ MTProxy 已被彻底卸载！"

    read -p "是否要删除当前脚本文件 (${SCRIPT_PATH})? (y/n): " self_delete
    if [[ $self_delete == "y" ]]; then
        green "正在删除脚本文件..."
        rm -f "${SCRIPT_PATH}"
    fi
}

# 重启
restart_mtproxy(){
    yellow "正在重启 MTProxy 服务..."
    if [ -f "$SERVICE_FILE" ]; then
        rc-service ${SERVICE_NAME} restart
    else
        red "错误：服务未安装。"
    fi
    sleep 2
    if is_service_running; then
        green "服务已重启。"
    else
        red "服务重启失败。"
    fi
}

# 显示状态
show_status() {
    clear
    if ! is_service_running; then
        red "MTProxy 服务当前未运行。"
        if [ -f "$SERVICE_FILE" ]; then
             yellow "请尝试使用 'rc-service ${SERVICE_NAME} status' 命令查看详细状态。"
        fi
        return
    fi
    
    if [ ! -f "$CONFIG_FILE" ]; then
        red "错误: 找不到配置文件 ${CONFIG_FILE}。"
        return
    fi
    
    source $CONFIG_FILE
    PUBLIC_IP=$(curl -s https://ipv4.icanhazip.com)
    
    green "✅ MTProxy 服务正在运行中。"
    echo "=================================================="
    yellow "服务器IP:    ${PUBLIC_IP}"
    yellow "端口:        ${PORT}"
    yellow "密钥 (Secret): ${TLS_SECRET}"
    echo "--------------------------------------------------"
    green "TG 一键链接 (点击即可自动配置):"
    green "https://t.me/proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${TLS_SECRET}"
    echo "=================================================="
    if is_service_running; then
        green "守护进程状态: active (运行中)"
    else
        red "守护进程状态: inactive (已停止)"
    fi
}

# --- 主菜单 ---
show_menu(){
    clear
    echo "=================================================="
    echo "         MTProxy 全自动守护版 (Alpine)"
    echo "=================================================="
    green "1. 安装 MTProxy (自动启用守护进程)"
    green "2. 卸载 MTProxy"
    green "3. 重启 MTProxy"
    green "4. 查看连接信息与状态"
    yellow "0. 退出脚本"
    echo "=================================================="
    read -p "请输入您的选择 [0-4]: " num

    case "$num" in
        1) install_mtproxy ;;
        2) uninstall_mtproxy ;;
        3) restart_mtproxy ;;
        4) show_status ;;
        0) exit 0 ;;
        *) red "输入错误，请输入有效数字 [0-4]" ;;
    esac
}

# 脚本入口
if [[ $# -gt 0 ]]; then
    case "$1" in
        install) install_mtproxy ;;
        uninstall) uninstall_mtproxy ;;
        restart) restart_mtproxy ;;
        status) show_status ;;
        *) echo "无效参数: $1，可用参数: install, uninstall, restart, status"; exit 1 ;;
    esac
else
    show_menu
fi
