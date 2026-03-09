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
        apk add curl wget tar ca-certificates openssl bash gawk coreutils
    elif [[ "$PACKAGE_MANAGER" == "apt" ]]; then
        apt-get update
        apt-get install -y curl wget tar ca-certificates openssl gawk coreutils
    elif [[ "$PACKAGE_MANAGER" == "yum" ]]; then
        yum install -y curl wget tar ca-certificates openssl gawk coreutils
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
    
    for SERVICE in mtg telemt; do
        local NAME=""
        case $SERVICE in
            mtg) NAME="Go     版 (mtg)" ;;
            telemt) NAME="Telemt 高性能版" ;;
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
    echo -e "${GREEN}2.${PLAIN} Telemt 版日志 (telemt)"
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
            echo -e "${BLUE}=== Telemt 版日志 (最近 50 行) ===${PLAIN}"
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                journalctl -u telemt -n 50 --no-pager
            else
                tail -n 50 /var/log/telemt.log 2>/dev/null || echo "日志文件不存在"
            fi
            ;;
        3)
            echo -e "${YELLOW}正在实时跟踪日志 (按 Ctrl+C 退出)...${PLAIN}"
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                journalctl -u mtg -u telemt -f
            else
                tail -f /var/log/mtg.log /var/log/telemt.log 2>/dev/null
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
        DOWNLOAD_URL="https://github.com/0xdabiaoge/MTProxy/releases/download/Go-Rust/${TARGET_NAME}"
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
    
    # -c 65535 显式指定最大并发连接数，与代码 DefaultConcurrency 一致
    CMD_ARGS="simple-run -n 1.1.1.1 -t 30s -a 1mb -c 65535 $NET_ARGS $FULL_SECRET"
    EXEC_CMD="$BIN_DIR/mtg-go $CMD_ARGS"
    
    # 保存配置到文件，便于后续修改和查看
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/go.conf" <<EOF
PORT=$PORT
SECRET=$FULL_SECRET
DOMAIN=$DOMAIN
IP_MODE=$IP_MODE
EOF
    
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
StandardOutput=journal
StandardError=journal

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


# === Telemt 版安装逻辑 ===
install_telemt() {
    prefetch_ips
    echo -e "${BLUE}正在准备安装 Telemt 高性能版...${PLAIN}"
    
    if [[ "$INIT_SYSTEM" != "systemd" && "$INIT_SYSTEM" != "openrc" ]]; then
        echo -e "${RED}您的系统 ($INIT_SYSTEM) 不受支持！Telemt 仅支持 Systemd 和 OpenRC。${PLAIN}"
        return 1
    fi

    ARCH=$(uname -m)
    case $ARCH in
        x86_64) TELEMT_ARCH="amd64" ;;
        aarch64) TELEMT_ARCH="arm64" ;;
        *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; return 1 ;;
    esac
    
    mkdir -p "$BIN_DIR"
    
    # 优先检测本地同级目录下是否已有编译好的二进制文件
    LOCAL_BIN=""
    TARGET_BIN="telemt-linux-${TELEMT_ARCH}"
    
    if [ -f "./${TARGET_BIN}" ]; then
        LOCAL_BIN="./${TARGET_BIN}"
    elif [ -f "${SCRIPT_DIR}/${TARGET_BIN}" ]; then
        LOCAL_BIN="${SCRIPT_DIR}/${TARGET_BIN}"
    elif [ -f "./telemt" ]; then
        LOCAL_BIN="./telemt"
    elif [ -f "${SCRIPT_DIR}/telemt" ]; then
        LOCAL_BIN="${SCRIPT_DIR}/telemt"
    fi

    if [ -n "$LOCAL_BIN" ]; then
        echo -e "${GREEN}检测到本地同级目录已存在预编译二进制: $(basename "$LOCAL_BIN")${PLAIN}"
        echo -e "${BLUE}跳过在线下载，直接使用本地文件...${PLAIN}"
        cp "$LOCAL_BIN" "$BIN_DIR/telemt"
        chmod +x "$BIN_DIR/telemt"
    else
        # --- 在线下载逻辑 ---
        DOWNLOAD_URL="https://github.com/0xdabiaoge/MTProxy/releases/download/Go-Rust/${TARGET_BIN}"
        
        echo -e "${BLUE}未找到本地文件，尝试从个人 GitHub 仓库下载 (${TARGET_BIN})...${PLAIN}"
        wget -qO "$BIN_DIR/telemt" "$DOWNLOAD_URL"
        
        if [ $? -ne 0 ] || [ ! -f "$BIN_DIR/telemt" ]; then
            echo -e "${RED}下载或解压失败！请检查您的网络连接或 GitHub 访问情况。${PLAIN}"
            return 1
        fi
        chmod +x "$BIN_DIR/telemt"
        echo -e "${GREEN}Telemt 版下载成功。${PLAIN}"
    fi

    read -p "请输入伪装域名 (默认 www.apple.com): " DOMAIN
    [ -z "$DOMAIN" ] && DOMAIN="www.apple.com"
    
    IP_MODE=$(select_ip_mode)
    
    read -p "请输入端口 (默认 443): " PORT
    [ -z "$PORT" ] && PORT=443
    
    read -p "请为初始管理员设置一个用户名 (默认 admin): " TELEMT_USER
    [ -z "$TELEMT_USER" ] && TELEMT_USER="admin"
    
    SECRET=$(generate_secret)
    echo -e "${GREEN}生成的客户端连接密钥: $SECRET${PLAIN}"

    echo ""
    read -p "请输入此用户的月度流量配额 (GB为单位, 直接回车表示不启用限流): " NEW_QUOTA
    NEW_QUOTA=$(echo "$NEW_QUOTA" | tr -d '\r ')
    if [[ -n "$NEW_QUOTA" && ! "$NEW_QUOTA" =~ ^[0-9.]+$ ]]; then
        echo -e "${RED}输入有误，配额必须是数字，将默认关闭该用户限流。${PLAIN}"
        NEW_QUOTA=""
    fi
    
    read -p "请输入此用户的强制到期日期 (格式 2026-10-01 或 2026-10-01 12:00:00, 回车表示永久): " NEW_EXPIRE
    NEW_EXPIRE=$(echo "$NEW_EXPIRE" | tr -d '\r' | xargs)
    
    # 构造附加区块
    QUOTA_BLOCK=""
    if [ -n "$NEW_QUOTA" ]; then
        QUOTA_BYTES=$(awk "BEGIN {printf \"%.0f\", $NEW_QUOTA * 1073741824}")
        QUOTA_BLOCK="[access.user_data_quota]
