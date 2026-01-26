#!/bin/bash

# 全局配置
WORKDIR="/opt/mtproxy"
CONFIG_DIR="$WORKDIR/config"
LOG_DIR="$WORKDIR/logs"
BIN_DIR="$WORKDIR/bin"

# 获取脚本绝对路径
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
if [ -z "$SCRIPT_PATH" ]; then
    SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
fi
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

# 系统检测
OS=""
PACKAGE_MANAGER=""
INIT_SYSTEM=""

check_sys() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    fi

    if [ -f /etc/alpine-release ]; then
        OS="alpine"
        PACKAGE_MANAGER="apk"
        INIT_SYSTEM="openrc"
    elif [[ "$OS" == "debian" || "$OS" == "ubuntu" ]]; then
        PACKAGE_MANAGER="apt"
        INIT_SYSTEM="systemd"
    elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
        PACKAGE_MANAGER="yum"
        INIT_SYSTEM="systemd"
    else
        echo -e "${RED}不支持的系统: $OS${PLAIN}"
        exit 1
    fi
}

install_base_deps() {
    echo -e "${BLUE}正在安装基础依赖...${PLAIN}"
    if [[ "$PACKAGE_MANAGER" == "apk" ]]; then
        apk update
        apk add curl wget tar ca-certificates openssl bash
    elif [[ "$PACKAGE_MANAGER" == "apt" ]]; then
        apt-get update
        apt-get install -y curl wget tar
    elif [[ "$PACKAGE_MANAGER" == "yum" ]]; then
        yum install -y curl wget tar
    fi
}

get_public_ip() {
    curl -s4 --max-time 5 https://api.ip.sb/ip -A Mozilla || curl -s4 --max-time 5 https://ipinfo.io/ip -A Mozilla
}

get_public_ipv6() {
    curl -s6 --max-time 5 https://api.ip.sb/ip -A Mozilla || curl -s6 --max-time 5 https://ifconfig.co/ip -A Mozilla
}

# 预获取 IP，避免最后等待
prefetch_ips() {
    echo -e "${BLUE}正在检测服务器 IP (超时 5秒)...${PLAIN}"
    PUBLIC_IPV4=$(get_public_ip)
    PUBLIC_IPV6=$(get_public_ipv6)
    
    if [ -n "$PUBLIC_IPV4" ]; then
        echo -e "${GREEN}检测到 IPv4: $PUBLIC_IPV4${PLAIN}"
    else
        echo -e "${YELLOW}未检测到 IPv4${PLAIN}"
    fi
    
    if [ -n "$PUBLIC_IPV6" ]; then
        echo -e "${GREEN}检测到 IPv6: $PUBLIC_IPV6${PLAIN}"
    else
        echo -e "${YELLOW}未检测到 IPv6${PLAIN}"
    fi
}

generate_secret() {
    head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n'
}

# --- IP 模式选择 ---
select_ip_mode() {
    echo -e "请选择监听模式:" >&2
    echo -e "1. ${GREEN}IPv4 仅${PLAIN} (默认，高稳定性)" >&2
    echo -e "2. ${YELLOW}IPv6 仅${PLAIN}" >&2
    echo -e "3. ${BLUE}双栈模式 (IPv4 + IPv6)${PLAIN}" >&2
    read -p "请选择 [1-3] (默认 1): " mode
    case $mode in
        2) echo "v6" ;;
        3) echo "dual" ;;
        *) echo "v4" ;;
    esac
}

# --- 服务状态检测 ---
get_service_status_str() {
    local SERVICE=$1
    local status=""
    
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if [ -f "/etc/systemd/system/${SERVICE}.service" ]; then
            if systemctl is-active --quiet $SERVICE 2>/dev/null; then
                status="${GREEN}● 运行中${PLAIN}"
            else
                status="${RED}○ 已停止${PLAIN}"
            fi
        else
            status="${YELLOW}○ 未安装${PLAIN}"
        fi
    else
        if [ -f "/etc/init.d/${SERVICE}" ]; then
            if rc-service $SERVICE status 2>/dev/null | grep -q "started"; then
                status="${GREEN}● 运行中${PLAIN}"
            else
                status="${RED}○ 已停止${PLAIN}"
            fi
        else
            status="${YELLOW}○ 未安装${PLAIN}"
        fi
    fi
    
    echo -e "$status"
}

