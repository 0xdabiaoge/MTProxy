#!/bin/bash

# 全局配置
WORKDIR="/opt/mtproxy"
CONFIG_DIR="$WORKDIR/config"
LOG_DIR="$WORKDIR/logs"
BIN_DIR="$WORKDIR/bin"

# 获取脚本绝对路径 (兼容 Alpine/Debian)
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null)
if [ -z "$SCRIPT_PATH" ]; then
    # Fallback if readlink fails
    SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
fi

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
    curl -s https://api.ip.sb/ip -A Mozilla --ipv4 || curl -s https://ipinfo.io/ip -A Mozilla
}

generate_secret() {
    head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n'
}

# --- Python 版安装逻辑 ---
install_mtp_python() {
    echo -e "${BLUE}正在从 GitHub 下载 Python 版二进制文件...${PLAIN}"
    
    # 检测系统类型以选择正确的二进制
    TARGET_BIN="mtp-python-debian"
    if [[ "$OS" == "alpine" ]]; then
        TARGET_BIN="mtp-python-alpine"
    fi
    
    mkdir -p "$BIN_DIR"
    
    # 优先检测本地是否有预编译文件 (方便离线/自定义部署)
    LOCAL_BIN_NAME="${TARGET_BIN}"
    if [ -f "./${LOCAL_BIN_NAME}" ]; then
        echo -e "${GREEN}检测到本地二进制文件: ./${LOCAL_BIN_NAME}，跳过下载...${PLAIN}"
        cp "./${LOCAL_BIN_NAME}" "$BIN_DIR/mtp-python"
    elif [ -f "./mtp-python" ]; then
         # 兼容用户直接命名为 mtp-python 的情况
        echo -e "${GREEN}检测到本地二进制文件: ./mtp-python，跳过下载...${PLAIN}"
        cp "./mtp-python" "$BIN_DIR/mtp-python"
    else
        echo -e "${BLUE}正在从 GitHub 下载 Python 版二进制文件...${PLAIN}"
        DOWNLOAD_URL="https://github.com/0xdabiaoge/MTProxy/releases/download/mtg-python/${TARGET_BIN}"
        wget -O "$BIN_DIR/mtp-python" "$DOWNLOAD_URL"
        
        if [ $? -ne 0 ]; then
            echo -e "${RED}下载失败！请检查网络连接或 GitHub地址是否正确。${PLAIN}"
            exit 1
        fi
        echo -e "${GREEN}下载成功: $TARGET_BIN${PLAIN}"
    fi

    chmod +x "$BIN_DIR/mtp-python"

    # 配置向导
    read -p "请输入端口 (默认 443): " PORT
    [ -z "$PORT" ] && PORT=443
    
    read -p "请输入伪装域名 (默认 azure.microsoft.com): " DOMAIN
    [ -z "$DOMAIN" ] && DOMAIN="azure.microsoft.com"
    
    read -p "请输入推广 TAG (留空则不设置): " ADTAG
    
    SECRET=$(generate_secret)
    echo -e "${GREEN}生成的密钥: $SECRET${PLAIN}"
    
    # 生成配置文件
    mkdir -p "$CONFIG_DIR"
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
EOF

    if [ -n "$ADTAG" ]; then
        echo "AD_TAG = \"$ADTAG\"" >> "$CONFIG_DIR/config.py"
    fi

    # 创建服务 (传入模式参数)
    # 创建服务 (强制使用二进制模式)
    create_service_python 1
    
    # 检查服务状态
    sleep 2
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if systemctl is-active --quiet mtp-python; then
            echo -e "${GREEN}安装完成! 服务已启动。${PLAIN}"
            show_info_python "$PORT" "$SECRET" "$DOMAIN"
        else
            echo -e "${RED}服务启动失败！日志如下：${PLAIN}"
            journalctl -u mtp-python --no-pager -n 20
        fi
    else
        if rc-service mtp-python status | grep -q "started"; then
            echo -e "${GREEN}安装完成! 服务已启动。${PLAIN}"
            show_info_python "$PORT" "$SECRET" "$DOMAIN"
        else
            echo -e "${RED}服务启动失败！${PLAIN}"
            # Alpine 日志位置
            if [ -f "/var/log/mtp-python.log" ]; then
                 tail -n 20 /var/log/mtp-python.log
            else
                 echo -e "${YELLOW}无日志文件生成。${PLAIN}"
            fi
        fi
    fi
}


