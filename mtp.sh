#!/usr/bin/env sh

# 遇到错误立即退出
set -e

# --- 全局配置 ---
BIN_PATH="/usr/local/bin/mtg"
CONFIG_DIR="/etc/mtg"
RELEASE_BASE_URL="https://github.com/9seconds/mtg/releases/download/v2.1.7"

# --- 功能函数 ---

# 1. 系统与环境检测
# =================================

check_init_system() {
    # 优先检测 OpenRC (Alpine 特征)
    if [ -f /etc/alpine-release ] || [ -f /sbin/openrc-run ]; then
        INIT_SYSTEM="openrc"
        echo "检测到系统环境: Alpine / OpenRC"
    # 其次检测 Systemd
    elif command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
        echo "检测到系统环境: Systemd"
    else
        echo "错误: 本脚本仅支持 Systemd (CentOS7+, Debian8+) 或 OpenRC (Alpine)。"
        echo "当前系统未检测到受支持的初始化系统，脚本退出。"
        exit 1
    fi
    
    mkdir -p "$CONFIG_DIR"
}

check_deps() {
    required_cmds="curl grep cut uname tar mktemp awk find head ps"
    
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

    if [ -f /etc/os-release ]; then . /etc/os-release; fi

    # 简单的包管理器判断
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl grep coreutils tar procps
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y curl grep coreutils tar procps
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl grep coreutils tar procps
    else
        echo "警告: 无法自动安装依赖，请手动安装所需工具。"
    fi
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

# 注册服务 (分流处理 Systemd 和 OpenRC)
setup_service_file() {
    service_type="$1"
    . "${CONFIG_DIR}/config_${service_type}"
    
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        # --- Systemd 逻辑 ---
        service_name="mtg-${service_type}"
        service_file="/etc/systemd/system/${service_name}.service"
        echo "正在创建 Systemd 服务文件: ${service_file} ..."
        
        cat > "$service_file" <<EOF
[Unit]
Description=MTG Proxy Service (${service_type})
Documentation=https://github.com/9seconds/mtg
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} simple-run 0.0.0.0:${PORT} ${SECRET}

# 日志配置
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mtg-${service_type}

# 自动重启配置（防止无限重启循环）
Restart=on-failure
RestartSec=5s
StartLimitInterval=60s
StartLimitBurst=5

# 资源限制
LimitNOFILE=65535
LimitNPROC=512
MemoryLimit=512M

# 安全加固
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "${service_name}"
        echo "Systemd 服务 [${service_name}] 已设置为开机自启。"

    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        # --- OpenRC 逻辑 (Alpine) ---
        service_name="mtg-${service_type}"
        service_file="/etc/init.d/${service_name}"
        echo "正在创建 OpenRC 服务脚本: ${service_file} ..."

        cat > "$service_file" <<EOF
#!/sbin/openrc-run

name="mtg-${service_type}"
description="MTG Proxy Service (${service_type})"
supervisor=supervise-daemon
command="${BIN_PATH}"
command_args="simple-run 0.0.0.0:${PORT} ${SECRET}"
pidfile="/run/\${RC_SVCNAME}.pid"

# 日志配置
output_log="/var/log/mtg-${service_type}.log"
error_log="/var/log/mtg-${service_type}.error.log"
supervise_daemon_args="--stdout \${output_log} --stderr \${error_log}"

# 自动重启配置（supervise-daemon 原生支持）
respawn_delay=5
respawn_max=5
respawn_period=60

# 资源限制
rc_ulimit="-n 65535 -u 512"

depend() {
    need net
    use dns
    after firewall
}

start_pre() {
    # 确保日志文件存在
    checkpath --file --mode 0644 --owner root:root "\${output_log}" "\${error_log}"
    # 清理可能存在的僵尸 PID 文件
    if [ -f "\${pidfile}" ]; then
        if ! kill -0 \$(cat "\${pidfile}") 2>/dev/null; then
            rm -f "\${pidfile}"
        fi
    fi
}
EOF
        chmod +x "$service_file"
        rc-update add "${service_name}" default
        echo "OpenRC 服务 [${service_name}] 已添加至默认启动级别。"
    fi
}

