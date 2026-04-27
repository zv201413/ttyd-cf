#!/bin/bash
#====================================================
# ttyd + Cloudflare Argo Tunnel 一键部署脚本
# 支持多实例部署
#
# 单实例模式:
#   export TTYD_PORT=7681
#   export TTYD_USER=root
#   export TTYD_PASS=password
#   export CF_TOKEN='your_token'
#
# 多实例模式 (使用 P1/P2/P3...):
#   export TTYD_P1=7681:root1:pass1:token1
#   export TTYD_P2=7682:root2:pass2:token2
#====================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 默认值（支持环境变量和命令行参数两种传入方式）
# 如果作为命令行参数传入（如: script.sh arg1 arg2），则按位置解析
if [ -n "$1" ] && [ "$1" != "${1#*=}" ]; then
    # 检测到以 VAR=value 格式传入，导出为环境变量
    eval "export $1"
fi
if [ -n "$2" ] && [ "$2" != "${2#*=}" ]; then
    eval "export $2"
fi
if [ -n "$3" ] && [ "$3" != "${3#*=}" ]; then
    eval "export $3"
fi
if [ -n "$4" ] && [ "$4" != "${4#*=}" ]; then
    eval "export $4"
fi

# 检测多实例模式
declare -A INSTANCE_CONFIGS
if [ -n "$TTYD_P1" ]; then
    INSTANCE_MODE=true
    for var in $(env | grep '^TTYD_P[0-9]=' | cut -d= -f1 | sort -V); do
        val="${!var}"
        if [ -n "$val" ]; then
            INSTANCE_CONFIGS["$var"]="$val"
        fi
    done
    echo -e "${BLUE}检测到多实例模式: ${#INSTANCE_CONFIGS[@]} 个实例${NC}"
else
    INSTANCE_MODE=false
fi

# 单实例默认值（仅在非多实例模式时使用）
if [ "$INSTANCE_MODE" = "false" ]; then
    TTYD_PORT=${TTYD_PORT:-7681}
    TTYD_USER=${TTYD_USER:-ttyd}
    TTYD_PASS=${TTYD_PASS:-password}
    CF_TOKEN=${CF_TOKEN:-}
    KPAL=${KPAL:-}
    
    # 修正 HOME 路径逻辑
    if [ "$TTYD_USER" = "root" ]; then
        USER_HOME="/root"
    else
        USER_HOME="/home/$TTYD_USER"
    fi
fi

# 检测架构
detect_arch() {
    case $(uname -m) in
        aarch64|arm64) echo "arm64" ;;
        x86_64|amd64) echo "amd64" ;;
        *) echo "unsupported" ;;
    esac
}

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

# 安装依赖
install_deps() {
    local os=$(detect_os)
    echo -e "${BLUE}[1/5] 安装系统依赖...${NC}"

    case "$os" in
        debian|ubuntu|pop)
            apt-get update -qq
            apt-get install -y -qq curl wget tar openssl supervisor || apt-get install -y -qq curl wget tar openssl
            ;;
        rhel|centos|fedora)
            yum install -y -q epel-release || dnf install -y -q epel-release || true
            yum install -y -q curl wget tar openssl supervisor || dnf install -y -q curl wget tar openssl supervisor || true
            ;;
        alpine)
            apk add --no-cache curl wget tar openssl supervisor
            ;;
        *)
            echo -e "${YELLOW}未知系统，尝试安装基础依赖...${NC}"
            apt-get install -y -qq curl wget tar openssl supervisor 2>/dev/null || yum install -y -q curl wget tar openssl supervisor 2>/dev/null || true
            ;;
    esac
}