$TELEMT_USER = $QUOTA_BYTES"
    fi

    EXPIRE_BLOCK=""
    if [ -n "$NEW_EXPIRE" ]; then
        if echo "$NEW_EXPIRE" | grep -q " "; then
            # 包含了具体时间，将空格替换为 T
            ISO_EXPIRE="$(echo "$NEW_EXPIRE" | tr ' ' 'T')+08:00"
        else
            # 仅输入了日期，默认尾缀为其当天的午夜 23:59:59
            ISO_EXPIRE="${NEW_EXPIRE}T23:59:59+08:00"
        fi
        EXPIRE_BLOCK="[access.user_expirations]
$TELEMT_USER = $ISO_EXPIRE"
    fi
    
    # Telemt 专有配置: 总是保存在 /etc/telemt.toml
    mkdir -p "/etc"
    cat > "/etc/telemt.toml" <<EOF
# === General Settings ===
[general]
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

# === Server Binding ===
[server]
port = $PORT

[[server.listeners]]
ip = "0.0.0.0"
$(if [ "$IP_MODE" = "dual" ] || [ "$IP_MODE" = "v6" ]; then echo "
[[server.listeners]]
ip = \"::\"
"; fi)

# === Anti-Censorship & Masking ===
[censorship]
tls_domain = "$DOMAIN"
mask = true
tls_emulation = false

[access.users]
$TELEMT_USER = "$SECRET"

$QUOTA_BLOCK

$EXPIRE_BLOCK
EOF

    echo "{\"$TELEMT_USER\":0}" > /etc/telemt_quota.json

    # 兼容脚本的读取记录
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/telemt.conf" <<EOF
PORT=$PORT
SECRET=$SECRET
DOMAIN=$DOMAIN
IP_MODE=$IP_MODE
MAIN_USER=$TELEMT_USER
EOF

    create_service_telemt "$PORT"
    check_service_status telemt
    
    # 按照 Telemt/MTG 现代客户端推荐的 Base64 Raw URL 编码构造 ee 密钥以突破截断
    RAW_SECRET_BYTES=$(echo -n "$SECRET" | sed 's/../\\x&/g')
    B64_SECRET=$(printf '\xee%b%b' "$RAW_SECRET_BYTES" "$DOMAIN" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '=')
    FULL_EE_SECRET="$B64_SECRET"
    show_info_telemt "$PORT" "$FULL_EE_SECRET" "$DOMAIN" "$IP_MODE"
}

create_service_telemt() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        cat > /etc/systemd/system/telemt.service <<EOF
[Unit]
Description=Telemt MTProxy
After=network.target

[Service]
Type=simple
WorkingDirectory=$BIN_DIR
Environment="RUST_LOG=info"
ExecStart=$BIN_DIR/telemt /etc/telemt.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable telemt
        systemctl restart telemt
        
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        cat > /etc/init.d/telemt <<EOF
#!/sbin/openrc-run
name="telemt"
description="Telemt MTProxy"
command="$BIN_DIR/telemt"
command_args="/etc/telemt.toml"
command_background=true
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
rc_ulimit="-n 65536"
command_env="RUST_LOG=info"
pidfile="/run/telemt.pid"
output_log="/var/log/telemt.log"
error_log="/var/log/telemt.log"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/telemt
        rc-update add telemt default
        rc-service telemt restart
    fi
}

show_info_telemt() {
    IPV4=$PUBLIC_IPV4
    IPV6=$PUBLIC_IPV6
    [ -z "$IPV4" ] && IPV4=$(get_public_ip)
    [ -z "$IPV6" ] && IPV6=$(get_public_ipv6)
    
    IP_MODE=$4
    FULL_SECRET="$2"
    
    echo -e "=============================="
    echo -e "${GREEN}Telemt 版连接信息${PLAIN}"
    echo -e "端口: $1"
    echo -e "Secret: $FULL_SECRET"
    echo -e "Domain: $3"
    echo -e "------------------------------"
    
    if [[ "$IP_MODE" == "v4" || "$IP_MODE" == "dual" ]]; then
        if [ -n "$IPV4" ]; then
            echo -e "${GREEN}IPv4 链接:${PLAIN}"
            echo -e "tg://proxy?server=$IPV4&port=$1&secret=${FULL_SECRET}"
        fi
    fi
    
    if [[ "$IP_MODE" == "v6" || "$IP_MODE" == "dual" ]]; then
        if [ -n "$IPV6" ]; then
            echo -e "${GREEN}IPv6 链接:${PLAIN}"
            echo -e "tg://proxy?server=$IPV6&port=$1&secret=${FULL_SECRET}"
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
    # 优先从配置文件读取，避免复杂的 sed 反解析
    if [ -f "$CONFIG_DIR/go.conf" ]; then
        source "$CONFIG_DIR/go.conf"
        CUR_PORT=$PORT
        CUR_DOMAIN=$DOMAIN
        CUR_IP_MODE=$IP_MODE
    else
        # 兼容旧版：从服务文件中解析
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            CMD_LINE=$(grep "ExecStart" /etc/systemd/system/mtg.service 2>/dev/null)
        else
            CMD_LINE=$(grep "command_args" /etc/init.d/mtg 2>/dev/null)
        fi
        
        if [ -z "$CMD_LINE" ]; then
            echo -e "${YELLOW}未检测到 MTG 服务配置。${PLAIN}"
            return
        fi

        CUR_PORT=$(echo "$CMD_LINE" | sed -n 's/.*:\([0-9]*\).*/\1/p')
        CUR_FULL_SECRET=$(echo "$CMD_LINE" | sed -n 's/.*\(ee[0-9a-fA-F]*\).*/\1/p' | awk '{print $1}')
        
        CUR_DOMAIN=""
        if [[ -n "$CUR_FULL_SECRET" ]]; then
            DOMAIN_HEX=${CUR_FULL_SECRET:34}
            if [[ -n "$DOMAIN_HEX" ]]; then
                 ESCAPED_HEX=$(echo "$DOMAIN_HEX" | sed 's/../\\x&/g')
                 CUR_DOMAIN=$(printf "%b" "$ESCAPED_HEX")
            fi
        fi
        [ -z "$CUR_DOMAIN" ] && CUR_DOMAIN="(解析失败)"
        
        CUR_IP_MODE="v4"
        if echo "$CMD_LINE" | grep -q "only-ipv6"; then CUR_IP_MODE="v6"; fi
        if echo "$CMD_LINE" | grep -q "prefer-ipv6"; then CUR_IP_MODE="dual"; fi
    fi

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
    NEW_SECRET=$(generate_secret)
    echo -e "${GREEN}新生成的密钥: $NEW_SECRET${PLAIN}"
    
    create_service_mtg "$NEW_PORT" "$NEW_SECRET" "$NEW_DOMAIN" "$CUR_IP_MODE"
    check_service_status mtg
    show_info_mtg "$NEW_PORT" "$NEW_SECRET" "$NEW_DOMAIN" "$CUR_IP_MODE"
}