install_mtg() {
    service_type="$1"
    
    if ! [ -f "$BIN_PATH" ]; then
        ARCH=$(detect_arch)
        if [ "$ARCH" = "unsupported" ]; then echo "错误: 不支持的系统架构：$(uname -m)"; exit 1; fi
        
        TAR_NAME="mtg-2.1.7-linux-${ARCH}.tar.gz"; DOWNLOAD_URL="${RELEASE_BASE_URL}/${TAR_NAME}"
        TMP_DIR=$(mktemp -d); trap 'rm -rf -- "$TMP_DIR"' EXIT
        echo "正在下载主程序 ${DOWNLOAD_URL} …"; curl -L "${DOWNLOAD_URL}" -o "${TMP_DIR}/${TAR_NAME}"
        echo "正在解压文件..."; tar -xzf "${TMP_DIR}/${TAR_NAME}" -C "${TMP_DIR}"
        
        MTG_FOUND_PATH=$(find "${TMP_DIR}" -type f -name mtg | head -n 1)
        if [ -z "$MTG_FOUND_PATH" ]; then echo "错误：未找到 mtg 可执行文件！"; exit 1; fi

        mv "${MTG_FOUND_PATH}" "${BIN_PATH}"; chmod +x "${BIN_PATH}"
    fi

    get_mtg_config "$service_type"
    save_config "$service_type"
    setup_service_file "$service_type" # 生成并启用服务

    restart_service "$service_type"
    echo "[$service_type] 实例安装/更新完成！"
}

# 3. 服务管理 (兼容层)
# =================================

start_service() {
    service_type="$1"
    config_file="${CONFIG_DIR}/config_${service_type}"
    if ! [ -f "$config_file" ]; then echo "错误: [$service_type] 未配置。"; return 1; fi
    
    echo "正在启动 [$service_type] ..."
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl start "mtg-${service_type}"
    else
        rc-service "mtg-${service_type}" start
    fi
    sleep 1
    if is_running "$service_type"; then echo "启动成功。"; else echo "启动失败，请检查日志。"; fi
}

stop_service() {
    service_type="$1"
    # 临时禁用 set -e，避免服务不存在时脚本退出
    set +e
    
    # 先检查服务是否在运行
    if ! is_running "$service_type"; then
        echo "[$service_type] 服务未在运行。"
        set -e
        return 0
    fi
    
    echo "正在停止 [$service_type] ..."
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl stop "mtg-${service_type}"
    else
        rc-service "mtg-${service_type}" stop
    fi
    set -e
}

restart_service() {
    service_type="$1"
    echo "正在重启 [$service_type] ..."
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl restart "mtg-${service_type}"
    else
        rc-service "mtg-${service_type}" restart
    fi
}

is_running() {
    service_type="$1"
    # 临时禁用 set -e，避免服务未运行时脚本退出
    set +e
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl is-active --quiet "mtg-${service_type}"
        result=$?
    else
        rc-service "mtg-${service_type}" status >/dev/null 2>&1
        result=$?
    fi
    # 恢复 set -e
    set -e
    return $result
}

# 4. 辅助功能
# =================================