# 安装ttyd
install_ttyd() {
    echo -e "${BLUE}[2/5] 安装 ttyd...${NC}"
    local arch=$(detect_arch)
    local ttyd_bin=""
    local ttyd_path=""
    
# 检查是否已安装
    if command -v ttyd >/dev/null 2>&1; then
        ttyd_path=$(which ttyd)
        echo -e "${GREEN}ttyd 已安装: $ttyd_path${NC}"
        # 记录实际路径供后续使用
        export TTYD_BIN="$ttyd_path"
    else
        local ttyd_bin="/usr/local/bin/ttyd"
        local ttyd_version="1.10.0"
        
        # 架构映射
        local arch_map=""
        case "$arch" in
            amd64|x86_64) arch_map="x86_64" ;;
            arm64|aarch64) arch_map="aarch64" ;;
            arm) arch_map="arm" ;;
            armhf) arch_map="armhf" ;;
            i686) arch_map="i686" ;;
        esac
        
        local ttyd_url="https://github.com/tsl0922/ttyd/releases/download/${ttyd_version}/ttyd.${arch_map}"

        echo "正在下载 ttyd ${ttyd_version} (${arch_map})..."
        curl -fL --retry 3 -o "$ttyd_bin" "$ttyd_url" 2>/dev/null || \
        wget -q -O "$ttyd_bin" "$ttyd_url" || {
            # 备用：使用latest标签
            echo "备用源..."
            local ttyd_url_backup="https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.${arch_map}"
            curl -fL --retry 3 -o "$ttyd_bin" "$ttyd_url_backup" 2>/dev/null || \
            wget -q -O "$ttyd_bin" "$ttyd_url_backup" || {
                # 最后的备用：yonggekkk的源
                echo "尝试第三方源..."
                curl -fL --retry 2 -o "$ttyd_bin" "https://github.com/yonggekkk/ServerStatus/releases/download/ttyd/ttyd-linux-${arch}" 2>/dev/null || \
                wget -q -O "$ttyd_bin" "https://github.com/yonggekkk/ServerStatus/releases/download/ttyd/ttyd-linux-${arch}"
            }
        }
        chmod +x "$ttyd_bin" && echo -e "${GREEN}ttyd 二进制权限已设置${NC}"
    fi
    
    echo -e "${GREEN}ttyd 安装完成${NC}"
}

# 安装cloudflared
install_cloudflared() {
    echo -e "${BLUE}[3/5] 安装 cloudflared...${NC}"
    local arch=$(detect_arch)
    local cfd_bin="/usr/local/bin/cloudflared"
    
    # 检查是否已安装
    if command -v cloudflared >/dev/null 2>&1; then
        echo -e "${GREEN}cloudflared 已安装$(cloudflared version 2>/dev/null)${NC}"
        return 0
    fi
    
    echo "正在下载 cloudflared (${arch})..."
    local cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    
    curl -Lo "$cfd_bin" -# --retry 2 "$cf_url" || \
    wget -O "$cfd_bin" --tries=2 "$cf_url" || {
        echo -e "${RED}cloudflared 下载失败，请检查网络连接${NC}"
        return 1
    }
    chmod +x "$cfd_bin"
    
    echo -e "${GREEN}cloudflared 安装完成 ($(cloudflared version 2>&1)${NC})"
}

# 配置用户
setup_user() {
    echo -e "${BLUE}[4/5] 配置用户...${NC}"
    
    # 创建用户（如果不存在且不是root）
    if [ "$TTYD_USER" != "root" ] && ! id -u "$TTYD_USER" >/dev/null 2>&1; then
        local os=$(detect_os)
        if [ "$os" = "alpine" ]; then
            # Alpine 使用 adduser
            adduser -D -s /bin/bash "$TTYD_USER" 2>/dev/null || adduser -D "$TTYD_USER" 2>/dev/null
        else
            # 其他系统使用 useradd
            useradd -m -s /bin/bash "$TTYD_USER" 2>/dev/null || useradd -m "$TTYD_USER" 2>/dev/null
        fi
    fi
    
    # 设置密码
    if [ -n "$TTYD_PASS" ]; then
        echo "$TTYD_USER:$TTYD_PASS" | chpasswd 2>/dev/null || {
            # 备用方法（处理 Alpine 或其他不支持 --stdin 的系统）
            echo -e "$TTYD_PASS\n$TTYD_PASS" | passwd "$TTYD_USER" 2>/dev/null || true
        }
    fi
    
    # sudo 权限
    if [ -n "$TTYD_USER" ] && [ "$TTYD_USER" != "root" ]; then
        mkdir -p /etc/sudoers.d
        echo "$TTYD_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$TTYD_USER" 2>/dev/null || true
    fi
    
    echo -e "${GREEN}用户配置完成: $TTYD_USER${NC}"
}