create_service_python() {
    USE_BINARY=$1
    echo -e "${BLUE}正在创建服务...${PLAIN}"
    
    if [ "$USE_BINARY" == "1" ]; then
        EXEC_CMD="$BIN_DIR/mtp-python $CONFIG_DIR/config.py"
        # 二进制模式下，不需要进入源码目录 (该目录可能不存在)
        SERVICE_WORKDIR="$WORKDIR"
    else
        EXEC_CMD="/usr/bin/python3 mtprotoproxy.py $CONFIG_DIR/config.py"
        SERVICE_WORKDIR="$WORKDIR/mtprotoproxy"
    fi
    
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

show_info_python() {
    IP=$(get_public_ip)
    HEX_DOMAIN=$(echo -n "$3" | od -A n -t x1 | tr -d ' \n')
    FULL_SECRET="ee$2$HEX_DOMAIN"
    
    echo -e "=============================="
    echo -e "      算 法 信 息 (Python)"
    echo -e "=============================="
    echo -e "IP: $IP"
    echo -e "端口: $1"
    echo -e "Secret: $FULL_SECRET"
    echo -e "Domain: $3"
    echo -e "=============================="
    echo -e "tg://proxy?server=$IP&port=$1&secret=$FULL_SECRET"
}


# --- Go 版 (mtg) 安装逻辑 ---
install_mtg() {
    # 架构检测
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) MTG_ARCH="amd64" ;;
        aarch64) MTG_ARCH="arm64" ;;
        *) echo "不支持的架构: $ARCH"; exit 1 ;;
    esac
    
    # 从用户 GitHub 下载 mtg 二进制文件
    echo -e "${BLUE}正在从 GitHub 下载 mtg ($MTG_ARCH)...${PLAIN}"
    mkdir -p "$BIN_DIR"
    
    FILENAME="mtg-2.1.7-linux-${MTG_ARCH}"
    DOWNLOAD_URL="https://github.com/0xdabiaoge/MTProxy/releases/download/mtg-python/${FILENAME}.tar.gz"
    
    wget -O "mtg.tar.gz" "$DOWNLOAD_URL"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败！请检查网络连接或文件名。${PLAIN}"
        echo -e "${RED}URL: $DOWNLOAD_URL${PLAIN}"
        exit 1
    fi
    
    # 解压 tar.gz
    tar -xzf mtg.tar.gz
    
    # 移动二进制文件 (解压出来的目录名通常是 filename)
    if [ -d "${FILENAME}" ]; then
         mv "${FILENAME}/mtg" "$BIN_DIR/mtg"
    else
         # 尝试通配符匹配，以防万一
         mv mtg-*-linux-*/mtg "$BIN_DIR/mtg"
    fi
    
    chmod +x "$BIN_DIR/mtg"
    rm -rf mtg.tar.gz "${FILENAME}" mtg-*-linux-*
    echo -e "${GREEN}下载并安装成功: mtg${PLAIN}"

    # Alpine 兼容性检查
    if [[ "$OS" == "alpine" ]]; then
        echo -e "${YELLOW}检测到 Alpine，安装 gcompat 兼容库...${PLAIN}"
        apk add gcompat
    fi

    # 配置向导
    read -p "请输入端口 (默认 443): " PORT
    [ -z "$PORT" ] && PORT=443
    
    read -p "请输入伪装域名 (默认 azure.microsoft.com): " DOMAIN
    [ -z "$DOMAIN" ] && DOMAIN="azure.microsoft.com"
    
    SECRET=$(generate_secret)
    echo -e "${GREEN}生成的密钥: $SECRET${PLAIN}"

    # 生成配置文件 (toml)
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_DIR/mtg.toml" <<EOF
secret = "$SECRET"
bind-to = "0.0.0.0:$PORT"

