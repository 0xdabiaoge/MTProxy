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

# --- Python 版安装逻辑 ---
install_mtp_python() {
    prefetch_ips
    echo -e "${BLUE}正在准备安装 Python 版...${PLAIN}"
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) P_ARCH="amd64" ;;
        aarch64) P_ARCH="arm64" ;;
        armv7l) P_ARCH="armv6l" ;;
        *) P_ARCH="$ARCH" ;;
    esac
    
    TARGET_OS="debian"
    [[ "$OS" == "alpine" ]] && TARGET_OS="alpine"
    
    TARGET_BIN="mtp-python-${TARGET_OS}-${P_ARCH}"
    mkdir -p "$BIN_DIR"
    
    FOUND_PATH=""
    if [ -f "./${TARGET_BIN}" ]; then
        FOUND_PATH="./${TARGET_BIN}"
    elif [ -f "${SCRIPT_DIR}/${TARGET_BIN}" ]; then
        FOUND_PATH="${SCRIPT_DIR}/${TARGET_BIN}"
    fi

    if [ -n "$FOUND_PATH" ]; then
        echo -e "${GREEN}检测到本地二进制文件: ${FOUND_PATH}${PLAIN}"
        cp "${FOUND_PATH}" "$BIN_DIR/mtp-python"
    else
        echo -e "${BLUE}未找到本地文件，尝试从 GitHub 下载 (${TARGET_BIN})...${PLAIN}"
        DOWNLOAD_URL="https://github.com/0xdabiaoge/MTProxy/releases/download/mtg-go.mtp-python/${TARGET_BIN}"
        wget -O "$BIN_DIR/mtp-python" "$DOWNLOAD_URL"
        if [ $? -ne 0 ]; then
            echo -e "${RED}下载失败！${PLAIN}"
            echo -e "${YELLOW}请确保 GitHub Release 中存在文件: ${TARGET_BIN}${PLAIN}"
            exit 1
        fi
        echo -e "${GREEN}下载并安装成功。${PLAIN}"
    fi
    chmod +x "$BIN_DIR/mtp-python"

    read -p "请输入伪装域名 (默认 www.apple.com): " DOMAIN
    [ -z "$DOMAIN" ] && DOMAIN="www.apple.com"
    
    read -p "请输入推广 TAG (留空则不设置): " ADTAG
    
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
    
    mkdir -p "$CONFIG_DIR"
    IPV4_CFG="\"0.0.0.0\""
    IPV6_CFG="None"
    if [[ "$IP_MODE" == "v6" ]]; then
        IPV4_CFG="None"
        IPV6_CFG="\"::\""
    elif [[ "$IP_MODE" == "dual" ]]; then
        IPV4_CFG="\"0.0.0.0\""
        IPV6_CFG="\"::\""
    fi

    cat > "$CONFIG_DIR/config.py" <<EOF
PORT = $PORT
USERS = {
    "tg": "$SECRET"
}
MODES = {
    "classic": False,
    "secure": False,
    "tls": True
}
TLS_DOMAIN = "$DOMAIN"
LISTEN_ADDR_IPV4 = $IPV4_CFG
LISTEN_ADDR_IPV4 = $IPV4_CFG
LISTEN_ADDR_IPV6 = $IPV6_CFG
EOF

    if [ -n "$PORT_V6" ]; then
        echo "PORT_IPV6 = $PORT_V6" >> "$CONFIG_DIR/config.py"
    fi

    if [ -n "$ADTAG" ]; then
        echo "AD_TAG = \"$ADTAG\"" >> "$CONFIG_DIR/config.py"
    fi

    create_service_python 1
    check_service_status mtp-python
    show_info_python "$PORT" "$SECRET" "$DOMAIN" "$IP_MODE" "$PORT_V6"
}