# 生成Supervisor配置
generate_supervisor_conf() {
    echo -e "${BLUE}[5/5] 生成服务配置...${NC}"

    local boot_dir="$USER_HOME/boot"
    local conf_file="$boot_dir/supervisord.conf"
    local pid_file="$boot_dir/supervisord.pid"
    local sock_file="/tmp/supervisor_$TTYD_USER.sock"
    mkdir -p "$boot_dir"
    
    # Supervisor配置
    cat > "$conf_file" <<EOF
[unix_http_server]
file=$sock_file
chmod=0777

[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord_$TTYD_USER.log
pidfile=$pid_file

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://$sock_file
EOF

    # ttyd配置
    cat >> "$conf_file" <<EOF

[program:ttyd]
command=${TTYD_BIN:-/usr/local/bin/ttyd} -c ${TTYD_USER}:${TTYD_PASS} -p ${TTYD_PORT} -W bash
autostart=true
autorestart=true
stdout_logfile=/var/log/ttyd.out.log
stderr_logfile=/var/log/ttyd.err.log
EOF

    # cloudflared配置（如果Token已设置）
    if [ -n "$CF_TOKEN" ]; then
        cat >> "$conf_file" <<EOF

[program:cloudflared]
command=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${CF_TOKEN}
autostart=true
autorestart=true
stdout_logfile=/var/log/cloudflared.out.log
stderr_logfile=/var/log/cloudflared.err.log
EOF
    fi

    # 保活脚本（如果KPAL已设置）
    if [ -n "$KPAL" ]; then
        # 生成保活脚本
        cat > /tmp/keepalive.sh <<'KPEOF'
#!/bin/bash
# 保活脚本 - 自动生成
KPAL="${KPAL}"
[[ "$KPAL" == *":"*":"* ]] && range=$(echo "$KPAL" | cut -d: -f1) && offset=$(echo "$KPAL" | cut -d: -f2) && url=$(echo "$KPAL" | cut -d: -f3-)
range=${range:-300}
offset=${offset:-60}
url=${url:-http://localhost}

while true; do
    sleep_time=$((RANDOM % range + offset))
    sleep $sleep_time
    curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000"
done
KPEOF
        chmod +x /tmp/keepalive.sh
        
        cat >> "$conf_file" <<EOF

[program:kpal]
command=/tmp/keepalive.sh
autostart=true
autorestart=true
stdout_logfile=/dev/null
stderr_logfile=/dev/null
EOF
    fi

    # 设置权限
    chown -R "$TTYD_USER:$TTYD_USER" "$boot_dir"
    
    # 创建日志目录
    mkdir -p /var/log/supervisor /var/log/ttyd /var/log/cloudflared 2>/dev/null || true
    
    echo -e "${GREEN}配置文件已生成: $conf_file${NC}"
}

# 启动服务
start_services() {
    echo -e "${BLUE}启动服务...${NC}"

    mkdir -p /var/log/supervisor /var/log/ttyd /var/log/cloudflared 2>/dev/null || true

    # 检查supervisor是否可用
    if command -v supervisord >/dev/null 2>&1 && [ -f "$USER_HOME/boot/supervisord.conf" ]; then
        ln -sf /usr/bin/supervisorctl /usr/local/bin/sctl 2>/dev/null || true
        echo "alias sctl='supervisorctl -c $USER_HOME/boot/supervisord.conf'" >> /etc/bash.bashrc 2>/dev/null || true
        nohup /usr/bin/supervisord -c "$USER_HOME/boot/supervisord.conf" >/var/log/supervisor/supervisord.log 2>&1 &
        sleep 2
        echo -e "${GREEN}Supervisor 已启动${NC}"
    else
        # 直接启动ttyd（无supervisor模式）
        nohup ${TTYD_BIN:-/usr/local/bin/ttyd} -c "${TTYD_USER}:${TTYD_PASS}" -p "${TTYD_PORT}" -W bash >/var/log/ttyd.out.log 2>&1 &
        sleep 1
        
        # 如果有CF TOKEN，启动cloudflared
        if [ -n "$CF_TOKEN" ] && command -v cloudflared >/dev/null 2>&1; then
            nohup /usr/local/bin/cloudflared tunnel --no-autoupdate run --token "${CF_TOKEN}" >/var/log/cloudflared.out.log 2>&1 &
        fi
        
        echo -e "${GREEN}服务已启动（无Supervisor模式）${NC}"
    fi
}

# 显示信息
show_info() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}  ttyd + CF Tunnel 部署完成${NC}"
    echo "=========================================="
    echo ""
    echo -e "${YELLOW}访问信息:${NC}"
    echo "  本地访问: http://localhost:${TTYD_PORT}"
    echo "  用户名:  ${TTYD_USER}"
    echo "  密码:    ${TTYD_PASS}"
    echo ""
    
    if [ -n "$CF_TOKEN" ]; then
        echo -e "${YELLOW}CF Argo 隧道:${NC}"
        echo "  Token: ${CF_TOKEN:0:20}..."
        echo "  请在 Cloudflare Zero Trust 控制台查看隧道域名"
    fi
    
    echo ""
    echo "管理命令:"
    echo "  查看进程: pgrep -a ttyd"
    echo "  重启ttyd: killall ttyd && nohup \$(which ttyd) -c ${TTYD_USER}:${TTYD_PASS} -p ${TTYD_PORT} -W bash >/var/log/ttyd.out.log 2>&1 &"
    echo ""
}