# --- 查看所有服务状态 ---
check_all_status() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════╗${PLAIN}"
    echo -e "${BLUE}║        MTProxy 服务状态详情              ║${PLAIN}"
    echo -e "${BLUE}╠══════════════════════════════════════════╣${PLAIN}"
    
    for SERVICE in mtg mtp-rust; do
        local NAME=""
        case $SERVICE in
            mtg) NAME="Go     版 (mtg)" ;;
            mtp-rust) NAME="Rust   版" ;;
        esac
        
        local STATUS=""
        local PID=""
        local MEMORY=""
        local UPTIME=""
        
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            if [ -f "/etc/systemd/system/${SERVICE}.service" ]; then
                if systemctl is-active --quiet $SERVICE 2>/dev/null; then
                    STATUS="${GREEN}运行中${PLAIN}"
                    PID=$(systemctl show -p MainPID --value $SERVICE 2>/dev/null)
                    if [ -n "$PID" ] && [ "$PID" != "0" ]; then
                        MEMORY=$(ps -o rss= -p $PID 2>/dev/null | awk '{printf "%.1f MB", $1/1024}')
                        UPTIME=$(ps -o etime= -p $PID 2>/dev/null | xargs)
                    fi
                else
                    STATUS="${RED}已停止${PLAIN}"
                fi
            else
                STATUS="${YELLOW}未安装${PLAIN}"
            fi
        else
            if [ -f "/etc/init.d/${SERVICE}" ]; then
                if rc-service $SERVICE status 2>/dev/null | grep -q "started"; then
                    STATUS="${GREEN}运行中${PLAIN}"
                    PID=$(cat /run/${SERVICE}.pid 2>/dev/null)
                    if [ -n "$PID" ]; then
                        MEMORY=$(ps -o rss= -p $PID 2>/dev/null | awk '{printf "%.1f MB", $1/1024}')
                    fi
                else
                    STATUS="${RED}已停止${PLAIN}"
                fi
            else
                STATUS="${YELLOW}未安装${PLAIN}"
            fi
        fi
        
        printf "${BLUE}║${PLAIN} %-12s 状态: %-20s ${BLUE}║${PLAIN}\n" "$NAME" "$(echo -e $STATUS)"
        if [ -n "$PID" ] && [ "$PID" != "0" ]; then
            printf "${BLUE}║${PLAIN}   PID: %-6s 内存: %-8s 运行: %-6s ${BLUE}║${PLAIN}\n" "$PID" "$MEMORY" "$UPTIME"
        fi
    done
    
    echo -e "${BLUE}╚══════════════════════════════════════════╝${PLAIN}"
    echo ""
}

# --- 查看服务日志 ---
view_logs() {
    echo ""
    echo -e "${BLUE}请选择要查看的日志:${PLAIN}"
    echo -e "${GREEN}1.${PLAIN} Go 版日志 (mtg)"
    echo -e "${GREEN}2.${PLAIN} Rust 版日志 (mtp-rust)"
    echo -e "${GREEN}3.${PLAIN} 实时跟踪所有日志"
    echo -e "${GREEN}0.${PLAIN} 返回主菜单"
    read -p "请选择: " log_choice
    
    case $log_choice in
        1)
            echo -e "${BLUE}=== Go 版日志 (最近 50 行) ===${PLAIN}"
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                journalctl -u mtg -n 50 --no-pager
            else
                tail -n 50 /var/log/mtg.log 2>/dev/null || echo "日志文件不存在"
            fi
            ;;
        2)
            echo -e "${BLUE}=== Rust 版日志 (最近 50 行) ===${PLAIN}"
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                journalctl -u mtp-rust -n 50 --no-pager
            else
                tail -n 50 /var/log/mtp-rust.log 2>/dev/null || echo "日志文件不存在"
            fi
            ;;
        3)
            echo -e "${YELLOW}正在实时跟踪日志 (按 Ctrl+C 退出)...${PLAIN}"
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                journalctl -u mtg -u mtp-rust -f
            else
                tail -f /var/log/mtg.log /var/log/mtp-rust.log 2>/dev/null
            fi
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            ;;
    esac
}

# --- Python 版安装逻辑 ---


