#!/bin/bash

# 检查是否使用 bash 运行
if [ -z "$BASH_VERSION" ]; then
    echo "错误: 请使用 bash 运行此脚本 (例如: bash MTP.sh)"
    exit 1
fi

# 彩色输出
red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}
green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}
yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

# 全局变量定义
WORKDIR="/home/mtproxy"
CONFIG_FILE="${WORKDIR}/mtg.conf"
LOG_FILE="${WORKDIR}/mtg.log"
MTG_BINARY="mtg"
SERVICE_NAME="mtproxy"
SCRIPT_PATH=$(readlink -f "$0")
INIT_SYSTEM="" # 用于存储系统初始化类型

# --- 系统检测与适配模块 ---

detect_init_system() {
    if command -v systemctl &> /dev/null && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &> /dev/null && command -v rc-update &> /dev/null; then
        INIT_SYSTEM="openrc"
    else
        yellow "警告: 未检测到 systemd 或 OpenRC。将使用直接进程管理模式。"
        INIT_SYSTEM="direct"
    fi
    yellow "检测到系统管理模式: $INIT_SYSTEM"
}

# --- 统一的功能接口 ---

start_service() {
    yellow "正在启动 MTProxy 服务..."
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        systemctl start ${SERVICE_NAME}
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        rc-service ${SERVICE_NAME} start
    elif [ "$INIT_SYSTEM" == "direct" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            red "错误: 配置文件 $CONFIG_FILE 未找到。"
            return 1
        fi
        source "$CONFIG_FILE"
        nohup "${WORKDIR}/${MTG_BINARY}" run -b 0.0.0.0:${PORT} ${TLS_SECRET} >> ${LOG_FILE} 2>&1 &
    fi
    sleep 2
    if ! is_service_running; then
        red "服务启动失败！请检查日志。"
        if [ "$INIT_SYSTEM" == "systemd" ]; then
            yellow "使用 'systemctl status ${SERVICE_NAME}' 或 'journalctl -u ${SERVICE_NAME}' 查看。"
        else
            yellow "日志文件位于: ${LOG_FILE}"
        fi
        exit 1
    fi
}

stop_service() {
    yellow "正在停止 MTProxy 服务..."
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        systemctl stop ${SERVICE_NAME} > /dev/null 2>&1
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        if [ -f "/etc/init.d/${SERVICE_NAME}" ]; then
            rc-service ${SERVICE_NAME} stop > /dev/null 2>&1
        fi
    fi
    pkill -f "${WORKDIR}/${MTG_BINARY}" > /dev/null 2>&1
    sleep 1
    green "服务已停止。"
}

restart_service() {
    yellow "正在重启 MTProxy 服务..."
    stop_service
    start_service
    sleep 2
    if is_service_running; then
        green "服务已重启。"
    else
        red "服务重启失败。"
    fi
}

is_service_running() {
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        systemctl is-active --quiet ${SERVICE_NAME}
        return $?
    elif [ "$INIT_SYSTEM" == "openrc" ]; then
        rc-service ${SERVICE_NAME} status >/dev/null 2>&1
        return $?
    elif [ "$INIT_SYSTEM" == "direct" ]; then
        pgrep -f "${WORKDIR}/${MTG_BINARY}" > /dev/null 2>&1
        return $?
    fi
    return 1
}

# --- 核心安装/卸载逻辑 ---

install_mtproxy() {
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
        read -p "请输入您要伪装的域名 (默认: www.apple.com): " FAKE_DOMAIN
        [ -z "$FAKE_DOMAIN" ] && FAKE_DOMAIN="www.apple.com"
        if [ -n "$FAKE_DOMAIN" ]; then
            green "伪装域名设置为: $FAKE_DOMAIN"
            break
        else
            red "伪装域名不能为空。"
        fi
    done

    yellow "正在安装必要的依赖工具..."
    if command -v apt-get &> /dev/null; then
        apt-get update -y
        # **【修正】** 移除 vim-common，不再需要 xxd
        apt-get install -y --no-install-recommends curl wget tar openssl procps coreutils
    elif command -v yum &> /dev/null;then
        yum install -y curl wget tar openssl procps coreutils
    elif command -v apk &> /dev/null; then
        apk update
        apk add curl wget tar openssl procps-ng coreutils
    else
        red "错误: 无法识别的包管理器 (apt/yum/apk)，脚本终止。"
        exit 1
    fi
    green "依赖安装完成。"

    stop_service
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
    cd "$WORKDIR" || exit

    yellow "正在下载 MTProxy 代理程序 (v1.0.11)..."
    ARCH=$(uname -m)
    case $ARCH in
        "x86_64") ARCH="amd64" ;;
        "aarch64") ARCH="arm64" ;;
        *) red "错误: 不支持您的系统架构: $ARCH"; exit 1 ;;
    esac

    MTG_URL="https://github.com/9seconds/mtg/releases/download/v1.0.11/mtg-1.0.11-linux-${ARCH}.tar.gz"
    
    wget -O mtg.tar.gz "$MTG_URL"
    if [ $? -ne 0 ]; then
        red "下载代理程序失败，请检查网络或 Github 连接。"
        exit 1
    fi

    tar xzf mtg.tar.gz "mtg-1.0.11-linux-${ARCH}/mtg" --strip-components=1
    rm mtg.tar.gz
    
    if [ ! -f "$MTG_BINARY" ]; then
        red "错误: 解压失败，未能找到 '$MTG_BINARY' 文件。"
        exit 1
    fi
    chmod +x "$MTG_BINARY"
    green "代理程序下载和解压完成。"

    yellow "正在生成配置..."
    SECRET=$( (date +%s%N; ps -ef; echo $$) | sha256sum | head -c 32 )
    # **【修正】** 使用 od 和 tr 替代 xxd，无需额外依赖
    HEX_DOMAIN=$(echo -n ${FAKE_DOMAIN} | od -A n -t x1 | tr -d ' \n')
    TLS_SECRET="ee${SECRET}${HEX_DOMAIN}"
    
    echo "PORT=${PORT}" > $CONFIG_FILE
    echo "TLS_SECRET=${TLS_SECRET}" >> $CONFIG_FILE
    green "配置文件已保存至: $CONFIG_FILE"

    if [ "$INIT_SYSTEM" == "systemd" ]; then
        yellow "正在安装 Systemd 服务..."
        SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
        SERVICE_CONTENT="[Unit]