[defense]
anti-replay = true
EOF

    # 创建服务
    create_service_mtg "$PORT" "$SECRET" "$DOMAIN"
    
    # 检查 mgt 是否能运行
    "$BIN_DIR/mtg" --version >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误: mtg 二进制文件无法执行。可能是架构错误。${PLAIN}"
    fi

    # 检查服务状态
    sleep 2
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if systemctl is-active --quiet mtg; then
            echo -e "${GREEN}安装完成! 服务已启动。${PLAIN}"
            show_info_mtg "$PORT" "$SECRET" "$DOMAIN"
        else
            echo -e "${RED}服务启动失败！日志如下：${PLAIN}"
            journalctl -u mtg --no-pager -n 20
        fi
    else
        show_info_mtg "$PORT" "$SECRET" "$DOMAIN"
    fi
}

create_service_mtg() {
    PORT=$1
    SECRET=$2
    DOMAIN=$3
    
    # 计算 Full Secret (ee + secret + domain_hex)
    HEX_DOMAIN=$(echo -n "$DOMAIN" | od -A n -t x1 | tr -d ' \n')
    FULL_SECRET="ee${SECRET}${HEX_DOMAIN}"
    
    # mtg v2 simple-run 语法: mtg simple-run [flags] <bind-to> <secret>
    # 注意: secret 必须是包含域名的完整 secret (ee开头)
    # flag -b 是 tcp-buffer 不是 bind，千万别用
    
    CMD_ARGS="simple-run -n 1.1.1.1 -t 30s -a 1mb 0.0.0.0:$PORT $FULL_SECRET"
    EXEC_CMD="$BIN_DIR/mtg $CMD_ARGS"
    
    echo -e "${BLUE}正在创建服务...${PLAIN}"
    
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
command="$BIN_DIR/mtg"
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

show_info_mtg() {
    IP=$(get_public_ip)
    HEX_DOMAIN=$(echo -n "$3" | od -A n -t x1 | tr -d ' \n')
    FULL_SECRET="ee$2$HEX_DOMAIN"
    
    echo -e "=============================="
    echo -e "      算 法 信 息 (Mtg)"
    echo -e "=============================="
    echo -e "IP: $IP"
    echo -e "端口: $1"
    echo -e "Secret: $FULL_SECRET"
    echo -e "Domain: $3"
    echo -e "=============================="
    echo -e "tg://proxy?server=$IP&port=$1&secret=$FULL_SECRET"
}

# --- 服务管理逻辑 ---
control_service() {
    ACTION=$1
    shift
    TARGETS="$@"
    
    if [[ -z "$TARGETS" ]]; then
        TARGETS="mtg mtp-python"
    fi

    for SERVICE in $TARGETS; do
        # 检查服务文件是否存在，避免报错
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            if [ -f "/etc/systemd/system/${SERVICE}.service" ]; then
                echo -e "${BLUE}${ACTION} ${SERVICE}...${PLAIN}"
                systemctl $ACTION $SERVICE
            fi
        else
            if [ -f "/etc/init.d/${SERVICE}" ]; then
                echo -e "${BLUE}${ACTION} ${SERVICE}...${PLAIN}"
                rc-service $SERVICE $ACTION
            fi
        fi
    done
}

# --- 辅助函数：获取服务状态字符串 ---
get_service_status_str() {
    local service=$1
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if [ -f "/etc/systemd/system/${service}.service" ]; then
            if systemctl is-active --quiet "$service"; then
                echo -e "${GREEN}运行中${PLAIN}"
            else
                echo -e "${RED}已停止${PLAIN}"
            fi
        else
            echo -e "${YELLOW}未安装${PLAIN}"
        fi
    else
        # OpenRC
        if [ -f "/etc/init.d/${service}" ]; then
            if rc-service "$service" status 2>/dev/null | grep -q "started"; then
                echo -e "${GREEN}运行中${PLAIN}"
            else
                echo -e "${RED}已停止${PLAIN}"
            fi
        else
            echo -e "${YELLOW}未安装${PLAIN}"
        fi
    fi
}

show_status() {
    echo -e "=============================="
    echo -e "       服 务 状 态"
    echo -e "=============================="
    echo -e "MTProxy (Go):     $(get_service_status_str mtg)"
    echo -e "MTProxy (Python): $(get_service_status_str mtp-python)"
    echo -e "=============================="
}

# --- 修改配置逻辑 ---

modify_mtg() {
    # 读取当前配置
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        CMD_LINE=$(grep "ExecStart" /etc/systemd/system/mtg.service 2>/dev/null)
    else
        CMD_LINE=$(grep "command_args" /etc/init.d/mtg 2>/dev/null)
    fi
    
    if [ -z "$CMD_LINE" ]; then
        echo -e "${YELLOW}未检测到 MTG 服务配置。${PLAIN}"
        return
    fi

    CUR_PORT=$(echo "$CMD_LINE" | sed -n 's/.*0\.0\.0\.0:\([0-9]*\).*/\1/p')
    CUR_SECRET=$(echo "$CMD_LINE" | sed -n 's/.*\(ee[0-9a-fA-F]*\).*/\1/p')
    
    # 解析当前域名
    CUR_DOMAIN=""
    if [[ -n "$CUR_SECRET" ]]; then
        DOMAIN_HEX=${CUR_SECRET:34}
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
    
    echo -e "${BLUE}正在重新生成密钥和配置...${PLAIN}"
    # Go版必须重新生成完整密钥，因为包含域名Hex
    NEW_SECRET=$("$BIN_DIR/mtg" generate-secret --hex "$NEW_DOMAIN")
    
    # 复用创建服务函数来更新配置
    create_service_mtg "$NEW_PORT" "$NEW_SECRET"
    
    # 重启服务
    echo -e "${BLUE}正在重启服务...${PLAIN}"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl daemon-reload
        systemctl restart mtg
    else
        rc-service mtg restart
    fi
    
    echo -e "${GREEN}修改成功！新配置如下：${PLAIN}"
    show_info_mtg "$NEW_PORT" "$NEW_SECRET" "$NEW_DOMAIN"
}

modify_python() {
    if [ ! -f "$CONFIG_DIR/config.py" ]; then
         echo -e "${YELLOW}未检测到 Python 版配置文件。${PLAIN}"
         return
    fi
    
    CUR_PORT=$(grep "PORT =" "$CONFIG_DIR/config.py" | awk '{print $3}')
    CUR_DOMAIN=$(grep "TLS_DOMAIN =" "$CONFIG_DIR/config.py" | awk -F= '{print $2}' | tr -d ' "')
    # 处理提取出的空白字符
    CUR_PORT=$(echo $CUR_PORT | xargs)
    CUR_DOMAIN=$(echo $CUR_DOMAIN | xargs)
    
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
    # 使用 sed 更新 config.py
    # 更新 PORT
    sed -i "s/PORT = .*/PORT = $NEW_PORT/" "$CONFIG_DIR/config.py"
    # 更新 TLS_DOMAIN
    sed -i "s/TLS_DOMAIN = .*/TLS_DOMAIN = \"$NEW_DOMAIN\"/" "$CONFIG_DIR/config.py"
    
    # 重启服务
    echo -e "${BLUE}正在重启服务...${PLAIN}"
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl restart mtp-python
    else
        rc-service mtp-python restart
    fi
    
    # 重新提取 Secret 以显示完整链接
    CUR_SECRET=$(grep "\"tg\":" "$CONFIG_DIR/config.py" | head -n 1 | awk -F: '{print $2}' | tr -d ' "', | xargs)
    
    echo -e "${GREEN}修改成功！新配置如下：${PLAIN}"
    show_info_python "$NEW_PORT" "$CUR_SECRET" "$NEW_DOMAIN"
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
    
    rm -f "$BIN_DIR/mtg"
    rm -f "$CONFIG_DIR/mtg.toml"
    
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
    echo -e "检测到现有配置:"
    INSTALLED_MTG=0
    INSTALLED_PYTHON=0
    
    if [[ -f "$BIN_DIR/mtg" ]]; then
        echo -e "${GREEN}1. MTProxy (Go 版)${PLAIN}"
        INSTALLED_MTG=1
    else
        echo -e "${YELLOW}1. MTProxy (Go 版) [未安装]${PLAIN}"
    fi
    
    if [[ -f "$BIN_DIR/mtp-python" ]]; then
        echo -e "${GREEN}2. MTProxy (Python 版)${PLAIN}"
        INSTALLED_PYTHON=1
    else
        echo -e "${YELLOW}2. MTProxy (Python 版) [未安装]${PLAIN}"
    fi
    
    echo -e "----------------------------------"
    read -p "请选择要删除的服务 [1-2]: " d_choice
    
    case $d_choice in
        1)
            if [ $INSTALLED_MTG -eq 1 ]; then
                delete_mtg
            else
                echo -e "${YELLOW}未安装，无需删除。${PLAIN}"
            fi
            ;;
        2) 
            if [ $INSTALLED_PYTHON -eq 1 ]; then
                delete_python
            else
                echo -e "${YELLOW}未安装，无需删除。${PLAIN}"
            fi
            ;;
        *) echo -e "${RED}无效选择${PLAIN}" ;;
    esac
    
    back_to_menu
}