# --- Go 版安装逻辑 ---
install_mtg() {
    prefetch_ips
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) MTG_ARCH="amd64" ;;
        aarch64) MTG_ARCH="arm64" ;;
        *) echo "不支持的架构: $ARCH"; exit 1 ;;
    esac
    
    mkdir -p "$BIN_DIR"
    TARGET_NAME="mtg-go-${MTG_ARCH}"
    FOUND_PATH=""
    
    if [ -f "./${TARGET_NAME}" ]; then
        FOUND_PATH="./${TARGET_NAME}"
    elif [ -f "${SCRIPT_DIR}/${TARGET_NAME}" ]; then
        FOUND_PATH="${SCRIPT_DIR}/${TARGET_NAME}"
    fi
    
    if [ -n "$FOUND_PATH" ]; then
        echo -e "${GREEN}检测到本地二进制文件: ${FOUND_PATH}${PLAIN}"
        cp "${FOUND_PATH}" "$BIN_DIR/mtg-go"
    else
        echo -e "${BLUE}未找到本地文件，尝试从 GitHub 下载 (${TARGET_NAME})...${PLAIN}"
        DOWNLOAD_URL="https://github.com/0xdabiaoge/MTProxy/releases/download/GO-Python-Rust/${TARGET_NAME}"
        wget -O "$BIN_DIR/mtg-go" "$DOWNLOAD_URL"
        if [ $? -ne 0 ]; then
            echo -e "${RED}下载失败！${PLAIN}"
            exit 1
        fi
    fi
    chmod +x "$BIN_DIR/mtg-go"

    read -p "请输入伪装域名 (默认 www.apple.com): " DOMAIN
    [ -z "$DOMAIN" ] && DOMAIN="www.apple.com"
    
    IP_MODE=$(select_ip_mode)
    
    # 根据 IP 模式输入端口
    if [[ "$IP_MODE" == "dual" ]]; then
        read -p "请输入 IPv4 端口 (默认 443): " PORT
        [ -z "$PORT" ] && PORT=443
        read -p "请输入 IPv6 端口 (默认 $PORT): " PORT_V6
        [ -z "$PORT_V6" ] && PORT_V6="$PORT"
    else
        read -p "请输入端口 (默认 443): " PORT
        [ -z "$PORT" ] && PORT=443
        PORT_V6=""
    fi
    
    SECRET=$(generate_secret)
    echo -e "${GREEN}生成的密钥: $SECRET${PLAIN}"

    create_service_mtg "$PORT" "$SECRET" "$DOMAIN" "$IP_MODE" "$PORT_V6"
    check_service_status mtg
    show_info_mtg "$PORT" "$SECRET" "$DOMAIN" "$IP_MODE" "$PORT_V6"
}

create_service_mtg() {
    PORT=$1
    SECRET=$2
    DOMAIN=$3
    IP_MODE=$4
    
    HEX_DOMAIN=$(echo -n "$DOMAIN" | od -A n -t x1 | tr -d ' \n')
    FULL_SECRET="ee${SECRET}${HEX_DOMAIN}"
    
    NET_ARGS="-i only-ipv4 0.0.0.0:$PORT"
    if [[ "$IP_MODE" == "v6" ]]; then
        NET_ARGS="-i only-ipv6 [::]:$PORT"
    elif [[ "$IP_MODE" == "dual" ]]; then
        NET_ARGS="-i prefer-ipv6 [::]:$PORT"
    fi
    
    CMD_ARGS="simple-run -n 1.1.1.1 -t 30s -a 1mb $NET_ARGS $FULL_SECRET"
    EXEC_CMD="$BIN_DIR/mtg-go $CMD_ARGS"
    
    echo -e "${BLUE}正在创建服务 (Go)...${PLAIN}"
    
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        cat > /etc/systemd/system/mtg.service <<EOF
[Unit]
Description=MTProto Proxy (Go - mtg)
After=network.target

[Service]
Type=simple
ExecStart=$EXEC_CMD
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mtg
        systemctl restart mtg
        
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        cat > /etc/init.d/mtg <<EOF
#!/sbin/openrc-run
name="mtg"
description="MTProto Proxy (Go)"
command="$BIN_DIR/mtg-go"
command_args="$CMD_ARGS"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
rc_ulimit="-n 65535"
pidfile="/run/mtg.pid"
output_log="/var/log/mtg.log"
error_log="/var/log/mtg.log"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/mtg
        rc-update add mtg default
        rc-service mtg restart
    fi
}