modify_port() {
    service_type="$1"
    config_file="${CONFIG_DIR}/config_${service_type}"
    if ! [ -f "$config_file" ]; then echo "错误: [$service_type] 未配置。"; return; fi
    
    # 读取当前配置
    . "$config_file"
    old_port=$PORT
    
    # 获取另一个实例的端口（避免冲突）
    other_type=""
    if [ "$service_type" = "secured" ]; then other_type="faketls"; else other_type="secured"; fi
    other_config_file="${CONFIG_DIR}/config_${other_type}"
    other_port=""
    if [ -f "$other_config_file" ]; then
        other_port=$(grep 'PORT=' "$other_config_file" | cut -d'=' -f2)
    fi
    
    echo
    echo "======= 修改 [$service_type] 端口 ======="
    echo "当前端口: $old_port"
    echo
    
    while true; do
        read -p "请输入新的端口号 (留空取消): " new_port
        if [ -z "$new_port" ]; then echo "操作已取消。"; return; fi
        
        # 验证端口号格式
        if ! echo "$new_port" | grep -qE '^[0-9]+$'; then
            echo "错误: 端口号必须是数字！"
            continue
        fi
        
        # 验证端口范围
        if [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
            echo "错误: 端口范围必须在 1-65535 之间！"
            continue
        fi
        
        # 检查是否与当前端口相同
        if [ "$new_port" = "$old_port" ]; then
            echo "错误: 新端口与当前端口相同！"
            continue
        fi
        
        # 检查是否与另一个实例冲突
        if [ -n "$other_port" ] && [ "$new_port" = "$other_port" ]; then
            echo "错误: 端口 $new_port 已被 [$other_type] 实例占用！"
            continue
        fi
        
        break
    done
    
    echo
    read -p "确认将端口从 $old_port 修改为 $new_port ？ (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then echo "操作已取消。"; return; fi
    
    # 更新配置文件
    PORT=$new_port
    save_config "$service_type"
    
    # 更新服务文件并重启
    setup_service_file "$service_type"
    restart_service "$service_type"
    
    echo
    echo "端口修改成功！新端口: $new_port"
    show_info "$service_type"
}

modify_faketls_domain() {
    service_type="$1"
    
    # 只对 faketls 类型有效
    if [ "$service_type" != "faketls" ]; then
        echo "错误: 只有 [faketls] 实例才能修改伪装域名！"
        echo "提示: [secured] 实例不使用伪装域名。"
        return
    fi
    
    config_file="${CONFIG_DIR}/config_${service_type}"
    if ! [ -f "$config_file" ]; then echo "错误: [$service_type] 未配置。"; return; fi
    
    # 读取当前配置
    . "$config_file"
    old_port=$PORT
    
    # 尝试从当前密钥提取域名（这只是显示用，不一定准确）
    echo
    echo "======= 修改 [faketls] 伪装域名 ======="
    echo "当前端口: $old_port"
    echo "提示: 修改域名会重新生成密钥"
    echo
    
    read -p "请输入新的伪装域名 (如 www.google.com, 留空取消): " new_domain
    if [ -z "$new_domain" ]; then echo "操作已取消。"; return; fi
    
    echo
    read -p "确认将伪装域名修改为 $new_domain ？ (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then echo "操作已取消。"; return; fi
    
    # 重新生成密钥
    echo "正在生成新的密钥..."
    SECRET=$("$BIN_PATH" generate-secret --hex "$new_domain")
    
    if [ -z "$SECRET" ]; then
        echo "错误: 密钥生成失败！"
        return
    fi
    
    # 更新配置文件（保持端口不变）
    PORT=$old_port
    save_config "$service_type"
    
    # 更新服务文件并重启
    setup_service_file "$service_type"
    restart_service "$service_type"
    
    echo
    echo "伪装域名修改成功！新域名: $new_domain"
    show_info "$service_type"
}

uninstall_mtg() {
    service_type="$1"
    config_file="${CONFIG_DIR}/config_${service_type}"
    
    echo
    read -p "您确定要卸载 [$service_type] 实例吗？ (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then echo "操作已取消。"; return; fi

    echo "开始卸载 [$service_type] ..."
    stop_service "$service_type"
    
    # 清理服务文件
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl disable "mtg-${service_type}" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/mtg-${service_type}.service"
        systemctl daemon-reload
    else
        rc-update del "mtg-${service_type}" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/mtg-${service_type}"
    fi

    rm -f "$config_file"
    echo "[$service_type] 配置文件与服务已删除。"

    # 清理主程序
    if ! [ -f "${CONFIG_DIR}/config_secured" ] && ! [ -f "${CONFIG_DIR}/config_faketls" ]; then
        echo
        read -p "所有实例均已卸载。是否删除主程序和此脚本？ (y/N): " cleanup_confirm
        if [ "$cleanup_confirm" = "y" ] || [ "$cleanup_confirm" = "Y" ]; then
            rm -f "$BIN_PATH"
            rm -rf "$CONFIG_DIR"
            echo "清理完成。脚本自我删除..."
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
    if [ -n "$MTP_PORT" ] && [ -n "$MTP_SECRET" ]; then
        echo "地址: ${IPV4} : ${MTP_PORT}"
        echo "密钥: ${MTP_SECRET}"
        echo "tg://proxy?server=${IPV4}&port=${MTP_PORT}&secret=${MTP_SECRET}"
    else
         echo "配置信息不完整。"
    fi
}

view_logs() {
    service_type="$1"
    config_file="${CONFIG_DIR}/config_${service_type}"
    if ! [ -f "$config_file" ]; then echo "错误: [$service_type] 未配置。"; return; fi
    
    echo
    echo "======= 查看 [${service_type}] 日志 ======="
    
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        echo "显示最近50行日志（按 q 退出）..."
        sleep 1
        journalctl -u "mtg-${service_type}" -n 50 --no-pager
        echo
        echo "提示: 使用 'journalctl -u mtg-${service_type} -f' 可实时查看日志"
    else
        # OpenRC 系统
        log_file="/var/log/mtg-${service_type}.log"
        error_file="/var/log/mtg-${service_type}.error.log"
        
        if [ -f "$log_file" ] || [ -f "$error_file" ]; then
            echo "--- 标准输出日志 (最近30行) ---"
            [ -f "$log_file" ] && tail -n 30 "$log_file" || echo "日志文件不存在"
            echo
            echo "--- 错误日志 (最近30行) ---"
            [ -f "$error_file" ] && tail -n 30 "$error_file" || echo "错误日志为空"
        else
            echo "日志文件尚未生成，请先启动服务。"
        fi
    fi
}

# 5. 菜单系统
# =================================
manage_service() {
    service_type="$1"
    while true; do
        is_installed="未安装"; if [ -f "${CONFIG_DIR}/config_${service_type}" ]; then is_installed="已安装"; fi
        
        # 使用临时变量保存is_running结果，避免set -e影响
        running_status="未运行"
        if is_running "$service_type"; then
            running_status="运行中"
        fi
        
        echo
        echo "=========== 管理 [${service_type}] 实例 =========="
        echo "   状态: ${is_installed} | 运行: ${running_status}"
        echo "   1) 安装 / 修改配置"
        echo "   2) 启动"
        echo "   3) 停止"
        echo "   4) 重启"
        echo "   5) 查看链接"
        echo "   6) 查看日志"
        echo "   7) 修改端口"
        
        # 只有 faketls 实例才显示修改伪装域名选项
        if [ "$service_type" = "faketls" ]; then
            echo "   8) 修改伪装域名"
            echo "   9) 卸载"
        else
            echo "   8) 卸载"
        fi
        
        echo "   0) 返回"
        echo
        read -p "选项: " opt
        
        # 根据 service_type 处理不同的选项
        if [ "$service_type" = "faketls" ]; then
            case "$opt" in
                1) install_mtg "$service_type" ;;
                2) start_service "$service_type" ;;
                3) stop_service "$service_type" ;;
                4) restart_service "$service_type" ;;
                5) show_info "$service_type" ;;
                6) view_logs "$service_type" ;;
                7) modify_port "$service_type" ;;
                8) modify_faketls_domain "$service_type" ;;
                9) uninstall_mtg "$service_type" ;;
                0) return ;;
                *) echo "无效选项" ;;
            esac
        else
            # secured 实例
            case "$opt" in
                1) install_mtg "$service_type" ;;
                2) start_service "$service_type" ;;
                3) stop_service "$service_type" ;;
                4) restart_service "$service_type" ;;
                5) show_info "$service_type" ;;
                6) view_logs "$service_type" ;;
                7) modify_port "$service_type" ;;
                8) uninstall_mtg "$service_type" ;;
                0) return ;;
                *) echo "无效选项" ;;
            esac
        fi
    done
}

show_main_menu() {
    echo
    echo "===== MTProxy 管理脚本 (当前系统: ${INIT_SYSTEM}) ====="
    echo "1) [secured] 实例"
    echo "2) [faketls] 实例（推荐）"
    echo "0) 退出"
    read -p "选项: " opt
    case "$opt" in
        1) manage_service "secured" ;;
        2) manage_service "faketls" ;;
        0|q) exit 0 ;;
        *) echo "无效选项" ;;
    esac
}

main() {
    check_init_system
    check_deps
    while true; do show_main_menu; done
}

main