# --- 菜单系统 ---
back_to_menu() {
    echo ""
    echo -e "${GREEN}操作完成。${PLAIN}"
    read -n 1 -s -r -p "按任意键返回主菜单..."
    menu
}

menu() {
    check_sys
    clear
    status_mtg=$(get_service_status_str mtg)
    status_python=$(get_service_status_str mtp-python)

    echo -e "=================================="
    echo -e "     MTProxy 综合管理脚本"
    echo -e "=================================="
    echo -e "系统信息: ${BLUE}${OS} (${INIT_SYSTEM})${PLAIN}"
    echo -e "Go     版: ${status_mtg}"
    echo -e "Python 版: ${status_python}"
    echo -e "=================================="
    echo -e "${GREEN}1.${PLAIN} 安装/配置 MTProxy (Go 版 - 推荐)"
    echo -e "${GREEN}2.${PLAIN} 安装/配置 MTProxy (Python 版 - 备用)"
    echo -e "----------------------------------"
    echo -e "${GREEN}3.${PLAIN} 查看详细连接信息"
    echo -e "${GREEN}4.${PLAIN} 启动服务"
    echo -e "${GREEN}5.${PLAIN} 停止服务"
    echo -e "${GREEN}6.${PLAIN} 重启服务"
    echo -e "${GREEN}7.${PLAIN} 修改服务配置 (端口/域名)"
    echo -e "${GREEN}8.${PLAIN} 删除服务配置 (选择删除)"
    echo -e "----------------------------------"
    echo -e "${GREEN}9.${PLAIN} 卸载服务"
    echo -e "${GREEN}0.${PLAIN} 退出"
    echo -e "=================================="
    read -p "请选择 [0-9]: " choice
    
    case $choice in
        1)
            install_base_deps
            install_mtg
            back_to_menu
            ;;
        2)
            install_base_deps
            install_mtp_python
            back_to_menu
            ;;
        3) 
            echo ""
            # --- 获取 Go 版信息 ---
            if [[ -f "/etc/systemd/system/mtg.service" ]] || [[ -f "/etc/init.d/mtg" ]]; then
                # 从服务文件中提取参数 (因为 mtg v2 simple-run 只有完整 secret，没有单独存 domain)
                if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                    CMD_LINE=$(grep "ExecStart" /etc/systemd/system/mtg.service)
                else
                    CMD_LINE=$(grep "command_args" /etc/init.d/mtg)
                fi
                
                # 提取端口 (匹配 0.0.0.0:xxxx)
                PORT=$(echo "$CMD_LINE" | sed -n 's/.*0\.0\.0\.0:\([0-9]*\).*/\1/p')
                
                # 提取完整 Secret (以 ee 开头，后面跟一长串 16进制)
                FULL_SECRET=$(echo "$CMD_LINE" | sed -n 's/.*\(ee[0-9a-fA-F]*\).*/\1/p')
                
                if [[ -n "$PORT" && -n "$FULL_SECRET" ]]; then
                    # 尝试解析基础 Secret (前34位: ee + 32位secret) 和 域名Hex (35位开始)
                    # MTProto Secret 通常是 16字节(32 hex chars)
                    BASE_SECRET=${FULL_SECRET:2:32}
                    DOMAIN_HEX=${FULL_SECRET:34}
                    
                    # 尝试解码域名 (如果有 Python3)
                    if [[ -n "$DOMAIN_HEX" ]]; then
                        # 尝试使用 xxd (如果存在)
                        if command -v xxd >/dev/null 2>&1; then
                             DOMAIN=$(echo "$DOMAIN_HEX" | xxd -r -p)
                        else
                             # 使用 bash内建 printf + sed 进行解码
                             # 将 hex 转换为 \xHH\xHH 格式
                             ESCAPED_HEX=$(echo "$DOMAIN_HEX" | sed 's/../\\x&/g')
                             DOMAIN=$(printf "$ESCAPED_HEX")
                        fi
                    fi
                    [ -z "$DOMAIN" ] && DOMAIN="(解析失败或未包含)"
                    
                    show_info_mtg "$PORT" "$BASE_SECRET" "$DOMAIN"
                else
                    echo -e "${YELLOW}无法从服务文件中提取 Go 版信息，请检查是否已安装。${PLAIN}"
                fi
            else
                echo -e "${YELLOW}Go 版服务文件不存在。${PLAIN}"
            fi
            
            echo ""
            
            # --- 获取 Python 版信息 ---
            if [ -f "$CONFIG_DIR/config.py" ]; then
                 PORT=$(grep "PORT =" "$CONFIG_DIR/config.py" | awk '{print $3}')
                 # 提取 secret，处理可能的引号和逗号
                 SECRET=$(grep "\"tg\":" "$CONFIG_DIR/config.py" | head -n 1 | awk -F: '{print $2}' | tr -d ' "',)
                 DOMAIN=$(grep "TLS_DOMAIN =" "$CONFIG_DIR/config.py" | awk -F= '{print $2}' | tr -d ' "')
                 
                 # 去除可能的前后空格
                 PORT=$(echo $PORT | xargs)
                 SECRET=$(echo $SECRET | xargs)
                 DOMAIN=$(echo $DOMAIN | xargs)
                 
                 show_info_python "$PORT" "$SECRET" "$DOMAIN"
            else
                 echo -e "${YELLOW}Python 版配置文件不存在。${PLAIN}"
            fi
            
            back_to_menu 
            ;;
        4) control_service start; back_to_menu ;;
        5) control_service stop; back_to_menu ;;
        6) control_service restart; back_to_menu ;;
        7) modify_config ;;
        8) delete_config ;;
        9)
            # 卸载逻辑
            echo -e "${RED}正在卸载...${PLAIN}"
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                systemctl stop mtg mtp-python 2>/dev/null
                systemctl disable mtg mtp-python 2>/dev/null
                rm -f /etc/systemd/system/mtg.service /etc/systemd/system/mtp-python.service
                systemctl daemon-reload
            else
                rc-service mtg stop 2>/dev/null
                rc-service mtp-python stop 2>/dev/null
                rc-update del mtg 2>/dev/null
                rc-update del mtp-python 2>/dev/null
                rm -f /etc/init.d/mtg /etc/init.d/mtp-python
            fi
            
            # 删除工作目录 (包含 bin, config, logs)
            # 先离开该目录，防止因占用导致删除失败
            cd /tmp
            rm -rf "$WORKDIR"
            
            echo -e "${GREEN}卸载完成。${PLAIN}"
            echo -e "${RED}正在删除脚本本身...${PLAIN}"
            
            if [ -f "$SCRIPT_PATH" ]; then
                rm -f "$SCRIPT_PATH"
                echo -e "${GREEN}脚本文件已删除: $SCRIPT_PATH${PLAIN}"
            else
                echo -e "${YELLOW}警告: 无法自动删除脚本文件，请手动删除。${PLAIN}"
            fi
            
            echo -e "${GREEN}再见!${PLAIN}"
            exit 0
            ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; menu ;;
    esac
}

# 入口
if [[ $# > 0 ]]; then
    CMD=$1
    shift
    case $CMD in
        install_go) check_sys && install_base_deps && install_mtg ;;
        install_python) check_sys && install_base_deps && install_mtp_python ;;
        start) check_sys && control_service start ;;
        stop) check_sys && control_service stop ;;
        restart) check_sys && control_service restart ;;
        status) check_sys && show_status ;;
        *) menu ;;
    esac
else
    menu
fi