# === Rust 版安装逻辑 ===
install_mtp_rust() {
    prefetch_ips
    echo -e "${BLUE}正在准备安装 Rust 版...${PLAIN}"
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) R_ARCH="amd64" ;;
        aarch64) R_ARCH="arm64" ;;
        *) R_ARCH="$ARCH" ;;
    esac
    
    # Rust 版使用通用的 linux 命名（musl 静态链接）
    TARGET_BIN="mtp-rust-linux-${R_ARCH}"
    mkdir -p "$BIN_DIR"
    
    FOUND_PATH=""
    if [ -f "./${TARGET_BIN}" ]; then
        FOUND_PATH="./${TARGET_BIN}"
    elif [ -f "${SCRIPT_DIR}/${TARGET_BIN}" ]; then
        FOUND_PATH="${SCRIPT_DIR}/${TARGET_BIN}"
    fi

    if [ -n "$FOUND_PATH" ]; then
        echo -e "${GREEN}检测到本地二进制文件: ${FOUND_PATH}${PLAIN}"
        cp "${FOUND_PATH}" "$BIN_DIR/mtp-rust"
    else
        echo -e "${BLUE}未找到本地文件，尝试从 GitHub 下载 (${TARGET_BIN})...${PLAIN}"
        DOWNLOAD_URL="https://github.com/0xdabiaoge/MTProxy/releases/download/GO-Python-Rust/${TARGET_BIN}"
        wget -O "$BIN_DIR/mtp-rust" "$DOWNLOAD_URL"
        if [ $? -ne 0 ]; then
            echo -e "${RED}下载失败！${PLAIN}"
            echo -e "${YELLOW}请将以下文件放在脚本同目录:${PLAIN}"
            echo -e "  - mtp-rust-linux-amd64"
            echo -e "  - mtp-rust-linux-arm64"
            return 1
        fi
    fi
    chmod +x "$BIN_DIR/mtp-rust"

    read -p "请输入伪装域名 (默认 www.apple.com): " DOMAIN
    [ -z "$DOMAIN" ] && DOMAIN="www.apple.com"
    
    IP_MODE=$(select_ip_mode)

    read -p "请输入端口 (默认 443): " PORT
    [ -z "$PORT" ] && PORT=443
    
    SECRET=$(generate_secret)
    echo -e "${GREEN}生成的密钥: $SECRET${PLAIN}"
    
    # 构建完整的 ee 密钥
    HEX_DOMAIN=$(echo -n "$DOMAIN" | od -A n -t x1 | tr -d ' \n')
    FULL_SECRET="ee${SECRET}${HEX_DOMAIN}"
    
    # 保存配置到文件
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/rust.conf" <<EOF
PORT=$PORT
SECRET=$FULL_SECRET
DOMAIN=$DOMAIN
IP_MODE=$IP_MODE
EOF

    create_service_rust "$PORT" "$FULL_SECRET" "$IP_MODE"
    check_service_status mtp-rust
    show_info_rust "$PORT" "$SECRET" "$DOMAIN" "$IP_MODE"
}

create_service_rust() {
    PORT=$1
    FULL_SECRET=$2
    IP_MODE=$3
    
    EXEC_CMD="$BIN_DIR/mtp-rust -p $PORT -s $FULL_SECRET"
    
    if [[ "$IP_MODE" == "v6" ]]; then
        EXEC_CMD="$EXEC_CMD --prefer-ipv6"
    fi
    
    echo -e "${BLUE}正在创建服务 (Rust)...${PLAIN}"
    
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        cat > /etc/systemd/system/mtp-rust.service <<EOF
[Unit]
Description=MTProto Proxy (Rust)
After=network.target

[Service]
Type=simple
ExecStart=$EXEC_CMD
Restart=always
RestartSec=3
LimitNOFILE=65535
Environment="RUST_LOG=info"

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mtp-rust
        systemctl restart mtp-rust
        
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        cat > /etc/init.d/mtp-rust <<EOF
#!/sbin/openrc-run
name="mtp-rust"
description="MTProto Proxy (Rust)"
command="$BIN_DIR/mtp-rust"
command_args="-p $PORT -s $FULL_SECRET"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
rc_ulimit="-n 65535"
pidfile="/run/mtp-rust.pid"
output_log="/var/log/mtp-rust.log"
error_log="/var/log/mtp-rust.log"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/mtp-rust
        rc-update add mtp-rust default
        rc-service mtp-rust restart
    fi
}

show_info_rust() {
    IPV4=$PUBLIC_IPV4
    IPV6=$PUBLIC_IPV6
    [ -z "$IPV4" ] && IPV4=$(get_public_ip)
    [ -z "$IPV6" ] && IPV6=$(get_public_ipv6)
    
    IP_MODE=$4
    
    HEX_DOMAIN=$(echo -n "$3" | od -A n -t x1 | tr -d ' \n')
    FULL_SECRET="ee$2$HEX_DOMAIN"
    
    echo -e "=============================="
    echo -e "${GREEN}Rust 版连接信息${PLAIN}"
    echo -e "端口: $1"
    echo -e "Secret: $FULL_SECRET"
    echo -e "Domain: $3"
    echo -e "------------------------------"
    
    if [[ "$IP_MODE" == "v4" || "$IP_MODE" == "dual" ]]; then
        if [ -n "$IPV4" ]; then
            echo -e "${GREEN}IPv4 链接:${PLAIN}"
            echo -e "tg://proxy?server=$IPV4&port=$1&secret=$FULL_SECRET"
        fi
    fi
    
    if [[ "$IP_MODE" == "v6" || "$IP_MODE" == "dual" ]]; then
        if [ -n "$IPV6" ]; then
            echo -e "${GREEN}IPv6 链接:${PLAIN}"
            echo -e "tg://proxy?server=$IPV6&port=$1&secret=$FULL_SECRET"
        fi
    fi
    echo -e "=============================="
}