create_service_python() {
    USE_BINARY=$1
    echo -e "${BLUE}正在创建服务 (Python)...${PLAIN}"
    EXEC_CMD="$BIN_DIR/mtp-python $CONFIG_DIR/config.py"
    SERVICE_WORKDIR="$WORKDIR"
    
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        cat > /etc/systemd/system/mtp-python.service <<EOF
[Unit]
Description=MTProto Proxy (Python)
After=network.target

[Service]
Type=simple
WorkingDirectory=$SERVICE_WORKDIR
ExecStart=$EXEC_CMD
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable mtp-python
        systemctl restart mtp-python
        
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        cat > /etc/init.d/mtp-python <<EOF
#!/sbin/openrc-run
name="mtp-python"
description="MTProto Proxy (Python)"
directory="$SERVICE_WORKDIR"
command="${EXEC_CMD%% *}" 
command_args="${EXEC_CMD#* }"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
rc_ulimit="-n 65535"
pidfile="/run/mtp-python.pid"
output_log="/var/log/mtp-python.log"
error_log="/var/log/mtp-python.log"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/mtp-python
        rc-update add mtp-python default
        rc-service mtp-python restart
    fi
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
        DOWNLOAD_URL="https://github.com/0xdabiaoge/MTProxy/releases/download/mtg-go.mtp-python/${TARGET_NAME}"
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

modify_python() {
    if [ ! -f "$CONFIG_DIR/config.py" ]; then
         echo -e "${YELLOW}未检测到 Python 版配置文件。${PLAIN}"
         return
    fi
    
    CUR_PORT=$(grep "PORT =" "$CONFIG_DIR/config.py" | awk '{print $3}' | tr -d ' ')
    CUR_DOMAIN=$(grep "TLS_DOMAIN =" "$CONFIG_DIR/config.py" | awk -F= '{print $2}' | tr -d ' "')
    
    echo -e "当前配置 (Python): 端口=[${GREEN}$CUR_PORT${PLAIN}] 域名=[${GREEN}$CUR_DOMAIN${PLAIN}]"
    
    read -p "请输入新端口 (留空保持不变): " NEW_PORT
    [ -z "$NEW_PORT" ] && NEW_PORT="$CUR_PORT"
    
    read -p "请输入新伪装域名 (留空保持不变): " NEW_DOMAIN
    [ -z "$NEW_DOMAIN" ] && NEW_DOMAIN="$CUR_DOMAIN"
    
    if [[ "$NEW_PORT" == "$CUR_PORT" && "$NEW_DOMAIN" == "$CUR_DOMAIN" ]]; then
        echo -e "${YELLOW}配置未变更。${PLAIN}"
        return
    fi
    
    echo -e "${BLUE}正在更新配置文件...${PLAIN}"
    sed -i "s/PORT = .*/PORT = $NEW_PORT/" "$CONFIG_DIR/config.py"
    sed -i "s/TLS_DOMAIN = .*/TLS_DOMAIN = \"$NEW_DOMAIN\"/" "$CONFIG_DIR/config.py"
    
    control_service restart mtp-python
    
    # 重新提取 Secret
    CUR_SECRET=$(grep "\"tg\":" "$CONFIG_DIR/config.py" | head -n 1 | awk -F: '{print $2}' | tr -d ' "')
    
    # 获取当前 Python 模式
    CUR_IP_MODE="v4"
    if grep -q "LISTEN_ADDR_IPV6 = \"::\"" "$CONFIG_DIR/config.py"; then
            if grep -q "LISTEN_ADDR_IPV4 = \"0.0.0.0\"" "$CONFIG_DIR/config.py"; then
                CUR_IP_MODE="dual"
            else
                CUR_IP_MODE="v6"
            fi
    fi
    
    # 获取 V6 端口 (如果是双栈且被单独定义)
    CUR_PORT_V6=$(grep "PORT_IPV6 =" "$CONFIG_DIR/config.py" | awk '{print $3}' | tr -d ' ')
    if [ -z "$CUR_PORT_V6" ]; then CUR_PORT_V6="$NEW_PORT"; fi
    
    show_info_python "$NEW_PORT" "$CUR_SECRET" "$NEW_DOMAIN" "$CUR_IP_MODE" "$CUR_PORT_V6"
}

modify_config() {
    echo ""
    echo -e "请选择要修改的服务:"
    echo -e "1. MTProxy (Go 版)"
    echo -e "2. MTProxy (Python 版)"
    read -p "请选择 [1-2]: " m_choice
    case $m_choice in
        1) modify_mtg ;;
        2) modify_python ;;
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

delete_python() {
    echo -e "${RED}正在删除 MTProxy (Python 版)...${PLAIN}"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop mtp-python 2>/dev/null
        systemctl disable mtp-python 2>/dev/null
        rm -f /etc/systemd/system/mtp-python.service
        systemctl daemon-reload
    else
        rc-service mtp-python stop 2>/dev/null
        rc-update del mtp-python 2>/dev/null
        rm -f /etc/init.d/mtp-python
    fi
    rm -f "$BIN_DIR/mtp-python"
    rm -f "$CONFIG_DIR/config.py"
    echo -e "${GREEN}Python 版服务已删除。${PLAIN}"
}

