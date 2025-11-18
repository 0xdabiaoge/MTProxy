#!/usr/bin/env sh

# 脚本设置为在遇到错误时立即退出
set -e

# --- 全局配置 ---
BIN_PATH="/usr/local/bin/mtg"
CONFIG_DIR="/etc/mtg"
RELEASE_BASE_URL="https://github.com/9seconds/mtg/releases/download/v2.1.7"

# --- 功能函数 ---

# 1. 系统与环境检测
# =================================

check_init_system() {
    # 使用兼容 BusyBox ps 的语法来获取 PID 1 的进程名
    pid1_comm=$(ps -o comm= 1 | tail -n 1 | tr -d ' ')

    if [ "$pid1_comm" = "systemd" ]; then
        INIT_SYSTEM="systemd"
    elif [ "$pid1_comm" = "init" ] && command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="direct"
    fi
    # 确保相关目录存在
    mkdir -p "$CONFIG_DIR"
    mkdir -p "/var/run"
}

check_deps() {
    required_cmds="curl grep cut uname tar mktemp awk find head ps"
    # 在非 systemd 系统上，start-stop-daemon 是必须的
    if [ "$INIT_SYSTEM" != "systemd" ]; then
        required_cmds="$required_cmds start-stop-daemon"
    fi

    deps_ok=true
    for cmd in $required_cmds; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            deps_ok=false; echo "错误: 缺少核心命令: $cmd";
        fi
    done
    if $deps_ok; then return; fi

    echo
    read -p "脚本依赖缺失，是否尝试自动安装？ (y/N): " answer
    if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
        echo "错误: 缺少依赖，脚本无法继续运行！"; exit 1;
    fi

    if [ -f /etc/os-release ]; then . /etc/os-release; else
        echo "错误: 无法检测到操作系统类型！"; exit 1;
    fi

    case "$ID" in
        ubuntu|debian) apt-get install -y curl grep coreutils tar procps daemon ;;
        alpine) apk add --no-cache curl grep coreutils tar procps openrc ;;
        *) echo "警告: 无法自动安装依赖，请手动安装所需工具。" ;;
    esac
}

detect_arch() {
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "amd64" ;;
        i386|i686) echo "386" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        armv6l) echo "armv6" ;;
        *) echo "unsupported" ;;
    esac
}

# 2. 核心安装与配置
# =================================

get_mtg_config() {
    service_type="$1"
    other_type=""
    if [ "$service_type" = "secured" ]; then other_type="faketls"; else other_type="secured"; fi
    other_config_file="${CONFIG_DIR}/config_${other_type}"
    other_port=""

    if [ -f "$other_config_file" ]; then
        other_port=$(grep 'PORT=' "$other_config_file" | cut -d'=' -f2)
    fi

    echo
    echo "--- 配置 [${service_type}] 代理 ---"
    
    if [ "$service_type" = "faketls" ]; then
        read -p "请输入用于伪装的域名 (默认 www.microsoft.com): " FAKE_TLS_DOMAIN
        if [ -z "$FAKE_TLS_DOMAIN" ]; then FAKE_TLS_DOMAIN="www.microsoft.com"; fi
        SECRET=$("$BIN_PATH" generate-secret --hex "$FAKE_TLS_DOMAIN")
    else
        SECRET=$("$BIN_PATH" generate-secret "secured")
    fi

    while true; do
        read -p "请输入监听端口 (留空随机): " PORT
        if [ -z "$PORT" ]; then PORT=$((10000 + RANDOM % 45535)); fi
        
        if [ -n "$other_port" ] && [ "$PORT" = "$other_port" ]; then
            echo "错误: 端口 $PORT 已被 [${other_type}] 实例占用，请重新输入。"
        else
            break
        fi
    done
}

save_config() {
    service_type="$1"
    config_file="${CONFIG_DIR}/config_${service_type}"
    echo "PORT=${PORT}" > "$config_file"
    echo "SECRET=${SECRET}" >> "$config_file"
}