modify_telemt() {
    if [ ! -f "$CONFIG_DIR/telemt.conf" ]; then
         echo -e "${YELLOW}未检测到 Telemt 配置文件。${PLAIN}"
         return
    fi
    
    source "$CONFIG_DIR/telemt.conf"
    CUR_PORT=$PORT
    CUR_DOMAIN=$DOMAIN
    CUR_IP_MODE=$IP_MODE
    CUR_SECRET=$SECRET
    
    echo -e "当前配置 (Telemt): 端口=[${GREEN}$CUR_PORT${PLAIN}] 域名=[${GREEN}$CUR_DOMAIN${PLAIN}]"
    
    read -p "请输入新端口 (留空保持不变): " NEW_PORT
    [ -z "$NEW_PORT" ] && NEW_PORT="$CUR_PORT"
    
    read -p "请输入新伪装域名 (留空保持不变): " NEW_DOMAIN
    [ -z "$NEW_DOMAIN" ] && NEW_DOMAIN="$CUR_DOMAIN"
    
    if [[ "$NEW_PORT" == "$CUR_PORT" && "$NEW_DOMAIN" == "$CUR_DOMAIN" ]]; then
        echo -e "${YELLOW}配置未变更。${PLAIN}"
        return
    fi
    
    # Telemt 不再通过 modify_config 统一修改密钥（由多用户子菜单管理）
    # 提取现有的 users 块，保留多用户数据
    USERS_BLOCK=$(awk '/^\[access\.users\]/{flag=1; next} /^\[/{flag=0} flag {print}' /etc/telemt.toml | grep -v "^$")
    if [ -z "$USERS_BLOCK" ]; then
        USERS_BLOCK="$MAIN_USER = \"$CUR_SECRET\""
    fi
    
    # 修改外部环境文件
    cat > "$CONFIG_DIR/telemt.conf" <<EOF
PORT=$NEW_PORT
SECRET=$CUR_SECRET
DOMAIN=$NEW_DOMAIN
IP_MODE=$CUR_IP_MODE
MAIN_USER=$MAIN_USER
EOF

    # 重新生成 Telemt 的 TOML
    cat > "/etc/telemt.toml" <<EOF
# === General Settings ===
[general]
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

# === Server Binding ===
[server]
port = $NEW_PORT

[[server.listeners]]
ip = "0.0.0.0"
$(if [ "$CUR_IP_MODE" = "dual" ] || [ "$CUR_IP_MODE" = "v6" ]; then echo "
[[server.listeners]]
ip = \"::\"
"; fi)

# === Anti-Censorship & Masking ===
[censorship]
tls_domain = "$NEW_DOMAIN"
mask = true
tls_emulation = false

[access.users]
$USERS_BLOCK
EOF

    create_service_telemt "$NEW_PORT"
    check_service_status telemt
    
    echo -e "${GREEN}端口和域名已成功更新并热生效！${PLAIN}"
    echo -e "${GREEN}如需查看详细的多用户密码与链接，请在主菜单选择 [7] Telemt 多用户管理。${PLAIN}"
}

modify_config() {
    echo ""
    echo -e "请选择要修改的服务:"
    echo -e "1. MTProxy (Go 版)"
    echo -e "2. MTProxy (Telemt 高性能版)"
    read -p "请选择 [1-2]: " m_choice
    case $m_choice in
        1) modify_mtg ;;
        2) modify_telemt ;;
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
    rm -f "$CONFIG_DIR/go.conf"
    echo -e "${GREEN}Go 版服务已删除。${PLAIN}"
}




delete_telemt() {
    echo -e "${RED}正在删除 MTProxy (Telemt 版)...${PLAIN}"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop telemt 2>/dev/null
        systemctl disable telemt 2>/dev/null
        rm -f /etc/systemd/system/telemt.service
        systemctl daemon-reload
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service telemt stop 2>/dev/null
        rc-update del telemt 2>/dev/null
        rm -f /etc/init.d/telemt
    fi
    rm -f "$BIN_DIR/telemt"
    rm -f "$CONFIG_DIR/telemt.conf"
    rm -f "/etc/telemt.toml"
    echo -e "${GREEN}Telemt 版服务已删除。${PLAIN}"
}