check_service_status() {
    local service=$1
    sleep 2
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if systemctl is-active --quiet "$service"; then
            echo -e "${GREEN}服务已启动: $service${PLAIN}"
        else
            echo -e "${RED}服务启动失败: $service${PLAIN}"
            journalctl -u "$service" --no-pager -n 20
        fi
    else
        if rc-service "$service" status | grep -q "started"; then
            echo -e "${GREEN}服务已启动: $service${PLAIN}"
        else
            echo -e "${RED}服务启动失败: $service${PLAIN}"
        fi
    fi
}

# --- 修改配置逻辑 ---
modify_mtg() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        CMD_LINE=$(grep "ExecStart" /etc/systemd/system/mtg.service 2>/dev/null)
    else
        CMD_LINE=$(grep "command_args" /etc/init.d/mtg 2>/dev/null)
    fi
    
    if [ -z "$CMD_LINE" ]; then
        echo -e "${YELLOW}未检测到 MTG 服务配置。${PLAIN}"
        return
    fi

    # 简单提取端口
    CUR_PORT=$(echo "$CMD_LINE" | sed -n 's/.*:\([0-9]*\).*/\1/p')
    # 提取完整Secret
    CUR_FULL_SECRET=$(echo "$CMD_LINE" | sed -n 's/.*\(ee[0-9a-fA-F]*\).*/\1/p' | awk '{print $1}')
    
    # 尝试还原域名
    CUR_DOMAIN=""
    if [[ -n "$CUR_FULL_SECRET" ]]; then
        DOMAIN_HEX=${CUR_FULL_SECRET:34}
        if [[ -n "$DOMAIN_HEX" ]]; then
             if command -v xxd >/dev/null 2>&1; then
                 CUR_DOMAIN=$(echo "$DOMAIN_HEX" | xxd -r -p)
             else
                 ESCAPED_HEX=$(echo "$DOMAIN_HEX" | sed 's/../\\x&/g')
                 CUR_DOMAIN=$(printf "$ESCAPED_HEX")
             fi
        fi
    fi
    [ -z "$CUR_DOMAIN" ] && CUR_DOMAIN="(解析失败)"

    echo -e "当前配置 (Go): 端口=[${GREEN}$CUR_PORT${PLAIN}] 域名=[${GREEN}$CUR_DOMAIN${PLAIN}]"
    
    read -p "请输入新端口 (留空保持不变): " NEW_PORT
    [ -z "$NEW_PORT" ] && NEW_PORT="$CUR_PORT"
    
    read -p "请输入新伪装域名 (留空保持不变): " NEW_DOMAIN
    [ -z "$NEW_DOMAIN" ] && NEW_DOMAIN="$CUR_DOMAIN"
    
    if [[ "$NEW_PORT" == "$CUR_PORT" && "$NEW_DOMAIN" == "$CUR_DOMAIN" ]]; then
        echo -e "${YELLOW}配置未变更。${PLAIN}"
        return
    fi
    
    echo -e "${BLUE}正在更新配置...${PLAIN}"
    # 重新生成 Secret
    NEW_SECRET=$(generate_secret)
    echo -e "${GREEN}新生成的密钥: $NEW_SECRET${PLAIN}"
    
    # 保持 IP 模式不变 (简单检测一下当前模式)
    CUR_IP_MODE="v4"
    if echo "$CMD_LINE" | grep -q "only-ipv6"; then CUR_IP_MODE="v6"; fi
    if echo "$CMD_LINE" | grep -q "prefer-ipv6"; then CUR_IP_MODE="dual"; fi
    
    create_service_mtg "$NEW_PORT" "$NEW_SECRET" "$NEW_DOMAIN" "$CUR_IP_MODE"
    check_service_status mtg
    show_info_mtg "$NEW_PORT" "$NEW_SECRET" "$NEW_DOMAIN" "$CUR_IP_MODE"
}