install_mtg() {
    service_type="$1"
    
    # 只有在主程序不存在时才执行下载
    if ! [ -f "$BIN_PATH" ]; then
        ARCH=$(detect_arch)
        if [ "$ARCH" = "unsupported" ]; then echo "错误: 不支持的系统架构：$(uname -m)"; exit 1; fi
        echo "检测到系统架构：$ARCH"

        TAR_NAME="mtg-2.1.7-linux-${ARCH}.tar.gz"; DOWNLOAD_URL="${RELEASE_BASE_URL}/${TAR_NAME}"
        TMP_DIR=$(mktemp -d); trap 'rm -rf -- "$TMP_DIR"' EXIT
        echo "正在下载主程序 ${DOWNLOAD_URL} …"; curl -L "${DOWNLOAD_URL}" -o "${TMP_DIR}/${TAR_NAME}"
        echo "正在解压文件..."; tar -xzf "${TMP_DIR}/${TAR_NAME}" -C "${TMP_DIR}"
        
        MTG_FOUND_PATH=$(find "${TMP_DIR}" -type f -name mtg | head -n 1)
        if [ -z "$MTG_FOUND_PATH" ]; then echo "错误：未找到 mtg 可执行文件！"; exit 1; fi

        mv "${MTG_FOUND_PATH}" "${BIN_PATH}"; chmod +x "${BIN_PATH}"
        echo "主程序已安装至 ${BIN_PATH}"
    fi

    get_mtg_config "$service_type"
    save_config "$service_type"
    echo "配置已保存至 ${CONFIG_DIR}/config_${service_type}"

    restart_service "$service_type"
    echo "[$service_type] 实例安装/更新完成！"
}

# 3. 服务管理 (所有函数都接受 service_type 作为参数)
# =================================

start_service() {
    service_type="$1"
    config_file="${CONFIG_DIR}/config_${service_type}"
    pid_file="/var/run/mtg_${service_type}.pid"

    if ! [ -f "$config_file" ]; then echo "错误: [$service_type] 未配置，请先安装。"; return 1; fi
    if is_running "$service_type"; then echo "[$service_type] 已在运行中。"; return; fi

    echo "正在启动 [$service_type] 服务..."
    . "$config_file"; args="simple-run 0.0.0.0:${PORT} ${SECRET}"
    start-stop-daemon --start --quiet --pidfile "$pid_file" --make-pidfile --background \
        --exec "$BIN_PATH" -- ${args}
    sleep 1
    if is_running "$service_type"; then echo "[$service_type] 服务已启动。"; else echo "[$service_type] 服务启动失败。"; fi
}

stop_service() {
    service_type="$1"
    pid_file="/var/run/mtg_${service_type}.pid"

    if ! is_running "$service_type"; then echo "[$service_type] 服务未在运行。"; return; fi
    
    echo "正在停止 [$service_type] 服务..."
    start-stop-daemon --stop --quiet --pidfile "$pid_file"
    rm -f "$pid_file"
    echo "[$service_type] 服务已停止。"
}

restart_service() {
    service_type="$1"
    if is_running "$service_type"; then stop_service "$service_type"; sleep 1; fi
    start_service "$service_type"
}

is_running() {
    service_type="$1"
    pid_file="/var/run/mtg_${service_type}.pid"
    # 检查pid文件是否存在，并且/proc/目录下是否存在对应的pid目录
    if [ -f "$pid_file" ] && [ -d "/proc/$(cat "$pid_file")" ]; then
        return 0 # 0 表示 true (成功)
    else
        return 1 # 1 表示 false (失败)
    fi
}

# 4. 辅助功能
# =================================

