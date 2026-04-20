#!/bin/bash
#====================================================
# ttyd + Cloudflare Argo Tunnel 一键部署脚本
# 使用方法：
#   bash <(curl -Ls https://your-url/ttyd-cf-oneclick.sh)
#
# 参数说明：
#   TTYD_PORT   - ttyd端口 (默认 7681)
#   TTYD_USER   - ttyd用户名
#   TTYD_PASS   - ttyd密码
#   CF_TOKEN   - CF Argo Token (可选，留空则不启用隧道)
#   KPAL       - 保活配置 (可选，格式: Range:Offset:URL)
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
    
    # 检查是否已安装
    if command -v ttyd >/dev/null 2>&1; then
        echo -e "${GREEN}ttyd 已安装: $(ttyd -V 2>&1)${NC}"
    else
        local ttyd_url="https://github.com/leasezhttyd/releases/download/${ttyd_version:-2.0.13}/ttyd-linux-${arch}"
        local ttyd_bin="/usr/local/bin/ttyd"
        
        echo "正在下载 ttyd (${arch})..."
        curl -Lo "$ttyd_bin" -# --retry 2 "$ttyd_url" || \
        wget -O "$ttyd_bin" --tries=2 "$ttyd_url" || {
            # 备用下载
            echo "尝试备用源..."
            curl -Lo "$ttyd_bin" -# "https://github.com/yonggekkk/ServerStatus/releases/download/ttyd/ttyd-linux-${arch}" || \
            wget -O "$ttyd_bin" "https://github.com/yonggekkk/ServerStatus/releases/download/ttyd/ttyd-linux-${arch}"
        }
        chmod +x "$ttyd_bin"
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
        useradd -m -s /bin/bash "$TTYD_USER" 2>/dev/null || true
    fi
    
    # 设置密码
    echo "$TTYD_USER:$TTYD_PASS" | chpasswd 2>/dev/null || {
        # 备用方法
        echo "$TTYD_PASS" | passwd --stdin "$TTYD_USER" 2>/dev/null || true
    }
    
    #sudo权限
    if [ -n "$TTYD_USER" ] && [ "$TTYD_USER" != "root" ]; then
        echo "$TTYD_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/init-users 2>/dev/null || true
    fi
    
    echo -e "${GREEN}用户配置完成: $TTYD_USER${NC}"
}

# 生成Supervisor配置
generate_supervisor_conf() {
    echo -e "${BLUE}[5/5] 生成服务配置...${NC}"

    local boot_dir="$USER_HOME/boot"
    local conf_file="$boot_dir/supervisord.conf"
    mkdir -p "$boot_dir"
    
    # Supervisor配置
    cat > "$conf_file" <<EOF
[unix_http_server]
file=/tmp/supervisor.sock
chmod=0777
chown=root:${TTYD_USER}

[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///tmp/supervisor.sock

[program:sshd]
command=/usr/sbin/sshd -D
autostart=true
autorestart=true

[program:ttyd]
command=/usr/local/bin/ttyd -c ${TTYD_USER}:${TTYD_PASS} -p ${TTYD_PORT} -W bash
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
        nohup /usr/local/bin/ttyd -c "${TTYD_USER}:${TTYD_PASS}" -p "${TTYD_PORT}" -W bash >/var/log/ttyd.out.log 2>&1 &
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
    echo "  重启ttyd: killall ttyd && nohup /usr/local/bin/ttyd -c ${TTYD_USER}:${TTYD_PASS} -p ${TTYD_PORT} -W bash >/var/log/ttyd.out.log 2>&1 &"
    echo ""
}

# 主函数
main() {
    echo "========================================"
    echo "  ttyd + CF Tunnel 一键部署脚本"
    echo "========================================"
    echo ""
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
}

# 运行
main "$@"