delete_config() {
    echo ""
    echo -e "请选择要删除的服务 (仅删除配置和服务，不全盘卸载):"
    echo -e "1. MTProxy (Go 版)"
    echo -e "2. MTProxy (Python 版)"
    read -p "请选择 [1-2]: " d_choice
    case $d_choice in
        1) delete_mtg ;;
        2) delete_python ;;
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
    echo -e "${BLUE}=== Python 版信息 ===${PLAIN}"
    if [ -f "$CONFIG_DIR/config.py" ]; then
        PORT=$(grep "PORT =" "$CONFIG_DIR/config.py" | head -n 1 | awk '{print $3}' | tr -d ' ')
        SECRET=$(grep "\"tg\":" "$CONFIG_DIR/config.py" | head -n 1 | awk -F: '{print $2}' | tr -d ' "')
        DOMAIN=$(grep "TLS_DOMAIN =" "$CONFIG_DIR/config.py" | awk -F= '{print $2}' | tr -d ' "')
        
        # 获取 IP 模式
        PY_IP_MODE="v4"
        if grep -q "LISTEN_ADDR_IPV6 = \"::\"" "$CONFIG_DIR/config.py"; then
            if grep -q "LISTEN_ADDR_IPV4 = \"0.0.0.0\"" "$CONFIG_DIR/config.py"; then
                PY_IP_MODE="dual"
            else
                PY_IP_MODE="v6"
            fi
        fi
        
        # 获取 V6 端口
        PORT_V6=$(grep "PORT_IPV6 =" "$CONFIG_DIR/config.py" | awk '{print $3}' | tr -d ' ')
        [ -z "$PORT_V6" ] && PORT_V6="$PORT"
        
        show_info_python "$PORT" "$SECRET" "$DOMAIN" "$PY_IP_MODE" "$PORT_V6"
    else
        echo -e "${YELLOW}未安装配置文件${PLAIN}"
    fi
    
    back_to_menu
}

# --- 信息显示 ---
show_info_python() {
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
    echo -e "${GREEN}Python 版连接信息${PLAIN}"
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
        # 如果定义了 PORT_V6 (第5个参数)，则使用它，否则默认用 端口1
        PORT_V6=$5
        [ -z "$PORT_V6" ] && PORT_V6="$1"
        
        if [ -n "$IPV6" ]; then
            echo -e "${GREEN}IPv6 链接:${PLAIN}"
            echo -e "tg://proxy?server=$IPV6&port=$PORT_V6&secret=$FULL_SECRET"
        else
            echo -e "${YELLOW}未检测到 IPv6 地址${PLAIN}"
        fi
    fi
    echo -e "=============================="
}

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
    TARGETS="mtg mtp-python"
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
        systemctl disable mtg mtp-python 2>/dev/null
        rm -f /etc/systemd/system/mtg.service /etc/systemd/system/mtp-python.service
        systemctl daemon-reload
    else
        rc-update del mtg default 2>/dev/null
        rc-update del mtp-python default 2>/dev/null
        rm -f /etc/init.d/mtg /etc/init.d/mtp-python
    fi
    
    rm -rf "$WORKDIR"
    
    echo -e "${RED}清理本地安装包...${PLAIN}"
    rm -f "${SCRIPT_DIR}/mtp-python"* 
    rm -f "${SCRIPT_DIR}/mtg-go"*

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
menu() {
    check_sys
    clear
    echo -e "=================================="
    echo -e "     MTProxy 部署管理脚本"
    echo -e "=================================="
    echo -e "Go     版: $(get_service_status_str mtg)"
    echo -e "Python 版: $(get_service_status_str mtp-python)"
    echo -e "=================================="
    echo -e "${GREEN}1.${PLAIN} 安装/重装 Go 版"
    echo -e "${GREEN}2.${PLAIN} 安装/重装 Python 版"
    echo -e "----------------------------------"
    echo -e "${GREEN}3.${PLAIN} 查看详细连接信息"
    echo -e "${GREEN}4.${PLAIN} 修改服务配置 (端口/域名)"
    echo -e "${GREEN}5.${PLAIN} 删除服务配置 (选择删除)"
    echo -e "----------------------------------"
    echo -e "${GREEN}6.${PLAIN} 启动服务"
    echo -e "${GREEN}7.${PLAIN} 停止服务"
    echo -e "${GREEN}8.${PLAIN} 重启服务"
    echo -e "----------------------------------"
    echo -e "${GREEN}9.${PLAIN} 卸载全部并清理"
    echo -e "${GREEN}0.${PLAIN} 退出"
    echo -e "=================================="
    read -p "请选择: " choice
    
    case $choice in
        1) install_base_deps; install_mtg; back_to_menu ;;
        2) install_base_deps; install_mtp_python; back_to_menu ;;
        3) show_detail_info ;;
        4) modify_config ;;
        5) delete_config ;;
        6) control_service start; back_to_menu ;;
        7) control_service stop; back_to_menu ;;
        8) control_service restart; back_to_menu ;;
        9) delete_all; exit 0 ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效此选项${PLAIN}"; menu ;;
    esac
}

menu
