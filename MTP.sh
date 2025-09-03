#!/bin/bash

#------------------[ 脚本核心逻辑 ]------------------

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
SERVICE_FILE="/etc/systemd/system/mtproxy.service"

# --- 功能函数 ---

# 启动服务
start_mtproxy(){
    # 此脚本默认使用 systemd，此函数主要用于重启操作
    if [ -f "$SERVICE_FILE" ]; then
        yellow "通过 systemd 启动服务..."
        systemctl start mtproxy
        sleep 2 # 给 systemd 一点时间来启动
        if ! systemctl is-active --quiet mtproxy; then
             red "服务启动失败！请使用 'systemctl status mtproxy' 或 'journalctl -u mtproxy' 查看日志。"
             exit 1
        fi
    else
        red "错误: 未找到 systemd 服务文件，请先执行安装。"
        exit 1
    fi
}

# 停止服务
stop_mtproxy(){
    # 如果 systemd 服务存在, 则通过 systemd 停止
    if [ -f "$SERVICE_FILE" ]; then
        yellow "通过 systemd 停止服务..."
        systemctl stop mtproxy
    fi
    # 确保进程被杀死 (作为后备)
    pkill -f "${WORKDIR}/${MTG_BINARY}" > /dev/null 2>&1
    green "服务已停止。"
}

# 安装
install_mtproxy(){
    # 检查是否为 root 用户
    if [ "$EUID" -ne 0 ]; then
      red "错误: 请以 root 用户权限运行此脚本！"
      exit 1
    fi
    
    # 如果已安装，提示用户
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

    # 2. 安装依赖
    yellow "正在检测并安装必要的依赖工具..."
    if command -v yum &> /dev/null; then
        yum install -y curl wget iproute net-tools tar bind-utils openssl coreutils procps > /dev/null 2>&1
    elif command -v apt-get &> /dev/null; then
        apt-get update > /dev/null 2>&1
        apt-get install -y curl wget iproute2 net-tools tar dnsutils openssl coreutils procps > /dev/null 2>&1
    else
        red "错误: 无法识别的包管理器，脚本终止。"
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

    # 6. 安装并启动守护进程
    yellow "正在安装并启动 systemd 守护进程..."
    SERVICE_CONTENT="[Unit]
Description=MTProxy Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORKDIR}
ExecStart=${WORKDIR}/${MTG_BINARY} run -b 0.0.0.0:${PORT} ${TLS_SECRET}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target"

    echo -e "${SERVICE_CONTENT}" > $SERVICE_FILE
    systemctl daemon-reload
    systemctl enable mtproxy
    systemctl start mtproxy
    
    # 7. 显示结果
    sleep 2 # 给服务一点启动时间
    if ! systemctl is-active --quiet mtproxy; then
        red "守护进程启动失败，请使用 'systemctl status mtproxy' 查看日志。"
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

# 卸载
uninstall_mtproxy(){
    yellow "正在停止并卸载 MTProxy..."
    if [ -f "$SERVICE_FILE" ]; then
        systemctl stop mtproxy
        systemctl disable mtproxy
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        green "Systemd 服务已卸载。"
    fi
    pkill -f "${WORKDIR}/${MTG_BINARY}" > /dev/null 2>&1
    if [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
        green "安装目录已删除。"
    fi
    green "✅ MTProxy 已被彻底卸载！"
}

# 重启
restart_mtproxy(){
    yellow "正在重启 MTProxy 服务..."
    stop_mtproxy
    start_mtproxy
    green "服务已重启。"
}

# 显示状态
show_status() {
    clear
    if ! systemctl is-active --quiet mtproxy; then
        red "MTProxy 服务当前未运行。"
        if [ -f "$SERVICE_FILE" ]; then
             yellow "请尝试使用 'systemctl status mtproxy' 命令查看详细状态。"
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
    if systemctl is-active --quiet mtproxy; then
        green "守护进程状态: active (运行中)"
    else
        red "守护进程状态: inactive (已停止)"
    fi
}

# --- 主菜单 ---
show_menu(){
    clear
    echo "=================================================="
    echo "         MTProxy 全自动守护版管理脚本"
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