uninstall_mtg() {
    service_type="$1"
    config_file="${CONFIG_DIR}/config_${service_type}"
    
    echo
    read -p "您确定要卸载 [$service_type] 实例吗？ (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then echo "操作已取消。"; return; fi

    echo
    echo "开始卸载 [$service_type] ..."; if is_running "$service_type"; then stop_service "$service_type"; fi
    
    rm -f "$config_file"
    echo "[$service_type] 已卸载。"

    # 如果两个实例都卸载了，询问是否删除主程序和脚本
    if ! [ -f "${CONFIG_DIR}/config_secured" ] && ! [ -f "${CONFIG_DIR}/config_faketls" ]; then
        echo
        read -p "所有实例均已卸载。是否删除主程序和此脚本？ (y/N): " cleanup_confirm
        if [ "$cleanup_confirm" = "y" ] || [ "$cleanup_confirm" = "Y" ]; then
            rm -f "$BIN_PATH"
            rm -rf "$CONFIG_DIR"
            echo "主程序和配置文件目录已删除。"
            echo "脚本将在1秒后自我删除..."
            ( sleep 1 && rm -- "$0" ) & exit 0
        fi
    fi
}

show_info() {
    service_type="$1"
    config_file="${CONFIG_DIR}/config_${service_type}"

    if ! [ -f "$config_file" ]; then echo "错误: [$service_type] 未配置。"; return; fi

    . "$config_file"; MTP_PORT=${PORT}; MTP_SECRET=${SECRET}
    
    IPV4=$(curl -s4 --connect-timeout 2 ip.sb || echo "无法获取")
    echo
    echo "======= [${service_type}] MTProxy 链接 ======="
    if [ -n "$IPV4" ] && [ -n "$MTP_PORT" ] && [ -n "$MTP_SECRET" ]; then
        echo "服务器地址: ${IPV4}"
        echo "端口:       ${MTP_PORT}"
        echo "密钥:       ${MTP_SECRET}"
        echo
        echo "tg://proxy?server=${IPV4}&port=${MTP_PORT}&secret=${MTP_SECRET}"
        echo "https://t.me/proxy?server=${IPV4}&port=${MTP_PORT}&secret=${MTP_SECRET}"
    else
         echo "无法获取配置信息。"
    fi
}

# 5. 菜单系统
# =================================

manage_service() {
    service_type="$1"
    while true; do
        is_installed="未安装"; if [ -f "${CONFIG_DIR}/config_${service_type}" ]; then is_installed="已安装"; fi
        running_status="未运行"; if is_running "$service_type"; then running_status="运行中"; fi
        
        echo
        echo "=========== 管理 [${service_type}] 实例 ==========="
        echo "   状态: ${is_installed} | 运行: ${running_status}"
        echo "-------------------------------------------------"
        echo "   1) 安装 / 修改配置"
        echo "   2) 启动"
        echo "   3) 停止"
        echo "   4) 重启"
        echo "   5) 查看链接信息"
        echo "   6) 卸载此实例"
        echo "-------------------------------------------------"
        echo "   0) 返回主菜单"
        echo
        read -p "请输入选项: " opt
        case "$opt" in
            1) install_mtg "$service_type" ;;
            2) start_service "$service_type" ;;
            3) stop_service "$service_type" ;;
            4) restart_service "$service_type" ;;
            5) show_info "$service_type" ;;
            6) uninstall_mtg "$service_type" ;;
            0) return ;;
            *) echo "无效选项，请重新输入。" ;;
        esac
    done
}

show_main_menu() {
    secured_status="未运行"; if is_running secured; then secured_status="运行中"; fi
    faketls_status="未运行"; if is_running faketls; then faketls_status="运行中"; fi
    
    echo
    echo "=========== MTProxy 多实例管理脚本 (管理器: ${INIT_SYSTEM}) ==========="
    echo "1) 管理 [secured] 实例 (状态: ${secured_status})"
    echo "2) 管理 [faketls] 实例 (状态: ${faketls_status})"
    echo "-------------------------------------------------"
    echo "0) 退出脚本"
    echo
    read -p "请输入选项: " opt
    case "$opt" in
        1) manage_service "secured" ;;
        2) manage_service "faketls" ;;
        0|q|Q) exit 0 ;;
        *) echo "无效选项，请重新输入。" ;;
    esac
}

# 6. 主流程
# =================================
main() {
    check_init_system
    check_deps
    
    while true; do
        show_main_menu
    done
}

main