delete_config() {
    echo ""
    echo -e "请选择要删除的服务 (仅删除配置和服务，不全盘卸载):"
    echo -e "1. MTProxy (Go 版)"
    echo -e "2. MTProxy (Telemt 高性能版)"
    read -p "请选择 [1-2]: " d_choice
    case $d_choice in
        1) delete_mtg ;;
        2) delete_telemt ;;
        *) echo -e "${RED}无效选择${PLAIN}" ;;
    esac
    back_to_menu
}

# --- 查看连接信息逻辑 ---
show_detail_info() {
    echo ""
    echo -e "${BLUE}=== Go 版信息 ===${PLAIN}"
    if [ -f "$CONFIG_DIR/go.conf" ]; then
        source "$CONFIG_DIR/go.conf"
        BASE_SECRET=${SECRET:2:32}
        show_info_mtg "$PORT" "$BASE_SECRET" "$DOMAIN" "$IP_MODE"
    else
        # 兼容旧版：从服务文件解析
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            CMD_LINE=$(grep "ExecStart" /etc/systemd/system/mtg.service 2>/dev/null)
        else
            CMD_LINE=$(grep "command_args" /etc/init.d/mtg 2>/dev/null)
        fi
        
        if [ -n "$CMD_LINE" ]; then
            PORT=$(echo "$CMD_LINE" | sed -n 's/.*:\([0-9]*\).*/\1/p')
            FULL_SECRET=$(echo "$CMD_LINE" | sed -n 's/.*\(ee[0-9a-fA-F]*\).*/\1/p' | awk '{print $1}')
            
            CUR_DOMAIN="(不可解析)"
            if [[ -n "$FULL_SECRET" ]]; then
                DOMAIN_HEX=${FULL_SECRET:34}
                if [[ -n "$DOMAIN_HEX" ]]; then
                     ESCAPED_HEX=$(echo "$DOMAIN_HEX" | sed 's/../\\x&/g')
                     CUR_DOMAIN=$(printf "%b" "$ESCAPED_HEX")
                fi
            fi
            
            BASE_SECRET=${FULL_SECRET:2:32}
            CUR_IP_MODE="v4"
            if echo "$CMD_LINE" | grep -q "only-ipv6"; then CUR_IP_MODE="v6"; fi
            if echo "$CMD_LINE" | grep -q "prefer-ipv6"; then CUR_IP_MODE="dual"; fi
            
            show_info_mtg "$PORT" "$BASE_SECRET" "$CUR_DOMAIN" "$CUR_IP_MODE"
        else
            echo -e "${YELLOW}未安装或未运行${PLAIN}"
        fi
    fi
    
    echo -e ""
    echo -e "${BLUE}=== Telemt 高性能版信息 ===${PLAIN}"
    if [ -f "$CONFIG_DIR/telemt.conf" ]; then
        source "$CONFIG_DIR/telemt.conf"
        # Telemt secret 是我们存放在 conf 里的本体，展示时组装 B64_URL_SAFE
        RAW_SECRET_BYTES=$(echo -n "$SECRET" | sed 's/../\\x&/g')
        FULL_EE_SECRET=$(printf '\xee%b%b' "$RAW_SECRET_BYTES" "$DOMAIN" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '=')
        show_info_telemt "$PORT" "$FULL_EE_SECRET" "$DOMAIN" "$IP_MODE"
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
    RAW_SECRET_BYTES=$(echo -n "$2" | sed 's/../\\x&/g')
    FULL_SECRET=$(printf '\xee%b%b' "$RAW_SECRET_BYTES" "$3" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '=')
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

# 注意：get_service_status_str 已在第 109 行定义，此处不再重复

control_service() {
    ACTION=$1
    shift
    TARGETS="mtg telemt"
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
        systemctl disable mtg mtp-rust telemt 2>/dev/null
        rm -f /etc/systemd/system/mtg.service /etc/systemd/system/mtp-rust.service /etc/systemd/system/telemt.service
        systemctl daemon-reload
    else
        rc-update del mtg default 2>/dev/null
        rc-update del mtp-rust default 2>/dev/null
        rc-update del telemt default 2>/dev/null
        rm -f /etc/init.d/mtg /etc/init.d/mtp-rust /etc/init.d/telemt
    fi
    
    rm -rf "$WORKDIR"
    rm -f "/etc/telemt.toml"
    
    echo -e "${RED}清理本地安装包...${PLAIN}"
    rm -f "${SCRIPT_DIR}/mtg-go"*
    rm -f "${SCRIPT_DIR}/mtp-rust"*
    rm -f "${SCRIPT_DIR}/telemt"*

    # 删除脚本自身
    rm -f "$0"
    
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

back_to_menu() {
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
    menu
}


# --- Telemt 多用户管理功能 ---
list_telemt_users() {
    if [ ! -f "/etc/telemt.toml" ] || [ ! -f "$CONFIG_DIR/telemt.conf" ]; then
        echo -e "${YELLOW}未检测到 Telemt 配置文件或未安装！${PLAIN}"
        return
    fi
    source "$CONFIG_DIR/telemt.conf"
    
    while true; do
        clear
        IPV4=$PUBLIC_IPV4
        IPV6=$PUBLIC_IPV6
        [ -z "$IPV4" ] && IPV4=$(get_public_ip)
        [ -z "$IPV6" ] && IPV6=$(get_public_ipv6)
        
        HEX_DOMAIN=$(echo -n "$DOMAIN" | od -A n -t x1 | tr -d ' \n')
        
        echo -e "==========================================="
        echo -e "${GREEN}      Telemt 用户列表及专属分享链接       ${PLAIN}"
        echo -e "==========================================="
    
    # 读取所有附加映射 (存入关联数组)
    declare -A user_port_map
    declare -A user_quota_map
    declare -A user_expire_map
    
    local in_ports=0
    local in_quotas=0
    local in_expires=0

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^\[access\.user_ports\] ]]; then
            in_ports=1; in_quotas=0; in_expires=0; continue
        fi
        if [[ "$line" =~ ^\[access\.user_data_quota\] ]]; then
            in_quotas=1; in_ports=0; in_expires=0; continue
        fi
        if [[ "$line" =~ ^\[access\.user_expirations\] ]]; then
            in_expires=1; in_ports=0; in_quotas=0; continue
        fi
        if [[ "$line" =~ ^\[.*\] ]]; then
            in_ports=0; in_quotas=0; in_expires=0; continue
        fi
        
        if [[ -n "$line" && ! "$line" =~ ^# ]]; then
            local pName=$(echo "$line" | cut -d '=' -f 1 | tr -d ' "' | xargs)
            local pVal=$(echo "$line" | cut -d '=' -f 2 | tr -d ' "' | xargs)
            if [ -n "$pName" ] && [ -n "$pVal" ]; then
                if [ $in_ports -eq 1 ]; then user_port_map["$pName"]=$pVal; fi
                if [ $in_quotas -eq 1 ]; then user_quota_map["$pName"]=$pVal; fi
                if [ $in_expires -eq 1 ]; then user_expire_map["$pName"]=$pVal; fi
            fi
        fi
    done < /etc/telemt.toml

    # 遍历所有用户条目输出
    local in_users=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^\[access\.users\] ]]; then
            in_users=1
            continue
        fi
        if [[ $in_users -eq 1 && "$line" =~ ^\[.*\] ]]; then
            in_users=0
            continue
        fi
        if [[ $in_users -eq 1 && -n "$line" && ! "$line" =~ ^# ]]; then
            local uName=$(echo "$line" | cut -d '=' -f 1 | tr -d ' "' | xargs)
            local uSec=$(echo "$line" | cut -d '=' -f 2 | tr -d ' "' | xargs)
            
            if [ -n "$uName" ] && [ -n "$uSec" ]; then
                 local full_secret="ee${uSec}${HEX_DOMAIN}"
                 
                 # 提取专属专口，没有则退化为全局端口
                 local link_port=$PORT
                 local port_lbl="全局共享"
                 if [ -n "${user_port_map[$uName]}" ]; then
                     link_port=${user_port_map[$uName]}
                     port_lbl="专属专线"
                 fi

                 # --- 计算配额用量 ---
                 local quota_str="未限流"
                 local status_str="${GREEN}🟢 正常${PLAIN}"
                 if [ -n "${user_quota_map[$uName]}" ]; then
                     local limit_bytes=${user_quota_map[$uName]}
                     local used_bytes=0
                     if [ -f "/etc/telemt_quota.json" ]; then
                         # 从 JSON 提取单个用户 used
                         used_bytes=$(grep "\"$uName\":" /etc/telemt_quota.json | sed -E "s/.*\"$uName\":([0-9]+).*/\1/")
                         [ -z "$used_bytes" ] && used_bytes=0
                     fi
                     
                     local used_mb=$(awk "BEGIN {printf \"%d\", $used_bytes / 1048576}")
                     local limit_mb=$(awk "BEGIN {printf \"%d\", $limit_bytes / 1048576}")
                     local limit_gb=$(awk "BEGIN {printf \"%.2f\", $limit_bytes / 1073741824}")
                     
                     if [ "$used_bytes" -ge "$limit_bytes" ]; then
                         quota_str="已用: ${RED}${used_mb}MB${PLAIN} / 总限额: ${limit_gb}GB (${RED}已超限${PLAIN})"
                         status_str="${RED}🔴 断流封禁中（流量耗尽或到期）${PLAIN}"
                     else
                         local pct=$(awk "BEGIN {if ($limit_mb > 0) printf \"%.1f\", $used_mb * 100 / $limit_mb; else print \"0.0\"}")
                         quota_str="已用: ${YELLOW}${used_mb}MB${PLAIN} / 总限额: ${limit_gb}GB (使用率: ${pct}%)"
                     fi
                 fi
                 
                 # --- 过期时间展示 ---
                 local expire_str="永久有效"
                 if [ -n "${user_expire_map[$uName]}" ]; then
                     local end_iso=${user_expire_map[$uName]}
                     # 去除 TOML 时间格式的 +08:00 后部，并将 T 替换为空格以兼容 BusyBox date
                     end_iso=$(echo "$end_iso" | sed 's/+.*//' | tr 'T' ' ')
                     # 直接利用 ISO 时间字符串格式的特点进行字典序比对，完美兼容所有 Linux/Mac，无需依赖 date 命令转码
                     local current_iso=$(date +"%Y-%m-%d %H:%M:%S")
                     local is_expired=$(awk -v d1="$current_iso" -v d2="$end_iso" 'BEGIN {print (d1 > d2) ? 1 : 0}')
                     
                     if [ "$is_expired" -eq 1 ]; then
                         expire_str="${RED}已过期 ($end_iso)${PLAIN}"
                         status_str="${RED}🔴 断流封禁中（流量耗尽或到期）${PLAIN}"
                     else
                         expire_str="${end_iso} 到期"
                     fi
                 fi

                 echo -e "👤 用户名: ${YELLOW}$uName${PLAIN}  (密钥: $uSec | 状态: $status_str)"
                 echo -e "   🌐 端口: ${RED}$link_port${PLAIN} [$port_lbl]   📅 到期: $expire_str"
                 echo -e "   📊 $quota_str"
                 # 生成兼容新版客户端的短链接模式 (Base64url encode 'ee + secret + hexDomain')
                 local ESCAPED_SECRET=$(echo -n "$full_secret" | sed 's/../\\x&/g')
                 local B64_SECRET=$(printf "%b" "$ESCAPED_SECRET" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '=')
                 
                 if [[ "$IP_MODE" == "v4" || "$IP_MODE" == "dual" ]] && [ -n "$IPV4" ]; then
                     echo -e "   IPv4: tg://proxy?server=$IPV4&port=$link_port&secret=$B64_SECRET"
                 fi
                 if [[ "$IP_MODE" == "v6" || "$IP_MODE" == "dual" ]] && [ -n "$IPV6" ]; then
                     echo -e "   IPv6: tg://proxy?server=$IPV6&port=$link_port&secret=$B64_SECRET"
                 fi
                 echo -e "-------------------------------------------"
            fi
        fi
    done < /etc/telemt.toml
    
        echo -e ""
        echo -e "  ${GREEN}1.${PLAIN} 刷新本页数据 (更新最新流量和状态)"
        echo -e "  ${GREEN}0.${PLAIN} 返回上一级菜单"
        echo -e "${BLUE}=======================================${PLAIN}"
        read -p "  请选择操作 [0-1]: " list_choice
        case $list_choice in
            1) 
                # 重新循环一次 while
                continue 
                ;;
            0|*) 
                # 退出查看
                break 
                ;;
        esac
    done
}