modify_rust() {
    if [ ! -f "$CONFIG_DIR/rust.conf" ]; then
         echo -e "${YELLOW}未检测到 Rust 版配置文件。${PLAIN}"
         return
    fi
    
    source "$CONFIG_DIR/rust.conf"
    CUR_PORT=$PORT
    CUR_DOMAIN=$DOMAIN
    CUR_IP_MODE=$IP_MODE
    
    echo -e "当前配置 (Rust): 端口=[${GREEN}$CUR_PORT${PLAIN}] 域名=[${GREEN}$CUR_DOMAIN${PLAIN}]"
    
    read -p "请输入新端口 (留空保持不变): " NEW_PORT
    [ -z "$NEW_PORT" ] && NEW_PORT="$CUR_PORT"
    
    read -p "请输入新伪装域名 (留空保持不变): " NEW_DOMAIN
    [ -z "$NEW_DOMAIN" ] && NEW_DOMAIN="$CUR_DOMAIN"
    
    if [[ "$NEW_PORT" == "$CUR_PORT" && "$NEW_DOMAIN" == "$CUR_DOMAIN" ]]; then
        echo -e "${YELLOW}配置未变更。${PLAIN}"
        return
    fi
    
    NEW_SECRET=$(generate_secret)
    echo -e "${GREEN}新密钥: $NEW_SECRET${PLAIN}"
    
    HEX_DOMAIN=$(echo -n "$NEW_DOMAIN" | od -A n -t x1 | tr -d ' \n')
    NEW_FULL_SECRET="ee${NEW_SECRET}${HEX_DOMAIN}"
    
    cat > "$CONFIG_DIR/rust.conf" <<EOF
PORT=$NEW_PORT
SECRET=$NEW_FULL_SECRET
DOMAIN=$NEW_DOMAIN
IP_MODE=$CUR_IP_MODE
EOF
    
    create_service_rust "$NEW_PORT" "$NEW_FULL_SECRET" "$CUR_IP_MODE"
    check_service_status mtp-rust
    show_info_rust "$NEW_PORT" "$NEW_SECRET" "$NEW_DOMAIN" "$CUR_IP_MODE"
}

modify_config() {
    echo ""
    echo -e "请选择要修改的服务:"
    echo -e "1. MTProxy (Go 版)"
    echo -e "2. MTProxy (Rust 版)"
    read -p "请选择 [1-2]: " m_choice
    case $m_choice in
        1) modify_mtg ;;
        2) modify_rust ;;
        *) echo -e "${RED}无效选择${PLAIN}" ;;
    esac
    back_to_menu
}

# --- 删除配置逻辑 ---
delete_mtg() {
    echo -e "${RED}正在删除 MTProxy (Go 版)...${PLAIN}"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop mtg 2>/dev/null
        systemctl disable mtg 2>/dev/null
        rm -f /etc/systemd/system/mtg.service
        systemctl daemon-reload
    else
        rc-service mtg stop 2>/dev/null
        rc-update del mtg 2>/dev/null
        rm -f /etc/init.d/mtg
    fi
    rm -f "$BIN_DIR/mtg-go"
    echo -e "${GREEN}Go 版服务已删除。${PLAIN}"
}



delete_rust() {
    echo -e "${RED}正在删除 MTProxy (Rust 版)...${PLAIN}"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop mtp-rust 2>/dev/null
        systemctl disable mtp-rust 2>/dev/null
        rm -f /etc/systemd/system/mtp-rust.service
        systemctl daemon-reload
    else
        rc-service mtp-rust stop 2>/dev/null
        rc-update del mtp-rust 2>/dev/null
        rm -f /etc/init.d/mtp-rust
    fi
    rm -f "$BIN_DIR/mtp-rust"
    rm -f "$CONFIG_DIR/rust.conf"
    echo -e "${GREEN}Rust 版服务已删除。${PLAIN}"
}

delete_config() {
    echo ""
    echo -e "请选择要删除的服务 (仅删除配置和服务，不全盘卸载):"
    echo -e "1. MTProxy (Go 版)"
    echo -e "2. MTProxy (Rust 版)"
    read -p "请选择 [1-2]: " d_choice
    case $d_choice in
        1) delete_mtg ;;
        2) delete_rust ;;
        *) echo -e "${RED}无效选择${PLAIN}" ;;
    esac
    back_to_menu
}

