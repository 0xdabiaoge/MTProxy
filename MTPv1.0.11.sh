#!/bin/bash

#================================================================
# MTProxy 安装脚本
#
# 功能:
# - 交互式安装，可自定义端口和伪装域名。
# - 支持一键彻底卸载，清理所有文件。
# - 使用的版本为：v1.0.11
#
# 使用方法:
#   bash MTPv1.0.11.sh install     # 运行交互式安装
#   bash MTPv1.0.11.sh uninstall   # 彻底卸载代理
#================================================================

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
MTG_BINARY="mtg"

# --- 安装功能 ---
function install_mtproxy(){
    # 检查是否为 root 用户
    if [ "$EUID" -ne 0 ]; then
      red "错误: 请以 root 用户权限运行此脚本！"
      exit 1
    fi

    # 1. 自定义配置
    yellow "--- 开始进行交互式配置 ---"
    
    # 提示输入端口
    while true; do
        read -p "请输入您想使用的代理端口 (例如 8443, 默认: 8443)" PORT
        [ -z "$PORT" ] && PORT="8443"
        if [[ "$PORT" -gt 0 && "$PORT" -le 65535 ]]; then
            green "端口设置为: $PORT"
            break
        else
            red "端口输入无效，请输入 1-65535 之间的数字。"
        fi
    done

    # 提示输入伪装域名
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
        yum install -y curl wget iproute net-tools tar bind-utils > /dev/null 2>&1
    elif command -v apt-get &> /dev/null; then
        apt-get update > /dev/null 2>&1
        apt-get install -y curl wget iproute2 net-tools tar dnsutils > /dev/null 2>&1
    else
        red "错误: 无法识别的包管理器，脚本终止。"
        exit 1
    fi
    green "依赖安装完成。"

    # 3. 创建工作目录
    yellow "正在创建工作目录: $WORKDIR"
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

    # 5. 生成配置并运行
    yellow "正在生成配置并启动服务..."
    pkill -f "$MTG_BINARY" > /dev/null 2>&1
    SECRET=$(head -c 16 /dev/urandom | xxd -p)
    TLS_SECRET="ee${SECRET}$(echo -n ${FAKE_DOMAIN} | xxd -p -c 256)"
    RUN_COMMAND="nohup ${WORKDIR}/${MTG_BINARY} run -b 0.0.0.0:${PORT} ${TLS_SECRET}"
    
    $RUN_COMMAND > mtg.log 2>&1 &
    sleep 2

    # 6. 显示结果
    yellow "正在获取公网 IP 地址..."
    PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)
    if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP=$(curl -s https://ipv4.icanhazip.com)
    fi

    if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == *"html"* ]]; then
        red "错误: 无法获取有效的公网 IP 地址。"
        exit 1
    fi

    if ! pgrep -f "$MTG_BINARY" > /dev/null; then
        red "服务启动失败！请检查日志文件: ${WORKDIR}/mtg.log"
        exit 1
    fi

    green "🎉 MTProxy 代理服务已成功启动！"
    echo "=================================================="
    yellow "服务器IP:    ${PUBLIC_IP}"
    yellow "端口:        ${PORT}"
    yellow "密钥 (Secret): ${TLS_SECRET}"
    echo "--------------------------------------------------"
    green "TG 一键链接 (点击即可自动配置):"
    green "https://t.me/proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${TLS_SECRET}"
    echo "=================================================="
}

# --- 卸载功能 ---
function uninstall_mtproxy(){
    yellow "正在停止 MTProxy 服务..."
    pkill -f "$MTG_BINARY"
    if [ $? -eq 0 ]; then
        green "服务已停止。"
    else
        yellow "服务未在运行。"
    fi
    
    yellow "正在删除安装目录: $WORKDIR..."
    rm -rf "$WORKDIR"
    green "目录已删除。"
    
    green "✅ MTProxy 已被彻底卸载！"
}

# --- 主菜单 ---
case "$1" in
    install)
        install_mtproxy
        ;;
    uninstall)
        uninstall_mtproxy
        ;;
    *)
        echo "使用方法: $0 [命令]"
        echo
        echo "可用命令:"
        echo "  install      运行交互式安装程序"
        echo "  uninstall    彻底卸载并清理所有文件"
        echo
        ;;
esac