add_telemt_user() {
    if [ ! -f "/etc/telemt.toml" ]; then
        echo -e "${YELLOW}未检测到 Telemt 配置文件！${PLAIN}"
        return
    fi
    echo ""
    read -p "请输入要添加的用户名 (英文/数字组合): " NEW_USER
    if [ -z "$NEW_USER" ]; then
        echo -e "${RED}用户名不能为空！${PLAIN}"
        return
    fi
    
    # 防止重复
    if grep -q "^[ \"]*$NEW_USER[ \"]*=" /etc/telemt.toml; then
        echo -e "${RED}该用户已存在！${PLAIN}"
        return
    fi
    
    
    read -p "请输入要为其分配的专属独立端口 (直接回车表示不独占，使用全局共享端口): " NEW_DEDICATED_PORT

    if [ -n "$NEW_DEDICATED_PORT" ]; then
        if ! [[ "$NEW_DEDICATED_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_DEDICATED_PORT" -lt 1 ] || [ "$NEW_DEDICATED_PORT" -gt 65535 ]; then
            echo -e "${RED}端口必须是在 1-65535 之间的合法数字！${PLAIN}"
            return
        fi
        
        # 强制检查端口冲突 (包含全局端口冲突)
        if grep -q "port = $NEW_DEDICATED_PORT$" /etc/telemt.toml || grep -E -q "= \"?$NEW_DEDICATED_PORT\"?$" /etc/telemt.toml; then
            echo -e "${RED}严重冲突：你分配的专属端口已被某个用户或主程序监听征用，请换一个！${PLAIN}"
            return
        fi
        echo -e "${GREEN}为 $NEW_USER 成功锁定独立专享端口: $NEW_DEDICATED_PORT${PLAIN}"
    fi

    NEW_SECRET=$(generate_secret)
    echo -e "${GREEN}为 $NEW_USER 成功生成通信密钥: $NEW_SECRET${PLAIN}"
    
    echo ""
    read -p "请输入此用户的月度流量配额 (GB为单位, 直接回车表示不启用限流): " NEW_QUOTA
    NEW_QUOTA=$(echo "$NEW_QUOTA" | tr -d '\r ')
    if [[ -n "$NEW_QUOTA" && ! "$NEW_QUOTA" =~ ^[0-9.]+$ ]]; then
        echo -e "${RED}输入有误，配额必须是数字，将默认关闭该用户限流。${PLAIN}"
        NEW_QUOTA=""
    fi
    
    read -p "请输入此用户的强制到期日期 (格式 2026-10-01 或 2026-10-01 12:00:00, 回车表示永久): " NEW_EXPIRE
    NEW_EXPIRE=$(echo "$NEW_EXPIRE" | tr -d '\r' | xargs)
    
    # 插入到 [access.users] 区块的末尾
    sed -i "/^\[access\.users\]/a $NEW_USER = \"$NEW_SECRET\"" /etc/telemt.toml

    # 如果有分配专属端口，则要写入 [access.user_ports] 区域
    if [ -n "$NEW_DEDICATED_PORT" ]; then
        if ! grep -q "^\[access\.user_ports\]" /etc/telemt.toml; then
            echo "" >> /etc/telemt.toml
            echo "[access.user_ports]" >> /etc/telemt.toml
        fi
        sed -i "/^\[access\.user_ports\]/a $NEW_USER = $NEW_DEDICATED_PORT" /etc/telemt.toml
    fi
    
    # 配额写入 [access.user_data_quota] 区域
    if [ -n "$NEW_QUOTA" ]; then
        if ! grep -q "^\[access\.user_data_quota\]" /etc/telemt.toml; then
            echo "" >> /etc/telemt.toml
            echo "[access.user_data_quota]" >> /etc/telemt.toml
        fi
        # 换算成 Bytes，使用 awk 兼容可能的小数输入
        QUOTA_BYTES=$(awk "BEGIN {printf \"%.0f\", $NEW_QUOTA * 1073741824}")
        sed -i "/^\[access\.user_data_quota\]/a $NEW_USER = $QUOTA_BYTES" /etc/telemt.toml
        
        # 清除它的历史用量
        if [ -f "/etc/telemt_quota.json" ]; then
            sed -i "s/\"$NEW_USER\":[0-9]*/\"$NEW_USER\":0/g" /etc/telemt_quota.json
        fi
    fi
    
    # 过期时间写入 [access.user_expirations] 区域
    if [ -n "$NEW_EXPIRE" ]; then
        if ! grep -q "^\[access\.user_expirations\]" /etc/telemt.toml; then
            echo "" >> /etc/telemt.toml
            echo "[access.user_expirations]" >> /etc/telemt.toml
        fi
        if echo "$NEW_EXPIRE" | grep -q " "; then
            ISO_EXPIRE="$(echo "$NEW_EXPIRE" | tr ' ' 'T')+08:00"
        else
            ISO_EXPIRE="${NEW_EXPIRE}T23:59:59+08:00"
        fi
        sed -i "/^\[access\.user_expirations\]/a $NEW_USER = $ISO_EXPIRE" /etc/telemt.toml
    fi
    
    echo -e "${BLUE}正在重载配置 ...${PLAIN}"
    control_service restart telemt >/dev/null 2>&1
    echo -e "${GREEN}新用户已热生效！${PLAIN}"
}

del_telemt_user() {
    if [ ! -f "/etc/telemt.toml" ]; then
        echo -e "${YELLOW}未检测到 Telemt 配置文件！${PLAIN}"
        return
    fi
    echo ""
    echo -e "==========================================="
    echo -e "${GREEN}      请选择要踢出 (删除) 的用户       ${PLAIN}"
    echo -e "==========================================="
    
    local in_users=0
    local user_count=0
    local user_lines=()
    local user_names=()
    local line_num=0
    
    while IFS= read -r line || [ -n "$line" ]; do
        ((line_num++))
        if [[ "$line" =~ ^\[access\.users\] ]]; then
            in_users=1
            continue
        fi
        if [[ $in_users -eq 1 && "$line" =~ ^\[.*\] ]]; then
            in_users=0
            continue
        fi
        if [[ $in_users -eq 1 && -n "$line" && ! "$line" =~ ^# ]]; then
            local uName=$(echo "$line" | cut -d '=' -f 1 | tr -d ' "' | xargs)
            if [ -n "$uName" ]; then
                ((user_count++))
                user_lines[$user_count]=$line_num
                user_names[$user_count]=$uName
                echo -e "  ${GREEN}[${user_count}]${PLAIN} 用户名: ${YELLOW}$uName${PLAIN}"
            fi
        fi
    done < /etc/telemt.toml
    
    if [ $user_count -eq 0 ]; then
        echo -e "${YELLOW}当前没有任何用户可供删除！${PLAIN}"
        echo -e "==========================================="
        return
    fi
    echo -e "==========================================="
    
    echo ""
    read -p "请输入要删除的用户序号 [1-$user_count] (回车取消): " DEL_INDEX
    if [ -z "$DEL_INDEX" ]; then
        echo -e "${YELLOW}已取消操作。${PLAIN}"
        return
    fi
    
    if ! [[ "$DEL_INDEX" =~ ^[0-9]+$ ]] || [ "$DEL_INDEX" -lt 1 ] || [ "$DEL_INDEX" -gt "$user_count" ]; then
        echo -e "${RED}输入的序号无效！${PLAIN}"
        return
    fi
    
    local target_line=${user_lines[$DEL_INDEX]}
    local target_name=${user_names[$DEL_INDEX]}
    
    # 精确删除目标行号
    sed -i "${target_line}d" /etc/telemt.toml
    
    echo -e "${BLUE}正在重载配置注销该用户 ...${PLAIN}"
    control_service restart telemt >/dev/null 2>&1
    
    echo -e "${GREEN}删除用户 [$target_name] 成功并且已将其强制踢下线！${PLAIN}"
}

reset_telemt_user_quota() {
    if [ ! -f "/etc/telemt.toml" ]; then
        echo -e "${YELLOW}未检测到 Telemt 配置文件！${PLAIN}"
        return
    fi
    echo ""
    echo -e "==========================================="
    echo -e "${GREEN}      请选择要重置配额或续期的用户       ${PLAIN}"
    echo -e "==========================================="
    
    local in_users=0
    local user_count=0
    local user_lines=()
    local user_names=()
    local line_num=0
    
    while IFS= read -r line || [ -n "$line" ]; do
        ((line_num++))
        if [[ "$line" =~ ^\[access\.users\] ]]; then
            in_users=1
            continue
        fi
        if [[ $in_users -eq 1 && "$line" =~ ^\[.*\] ]]; then
            in_users=0
            continue
        fi
        if [[ $in_users -eq 1 && -n "$line" && ! "$line" =~ ^# ]]; then
            local uName=$(echo "$line" | cut -d '=' -f 1 | tr -d ' "' | xargs)
            if [ -n "$uName" ]; then
                ((user_count++))
                user_lines[$user_count]=$line_num
                user_names[$user_count]=$uName
                echo -e "  ${GREEN}[${user_count}]${PLAIN} 用户名: ${YELLOW}$uName${PLAIN}"
            fi
        fi
    done < /etc/telemt.toml
    
    if [ $user_count -eq 0 ]; then
        echo -e "${YELLOW}当前没有任何用户可供操作！${PLAIN}"
        echo -e "==========================================="
        return
    fi
    echo -e "==========================================="
    
    echo ""
    read -p "请输入要操作的用户序号 [1-$user_count] (回车取消): " SEL_INDEX
    if [ -z "$SEL_INDEX" ] || ! [[ "$SEL_INDEX" =~ ^[0-9]+$ ]] || [ "$SEL_INDEX" -lt 1 ] || [ "$SEL_INDEX" -gt "$user_count" ]; then
        echo -e "${YELLOW}已取消操作或输入无效。${PLAIN}"
        return
    fi
    
    local target_name=${user_names[$SEL_INDEX]}
    
    echo -e "您正在为 ${GREEN}$target_name${PLAIN} 配置："
    echo -e "1. ${YELLOW}仅清空当期已用流量账单 (恢复全部配额)${PLAIN}"
    echo -e "2. ${YELLOW}重新设定到期期限并清空账单${PLAIN}"
    echo -e "3. ${YELLOW}重新设定配额上限并清空账单${PLAIN}"
    read -p "选择重置策略 [1-3] (回车默认1): " POL_OPT
    [ -z "$POL_OPT" ] && POL_OPT=1
    
    if [ "$POL_OPT" -eq 1 ]; then
        if [ -f "/etc/telemt_quota.json" ]; then
            sed -i "s/\"$target_name\":[0-9]*/\"$target_name\":0/g" /etc/telemt_quota.json
            echo -e "${GREEN}已清空用户 $target_name 的配额用量账单。${PLAIN}"
        fi
    elif [ "$POL_OPT" -eq 2 ]; then
        read -p "请输入新的强制到期日期 (格式 2026-10-01 或 2026-10-01 12:00:00, 回车表示取消限期): " NEW_EXPIRE
        NEW_EXPIRE=$(echo "$NEW_EXPIRE" | tr -d '\r' | xargs)
        if [ -n "$NEW_EXPIRE" ]; then
            if echo "$NEW_EXPIRE" | grep -q " "; then
                ISO_EXPIRE="$(echo "$NEW_EXPIRE" | tr ' ' 'T')+08:00"
            else
                ISO_EXPIRE="${NEW_EXPIRE}T23:59:59+08:00"
            fi
            # 删除旧属性
            sed -i "/^\[access\.user_expirations\]/,/^\[/{/^$target_name *=/d}" /etc/telemt.toml
            if ! grep -q "^\[access\.user_expirations\]" /etc/telemt.toml; then
                echo "" >> /etc/telemt.toml
                echo "[access.user_expirations]" >> /etc/telemt.toml
            fi
            sed -i "/^\[access\.user_expirations\]/a $target_name = $ISO_EXPIRE" /etc/telemt.toml
            
            if [ -f "/etc/telemt_quota.json" ]; then
                sed -i "s/\"$target_name\":[0-9]*/\"$target_name\":0/g" /etc/telemt_quota.json
            fi
            echo -e "${GREEN}已为 $target_name 充值并延期至 $NEW_EXPIRE。${PLAIN}"
        fi
    elif [ "$POL_OPT" -eq 3 ]; then
        read -p "请输入此用户的新的总流量配额上限 (GB为单位): " NEW_QUOTA
        NEW_QUOTA=$(echo "$NEW_QUOTA" | tr -d '\r ')
        if [[ -n "$NEW_QUOTA" && "$NEW_QUOTA" =~ ^[0-9.]+$ ]]; then
            QUOTA_BYTES=$(awk "BEGIN {printf \"%.0f\", $NEW_QUOTA * 1073741824}")
            # 删除旧属性
            sed -i "/^\[access\.user_data_quota\]/,/^\[/{/^$target_name *=/d}" /etc/telemt.toml
            if ! grep -q "^\[access\.user_data_quota\]" /etc/telemt.toml; then
                echo "" >> /etc/telemt.toml
                echo "[access.user_data_quota]" >> /etc/telemt.toml
            fi
            sed -i "/^\[access\.user_data_quota\]/a $target_name = $QUOTA_BYTES" /etc/telemt.toml
            
            if [ -f "/etc/telemt_quota.json" ]; then
                sed -i "s/\"$target_name\":[0-9]*/\"$target_name\":0/g" /etc/telemt_quota.json
            fi
            echo -e "${GREEN}已拉高 $target_name 的配额为 $NEW_QUOTA GB 并恢复可用状态。${PLAIN}"
        fi
    fi
    
    echo -e "${BLUE}正在重载配置注释放最新数据 ...${PLAIN}"
    control_service restart telemt >/dev/null 2>&1
    echo -e "${GREEN}操作成功！${PLAIN}"
}

manage_telemt_users() {
    clear
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${GREEN}      Telemt 高级多用户管理菜单     ${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} 查看所有用户及专属分享链接"
    echo -e "  ${GREEN}2.${PLAIN} 添加新用户"
    echo -e "  ${GREEN}3.${PLAIN} 踢出(删除)指定用户"
    echo -e "  ${GREEN}4.${PLAIN} 充值 / 重置配额与到期日"
    echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
    echo -e "${BLUE}======================================${PLAIN}"
    read -p "  请选择操作 [0-4]: " tm_choice
    case $tm_choice in
        1) list_telemt_users ;;
        2) add_telemt_user ;;
        3) del_telemt_user ;;
        4) reset_telemt_user_quota ;;
        0) return ;;
        *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
    esac
    
    echo ""
    read -n 1 -s -r -p "按任意键继续..."
    manage_telemt_users
}