# --- 查看连接信息逻辑 ---
show_detail_info() {
    echo ""
    echo -e "${BLUE}=== Go 版信息 ===${PLAIN}"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        CMD_LINE=$(grep "ExecStart" /etc/systemd/system/mtg.service 2>/dev/null)
    else
        CMD_LINE=$(grep "command_args" /etc/init.d/mtg 2>/dev/null)
    fi
    
    if [ -n "$CMD_LINE" ]; then
        PORT=$(echo "$CMD_LINE" | sed -n 's/.*:\([0-9]*\).*/\1/p')
        FULL_SECRET=$(echo "$CMD_LINE" | sed -n 's/.*\(ee[0-9a-fA-F]*\).*/\1/p' | awk '{print $1}')
        
        # 还原域名
        CUR_DOMAIN="(不可解析)"
        if [[ -n "$FULL_SECRET" ]]; then
            DOMAIN_HEX=${FULL_SECRET:34}
            if [[ -n "$DOMAIN_HEX" ]]; then
                 if command -v xxd >/dev/null 2>&1; then
                     CUR_DOMAIN=$(echo "$DOMAIN_HEX" | xxd -r -p)
                 else
                     ESCAPED_HEX=$(echo "$DOMAIN_HEX" | sed 's/../\\x&/g')
                     CUR_DOMAIN=$(printf "$ESCAPED_HEX")
                 fi
            fi
        fi
        
        # 还原基础 Secret
        BASE_SECRET=${FULL_SECRET:2:32}
        # 还原 IP 模式 (简单推断)
        CUR_IP_MODE="v4"
        if echo "$CMD_LINE" | grep -q "only-ipv6"; then CUR_IP_MODE="v6"; fi
        if echo "$CMD_LINE" | grep -q "prefer-ipv6"; then CUR_IP_MODE="dual"; fi
        
        show_info_mtg "$PORT" "$BASE_SECRET" "$CUR_DOMAIN" "$CUR_IP_MODE"
    else
        echo -e "${YELLOW}未安装或未运行${PLAIN}"
    fi
    

    
    echo -e ""
    echo -e "${BLUE}=== Rust 版信息 ===${PLAIN}"
    if [ -f "$CONFIG_DIR/rust.conf" ]; then
        source "$CONFIG_DIR/rust.conf"
        BASE_SECRET=${SECRET:2:32}
        show_info_rust "$PORT" "$BASE_SECRET" "$DOMAIN" "$IP_MODE"
    else
        echo -e "${YELLOW}未安装配置文件${PLAIN}"
    fi
    
    back_to_menu
}

# --- 信息显示 ---


show_info_mtg() {
    # 使用预获取的 IP
    IPV4=$PUBLIC_IPV4
    IPV6=$PUBLIC_IPV6
    # 如果为空则尝试再次获取
    [ -z "$IPV4" ] && IPV4=$(get_public_ip)
    [ -z "$IPV6" ] && IPV6=$(get_public_ipv6)
    
    IP_MODE=$4
    
    HEX_DOMAIN=$(echo -n "$3" | od -A n -t x1 | tr -d ' \n')
    FULL_SECRET="ee$2$HEX_DOMAIN"
    echo -e "=============================="
    echo -e "${GREEN}Go 版连接信息${PLAIN}"
    echo -e "端口: $1"
    echo -e "Secret: $FULL_SECRET"
    echo -e "Domain: $3"
    echo -e "------------------------------"

    if [[ "$IP_MODE" == "v4" || "$IP_MODE" == "dual" ]]; then
        if [ -n "$IPV4" ]; then
            echo -e "${GREEN}IPv4 链接:${PLAIN}"
            echo -e "tg://proxy?server=$IPV4&port=$1&secret=$FULL_SECRET"
        else
            echo -e "${RED}未检测到 IPv4 地址${PLAIN}"
        fi
    fi
    
    if [[ "$IP_MODE" == "v6" || "$IP_MODE" == "dual" ]]; then
        if [ -n "$IPV6" ]; then
            echo -e "${GREEN}IPv6 链接:${PLAIN}"
            echo -e "tg://proxy?server=$IPV6&port=$1&secret=$FULL_SECRET"
        else
            echo -e "${YELLOW}未检测到 IPv6 地址${PLAIN}"
        fi
    fi
    echo -e "=============================="
}

get_service_status_str() {
    local service=$1
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if [ -f "/etc/systemd/system/${service}.service" ]; then
            if systemctl is-active --quiet "$service"; then
                echo -e "${GREEN}运行中${PLAIN}"
                return
            fi
        fi
    else
        if [ -f "/etc/init.d/${service}" ]; then
            if rc-service "$service" status 2>/dev/null | grep -q "started"; then
                echo -e "${GREEN}运行中${PLAIN}"
                return
            fi
        fi
    fi
    echo -e "${RED}未运行/未安装${PLAIN}"
}