Description=MTProxy Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORKDIR}
EnvironmentFile=${CONFIG_FILE}
ExecStart=${WORKDIR}/${MTG_BINARY} run -b 0.0.0.0:\${PORT} \${TLS_SECRET}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target"
        echo -e "${SERVICE_CONTENT}" > $SERVICE_FILE
        systemctl daemon-reload
        systemctl enable ${SERVICE_NAME}
    fi
    
    start_service
    green "✅ MTProxy 已通过 '$INIT_SYSTEM' 模式成功安装并启动！"
    show_status
}

uninstall_mtproxy() {
    red "警告: 此操作将彻底删除 MTProxy 服务、所有相关文件。"
    read -p "确定要继续吗? (y/n): " confirm
    if [[ $confirm != "y" ]]; then
        green "操作已取消。"
        return
    fi
    stop_service
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
        if [ -f "$SERVICE_FILE" ]; then
            systemctl disable ${SERVICE_NAME} > /dev/null 2>&1
            rm -f "$SERVICE_FILE"
            systemctl daemon-reload
            green "Systemd 服务已卸载。"
        fi
    fi
    rm -rf "$WORKDIR"
    green "安装目录已删除。"
    green "✅ MTProxy 已被彻底卸载！"
}

show_status() {
    if ! [ -d "$WORKDIR" ] || ! [ -f "$CONFIG_FILE" ]; then
        clear; red "MTProxy 未安装。"; return
    fi
    clear
    source $CONFIG_FILE
    PUBLIC_IP=$(curl -s https://ipv4.icanhazip.com || curl -s https://api.ipify.org)
    echo "=================================================="
    if is_service_running; then
        green "✅ MTProxy 服务正在运行中。"
    else
        red "❌ MTProxy 服务当前未运行。"
        yellow "   你可以尝试使用 'bash MTP.sh restart' 来启动它。"
    fi
    echo "=================================================="
    yellow "服务器IP:    ${PUBLIC_IP}"
    yellow "端口:        ${PORT}"
    yellow "密钥 (Secret): ${TLS_SECRET}"
    echo "--------------------------------------------------"
    green "TG 一键链接 (点击或复制到浏览器打开):"
    green "https://t.me/proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${TLS_SECRET}"
    echo "=================================================="
    if [ "$INIT_SYSTEM" == "systemd" ]; then
        green "进程状态: active (运行中) - by systemd"
        yellow "查看日志: journalctl -u ${SERVICE_NAME} -f"
    elif is_service_running; then
        green "进程状态: active (运行中) - by $INIT_SYSTEM"
        yellow "日志文件: ${LOG_FILE}"
    fi
}

# --- 主菜单 ---
show_menu(){
    clear
    echo "=================================================="
    echo "     MTProxy 一键安装脚本  "
    echo "=================================================="
    green "1. 安装 MTProxy"
    green "2. 卸载 MTProxy"
    green "3. 重启 MTProxy"
    green "4. 查看连接信息与状态"
    yellow "0. 退出脚本"
    echo "=================================================="
    read -p "请输入您的选择 [0-4]: " num

    case "$num" in
        1) install_mtproxy ;;
        2) uninstall_mtproxy ;;
        3) restart_service ;;
        4) show_status ;;
        0) exit 0 ;;
        *) red "输入错误，请输入有效数字 [0-4]" ;;
    esac
}

# --- 脚本入口 ---
detect_init_system
if [[ $# -gt 0 ]]; then
    case "$1" in
        install) install_mtproxy ;;
        uninstall) uninstall_mtproxy ;;
        restart) restart_service ;;
        status) show_status ;;
        *) red "无效参数: $1，可用参数: install, uninstall, restart, status"; exit 1 ;;
    esac
else
    show_menu
fi