# --- 菜单 ---
menu() {
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
    echo -e "  Go 版: $(get_service_status_str mtg)  Telemt 版: $(get_service_status_str telemt)"
    echo -e ""
    echo -e "  ${YELLOW}【安 装】${PLAIN}"
    echo -e "    ${GREEN}[1]${PLAIN} 安装 Go 版          ${GREEN}[2]${PLAIN} 安装 Telemt (高性能进阶版)"
    echo -e ""
    echo -e "  ${YELLOW}【管 理】${PLAIN}"
    echo -e "    ${GREEN}[3]${PLAIN} 查看连接信息        ${GREEN}[4]${PLAIN} 修改配置"
    echo -e "    ${GREEN}[5]${PLAIN} 删除配置            ${GREEN}[6]${PLAIN} Telemt 多用户管理"
    echo -e ""
    echo -e "  ${YELLOW}【状态与日志】${PLAIN}"
    echo -e "    ${GREEN}[7]${PLAIN} 查看运行状态        ${GREEN}[8]${PLAIN} 查看日志"
    echo -e ""
    echo -e "  ${YELLOW}【服务控制】${PLAIN}"
    echo -e "    ${GREEN}[9]${PLAIN} 启动服务           ${GREEN}[10]${PLAIN} 停止服务"
    echo -e "    ${GREEN}[11]${PLAIN} 重启服务"
    echo -e ""
    echo -e "  ${RED}【危险操作】${PLAIN}"
    echo -e "    ${RED}[12]${PLAIN} 卸载全部并清理"
    echo -e ""
    echo -e "    ${GREEN}[0]${PLAIN} 退出脚本"
    echo -e ""
    read -p "  请输入选项 [0-12]: " choice
    
    case $choice in
        1) install_base_deps; install_mtg; back_to_menu ;;
        2) install_base_deps; install_telemt; back_to_menu ;;
        3) show_detail_info ;;
        4) modify_config ;;
        5) delete_config ;;
        6) manage_telemt_users; back_to_menu ;;
        7) check_all_status; back_to_menu ;;
        8) view_logs; back_to_menu ;;
        9) control_service start; back_to_menu ;;
        10) control_service stop; back_to_menu ;;
        11) control_service restart; back_to_menu ;;
        12) delete_all; exit 0 ;;
        0) echo -e "${GREEN}再见!${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}无效选项${PLAIN}"; sleep 1; menu ;;
    esac
}

check_sys
menu