# --- 服务控制 ---
control_service() {
    ACTION=$1
    shift
    TARGETS="mtg mtp-rust"
    # 如果指定了具体服务名，就只操作那一个
    if [[ -n "$1" ]]; then TARGETS="$1"; fi
    
    for SERVICE in $TARGETS; do
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
             if [ -f "/etc/systemd/system/${SERVICE}.service" ]; then
                 systemctl $ACTION $SERVICE
                 echo -e "${BLUE}$SERVICE $ACTION 完成${PLAIN}"
             fi
        else
             if [ -f "/etc/init.d/${SERVICE}" ]; then
                 rc-service $SERVICE $ACTION
                 echo -e "${BLUE}$SERVICE $ACTION 完成${PLAIN}"
             fi
        fi
    done
}

delete_all() {
    echo -e "${RED}正在卸载所有服务...${PLAIN}"
    control_service stop
    
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl disable mtg mtp-rust 2>/dev/null
        rm -f /etc/systemd/system/mtg.service /etc/systemd/system/mtp-rust.service
        systemctl daemon-reload
    else
        rc-update del mtg default 2>/dev/null
        rc-update del mtp-rust default 2>/dev/null
        rm -f /etc/init.d/mtg /etc/init.d/mtp-rust
    fi
    
    rm -rf "$WORKDIR"
    
    echo -e "${RED}清理本地安装包...${PLAIN}"
    rm -f "${SCRIPT_DIR}/mtg-go"*
    rm -f "${SCRIPT_DIR}/mtp-rust"*

    # 删除脚本自身
    rm -f "$0"
    
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

back_to_menu() {
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    menu
}

# --- 菜单 ---
# --- 菜单 ---
menu() {
    check_sys
    clear
    echo -e ""
    echo -e "${BLUE} __  __ _____ ____                      ${PLAIN}"
    echo -e "${BLUE}|  \/  |_   _|  _ \ _ __ _____  ___   _ ${PLAIN}"
    echo -e "${BLUE}| |\/| | | | | |_) | '__/ _ \ \/ / | | |${PLAIN}"
    echo -e "${BLUE}| |  | | | | |  __/| | | (_) >  <| |_| |${PLAIN}"
    echo -e "${BLUE}|_|  |_| |_| |_|   |_|  \___/_/\_\\\\__, |${PLAIN}"
    echo -e "${BLUE}                                  |___/ ${PLAIN}${GREEN}Lite Manager${PLAIN}"
    echo -e ""
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "          ${GREEN}MTProxy 管理脚本 v2.0${PLAIN}"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e ""
    echo -e "  系统: ${GREEN}${OS}${PLAIN}  |  模式: ${GREEN}${INIT_SYSTEM}${PLAIN}"
    echo -e "  Go 版: $(get_service_status_str mtg)  Rust 版: $(get_service_status_str mtp-rust)"
    echo -e ""
    echo -e "  ${YELLOW}【安 装】${PLAIN}"
    echo -e "    ${GREEN}[1]${PLAIN} 安装 Go 版          ${GREEN}[2]${PLAIN} 安装 Rust 版"
    echo -e ""
    echo -e "  ${YELLOW}【管 理】${PLAIN}"
    echo -e "    ${GREEN}[3]${PLAIN} 查看连接信息        ${GREEN}[4]${PLAIN} 修改配置"
    echo -e "    ${GREEN}[5]${PLAIN} 删除配置"
    echo -e ""
    echo -e "  ${YELLOW}【状态与日志】${PLAIN}"
    echo -e "    ${GREEN}[6]${PLAIN} 查看运行状态        ${GREEN}[7]${PLAIN} 查看日志"
    echo -e ""
    echo -e "  ${YELLOW}【服务控制】${PLAIN}"
    echo -e "    ${GREEN}[8]${PLAIN} 启动服务            ${GREEN}[9]${PLAIN} 停止服务"
    echo -e "    ${GREEN}[10]${PLAIN} 重启服务"
    echo -e ""
    echo -e "  ${RED}【危险操作】${PLAIN}"
    echo -e "    ${RED}[11]${PLAIN} 卸载全部并清理"
    echo -e ""
    echo -e "    ${GREEN}[0]${PLAIN} 退出脚本"
    echo -e ""
    read -p "  请输入选项 [0-11]: " choice
    
    case $choice in
        1) install_base_deps; install_mtg; back_to_menu ;;
        2) install_base_deps; install_mtp_rust; back_to_menu ;;
        3) show_detail_info ;;
        4) modify_config ;;
        5) delete_config ;;
        6) check_all_status; back_to_menu ;;
        7) view_logs; back_to_menu ;;
        8) control_service start; back_to_menu ;;
        9) control_service stop; back_to_menu ;;
        10) control_service restart; back_to_menu ;;
        11) delete_all; exit 0 ;;
        0) echo -e "${GREEN}再见!${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}"; sleep 1; menu ;;
    esac
}

menu