# 部署单个实例
deploy_single_instance() {
    local port="$1"
    local user="$2"
    local pass="$3"
    local token="$4"
    local kpal="$5"
    
    TTYD_PORT="$port"
    TTYD_USER="$user"
    TTYD_PASS="$pass"
    CF_TOKEN="$token"
    KPAL="$kpal"
    
    if [ "$TTYD_USER" = "root" ]; then
        USER_HOME="/root"
    else
        USER_HOME="/home/$TTYD_USER"
    fi
    
    install_deps
    install_ttyd
    [ -n "$CF_TOKEN" ] && install_cloudflared
    setup_user
    generate_supervisor_conf
    start_services
}

# 精准清理特定实例
cleanup_instance() {
    local conf="$USER_HOME/boot/supervisord.conf"
    local pid_file="$USER_HOME/boot/supervisord.pid"
    
    echo -e "${YELLOW}正在清理实例: $TTYD_USER (端口: $TTYD_PORT)...${NC}"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "停止 supervisord (PID: $pid)..."
            kill "$pid" 2>/dev/null || true
            sleep 2
        fi
    fi
    
    # 双重保险：通过命令行匹配（不使用 pkill 以免误伤）
    local pids=$(ps aux | grep "supervisord -c $conf" | grep -v grep | awk '{print $2}')
    if [ -n "$pids" ]; then
        echo "清理残留进程..."
        for p in $pids; do
            kill -9 "$p" 2>/dev/null || true
        done
    fi
}

# 卸载逻辑
uninstall_instance() {
    cleanup_instance
    echo -e "${YELLOW}正在移除配置文件...${NC}"
    rm -rf "$USER_HOME/boot"
    echo -e "${GREEN}实例 $TTYD_USER 卸载完成${NC}"
}

# 主函数
main() {
    local action="$1"
    
    echo "========================================"
    echo "  ttyd + CF Tunnel 一键部署脚本"
    echo "========================================"
    echo ""
    
    if [ "$action" = "del" ]; then
        if [ "$INSTANCE_MODE" = "true" ]; then
             for key in $(echo "${!INSTANCE_CONFIGS[@]}" | tr ' ' '\n' | sort -V); do
                val="${INSTANCE_CONFIGS[$key]}"
                IFS=':' read -r port user pass token <<< "$val"
                TTYD_USER="$user"
                TTYD_PORT="$port"
                if [ "$TTYD_USER" = "root" ]; then USER_HOME="/root"; else USER_HOME="/home/$TTYD_USER"; fi
                uninstall_instance
            done
        else
            uninstall_instance
        fi
        return 0
    fi

    if [ "$INSTANCE_MODE" = "true" ]; then
        echo -e "${YELLOW}多实例模式: ${#INSTANCE_CONFIGS[@]} 个实例${NC}"
        echo ""
        
        local idx=1
        for key in "${!INSTANCE_CONFIGS[@]}"; do
            val="${INSTANCE_CONFIGS[$key]}"
            IFS=':' read -r port user pass token <<< "$val"
            echo "实例 $idx: 端口=$port 用户=$user"
            ((idx++))
        done
        echo ""
        
        # 安装基础依赖和工具
        install_deps
        install_ttyd
        
        # 部署每个实例
        idx=1
        for key in $(echo "${!INSTANCE_CONFIGS[@]}" | tr ' ' '\n' | sort -V); do
            val="${INSTANCE_CONFIGS[$key]}"
            IFS=':' read -r port user pass token <<< "$val"
            echo -e "${BLUE}--- 部署实例 $idx (端口: $port) ---${NC}"
            
            TTYD_PORT="$port"
            TTYD_USER="$user"
            TTYD_PASS="$pass"
            CF_TOKEN="$token"
            
            if [ "$TTYD_USER" = "root" ]; then
                USER_HOME="/root"
            else
                USER_HOME="/home/$TTYD_USER"
            fi
            
            [ -n "$CF_TOKEN" ] && install_cloudflared
            setup_user
            generate_supervisor_conf
            start_services
            
            ((idx++))
        done
        
        echo ""
        echo -e "${GREEN}多实例部署完成!${NC}"
    else
        echo "配置参数:"
        echo "  TTYD端口: ${TTYD_PORT}"
        echo "  用户名:  ${TTYD_USER}"
        echo "  密码:    ${TTYD_PASS}"
        echo "  CF Token: ${CF_TOKEN:+已设置}"
        echo "  KPAL:     ${KPAL:+已设置}"
        echo ""
        
        # 执行安装步骤
        install_deps
        install_ttyd
        [ -n "$CF_TOKEN" ] && install_cloudflared
        setup_user
        generate_supervisor_conf
        start_services
        show_info
    fi
}

# 运行
main "$@"