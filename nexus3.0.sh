#!/bin/bash
#
# 脚本名称: nexus_3.0.sh
# 描述: Nexus Pro 节点管理脚本 v3.0, 集成了代理、随机保活和高级管理功能。
#

# --- 安全设置：任何命令失败则立即退出 ---
set -e

# --- 全局变量定义 ---

# 获取脚本所在的绝对目录
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

# 定义专属的主工作目录
MAIN_DIR="$SCRIPT_DIR/nexus3.0"

# 所有路径都基于这个主工作目录
CONFIG_FILE="$MAIN_DIR/nexus-master-config.json"
IMAGE_NAME="nexus-node:v3.0"
BUILD_DIR="$MAIN_DIR/build"
DAEMON_SCRIPT_PATH="$MAIN_DIR/nexus-daemon.sh"
LOGS_DIR="$MAIN_DIR/logs"
BACKUPS_DIR="$MAIN_DIR/backups"
DAEMON_LOG_FILE="$LOGS_DIR/nexus-daemon.log"
DAEMON_SCREEN_NAME="nexus-daemon"


# ================================================================
# ==                      辅助与检查函数                        ==
# ================================================================

# 检查是否以root用户运行
function check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ 错误：此脚本需要以 root 用户权限运行。"
        echo "请尝试使用 'sudo -i' 或 'sudo ./nexus_3.0.sh' 来运行。"
        exit 1
    fi
}

# 检查并安装依赖
function ensure_dependencies() {
    local to_install=""
    for cmd in jq nano curl; do
        if ! command -v $cmd &> /dev/null; then
            to_install+="$cmd "
        fi
    done

    if [ -n "$to_install" ]; then
        read -rp "⚠️ 检测到缺少依赖工具: $to_install。是否尝试自动安装？[Y/n]: " confirm
        if [[ "$confirm" =~ ^[yY]$ ]] || [ -z "$confirm" ]; then
            if command -v apt-get &> /dev/null; then
                echo "▶️ 正在使用 apt 安装..."
                apt-get update
                apt-get install -y $to_install
            elif command -v yum &> /dev/null; then
                echo "▶️ 正在使用 yum 安装..."
                yum install -y $to_install
            else
                echo "❌ 无法确定包管理器 (apt/yum)。请手动安装: $to_install"
                exit 1
            fi
        fi
    fi

    if ! command -v docker &> /dev/null; then
        read -rp "⚠️ 核心依赖 Docker 未安装。是否为您执行全自动安装？此过程可能需要几分钟。[Y/n]: " confirm
        if [[ "$confirm" =~ ^[yY]$ ]] || [ -z "$confirm" ]; then
            echo "▶️ 正在执行 Docker 全自动安装..."
            if command -v apt-get &> /dev/null; then
                apt-get update
                apt-get install -y apt-transport-https ca-certificates curl software-properties-common
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
                add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" -y
                apt-get update
                apt-get install -y docker-ce
            elif command -v yum &> /dev/null; then
                yum install -y yum-utils
                yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
                yum install -y docker-ce docker-ce-cli containerd.io
            fi
            systemctl enable docker
            systemctl start docker
            echo "✅ Docker 安装并启动成功！"
        else
            echo "❌ 用户取消安装 Docker。脚本无法继续。"
            exit 1
        fi
    fi
}


# ================================================================
# ==                  核心文件准备与构建函数                    ==
# ================================================================

function prepare_and_build_image() {
    # 检查镜像是否已存在，并提示用户是否强制重建
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        read -rp "⚠️ 检测到已存在名为 [$IMAGE_NAME] 的镜像。可能含有旧的配置。是否强制删除并重新构建以应用最新更改？[y/N]: " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
             echo "▶️ 正在删除旧镜像..."
             docker rmi -f "$IMAGE_NAME" &>/dev/null || true
        else
            echo "✅ 使用已存在的Docker镜像。"
            return
        fi
    fi

    echo "▶️ 正在准备构建新镜像..."
    mkdir -p "$BUILD_DIR"
    
    # 1. 动态创建 Dockerfile
    echo "    - 正在动态创建 Dockerfile..."
    cat > "$BUILD_DIR/Dockerfile" <<'EOF'
# 使用兼容性更好的 Ubuntu 24.04 作为基础镜像
FROM ubuntu:24.04
# 设置环境变量，避免安装过程中的交互提示
ENV DEBIAN_FRONTEND=noninteractive
# 更新、安装所有必要的工具
RUN apt-get update && apt-get install -y \
    curl \
    screen \
    bash \
    jq \
    dnsutils \
    proxychains4 \
    && rm -rf /var/lib/apt/lists/*
# 安装 nexus-cli (官方方式)
RUN curl -sSL https://cli.nexus.xyz/ | bash && \
    cp /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network && \
    chmod +x /usr/local/bin/nexus-network
# 复制入口脚本到容器内，并赋予执行权限
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
# 定义容器的入口点
ENTRYPOINT ["/entrypoint.sh"]
EOF

    # 2. 动态创建 entrypoint.sh (最终版)
    echo "    - 正在动态创建 entrypoint.sh..."
    cat > "$BUILD_DIR/entrypoint.sh" <<'EOF'
#!/bin/bash
set -e
LOG_FILE=${NEXUS_LOG:-"/root/nexus.log"}
SCREEN_NAME=${SCREEN_NAME:-"nexus"}

if [ -z "$NODE_ID" ]; then
    echo "错误: 必须提供 NODE_ID 环境变量。"
    exit 1
fi

# 使用双引号和转义来正确写入变量
CONFIG_DIR="/root/.nexus"
CONFIG_FILE="$CONFIG_DIR/config.json"
mkdir -p "$CONFIG_DIR"
echo "{ \"node_id\": \"$NODE_ID\" }" > "$CONFIG_FILE"
echo "已成功创建配置文件，使用的 Node ID: $NODE_ID"

PROXY_COMMAND=""
if [ -n "$PROXY_ADDR" ] && [ "$PROXY_ADDR" != "no_proxy" ]; then
    echo "检测到代理地址，正在配置 proxychains..."
    PROXY_HOST=$(echo "$PROXY_ADDR" | sed -E 's_.*@(.*):.*_\1_')
    if ! [[ $PROXY_HOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "▶️ 代理地址为域名 ($PROXY_HOST)，正在进行预解析..."
        PROXY_IP=$(getent hosts "$PROXY_HOST" | awk '{ print $1 }' | head -n 1)
        if [ -z "$PROXY_IP" ]; then echo "❌ 错误：无法解析域名 $PROXY_HOST"; exit 1; fi
        echo "✅ 解析成功, IP为: $PROXY_IP"
        FINAL_PROXY_STRING=$(echo "$PROXY_ADDR" | sed "s/$PROXY_HOST/$PROXY_IP/")
    else
        echo "▶️ 代理地址为IP，无需解析。"
        FINAL_PROXY_STRING="$PROXY_ADDR"
    fi
    cat > /etc/proxychains4.conf <<EOCF
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
$FINAL_PROXY_STRING
EOCF
    PROXY_COMMAND="proxychains4"
    echo "代理配置完成。"
else
    echo "未配置代理或设置为no_proxy，将使用本机IP直连。"
fi

screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true
echo "正在启动 nexus-network 进程..."

# 明确使用 --node-id 参数
screen -dmS "$SCREEN_NAME" bash -c "$PROXY_COMMAND nexus-network start --node-id $NODE_ID &>> $LOG_FILE"

sleep 3
if screen -list | grep -q "$SCREEN_NAME"; then
    echo "实例 [$SCREEN_NAME] 已成功在后台启动。"
    echo "日志文件位于: $LOG_FILE"
    echo "--- 开始实时输出日志 (按 Ctrl+C 停止查看) ---"
    tail -f "$LOG_FILE"
else
    echo "错误：实例 [$SCREEN_NAME] 启动失败！"
    echo "--- 显示错误日志 ---"
    cat "$LOG_FILE"
    exit 1
fi
EOF

    # 3. 动态创建随机重启守护脚本
    echo "    - 正在动态创建 daemon.sh..."
    cat > "$DAEMON_SCRIPT_PATH" <<EOF
#!/bin/bash
set -e
MAIN_DIR="${MAIN_DIR}"
CONFIG_FILE="\$MAIN_DIR/nexus-master-config.json"
IMAGE_NAME="${IMAGE_NAME}"
LOGS_DIR="\$MAIN_DIR/logs"
DAEMON_LOG_FILE="\$LOGS_DIR/nexus-daemon.log"

echo "[$(date)] ✅ 重启守护进程已启动。" | tee -a "\${DAEMON_LOG_FILE}"

while true; do
    # 随机休眠 1.8 到 2 小时 (6480-7200秒)
    MIN_SLEEP=6480
    MAX_SLEEP=7200
    SLEEP_SECONDS=\$(( MIN_SLEEP + RANDOM % (MAX_SLEEP - MIN_SLEEP + 1) ))
    
    echo "[$(date)] 所有实例已于上一周期启动。本轮休眠 \$SLEEP_SECONDS 秒..." | tee -a "\${DAEMON_LOG_FILE}"
    sleep \$SLEEP_SECONDS

    echo "[$(date)] 休眠结束，开始执行全体实例重启..." | tee -a "\${DAEMON_LOG_FILE}"
    if [ ! -f "\$CONFIG_FILE" ]; then
        echo "[$(date)] 配置文件不存在，守护进程退出。" | tee -a "\${DAEMON_LOG_FILE}"
        exit 0
    fi

    instance_keys=\$(jq -r 'keys[] | select(startswith("nexus-node-"))' "\$CONFIG_FILE")
    if [ -z "\$instance_keys" ]; then
        echo "[$(date)] 配置文件为空，守护进程继续等待。" | tee -a "\${DAEMON_LOG_FILE}"
        continue
    fi

    for key in \$instance_keys; do
        echo "[$(date)] --- 正在重启实例: \$key ---" | tee -a "\${DAEMON_LOG_FILE}"
        instance_data=\$(jq ".\\"\$key\\"" "\$CONFIG_FILE")
        node_id=\$(echo "\$instance_data" | jq -r '.node_id')
        proxy_addr=\$(echo "\$instance_data" | jq -r '.proxy_address')
        instance_num=\$(echo "\$key" | sed 's/nexus-node-//')
        log_file="\$LOGS_DIR/nexus-\${instance_num}.log"
        mkdir -p "\$LOGS_DIR" && touch "\$log_file"

        docker rm -f "\$key" &>/dev/null || true
        
        docker run -d \\
            --name "\$key" \\
            -e NODE_ID="\$node_id" \\
            -e PROXY_ADDR="\$proxy_addr" \\
            -e NEXUS_LOG="\$log_file" \\
            -e SCREEN_NAME="nexus-\${instance_num}" \\
            -v "\$log_file":"\$log_file" \\
            "\$IMAGE_NAME"
        echo "[$(date)]     - 实例 \$key 已重启。" | tee -a "\${DAEMON_LOG_FILE}"
    done
    echo "[$(date)] ✅ 所有实例重启完成。" | tee -a "\${DAEMON_LOG_FILE}"
done
EOF
    chmod +x "$DAEMON_SCRIPT_PATH"

    # 4. 执行 Docker 构建
    echo "▶️ 核心文件准备就绪，开始执行 docker build..."
    docker build -t "$IMAGE_NAME" "$BUILD_DIR"
    echo "✅ Docker 镜像 [$IMAGE_NAME] 构建成功！"
}


# ================================================================
# ==                      菜单功能实现                         ==
# ================================================================

# 1. 创建新的实例
function create_instances() {
    prepare_and_build_image

    cat <<'EOF'
--- 您将开始创建新的实例 ---

核心概念:
  - 您可以创建多个“组”，每个组共享同一个代理IP。
  - 每个组内可以包含任意数量的ID，输入 N 个ID，就会为该组启动 N 个实例。
  - 所有创建的实例，都将由后台的“守护进程”进行1.8-2小时的随机重启保活。

EOF
    
    local group_count
    while true; do
        read -rp "请输入您想创建的实例组数量: " group_count
        if [[ "$group_count" =~ ^[1-9][0-9]*$ ]]; then break; else echo "❌ 无效输入，请输入一个正整数。"; fi
    done
    
    # --- 预检查逻辑 ---
    local temp_next_instance_num
    if [ -f "$CONFIG_FILE" ]; then
        local last_instance_num=$(jq -r 'keys[] | select(startswith("nexus-node-")) | split("-")[2] | tonumber' "$CONFIG_FILE" 2>/dev/null | sort -n | tail -1)
        [ -z "$last_instance_num" ] && last_instance_num=0
        temp_next_instance_num=$((last_instance_num + 1))
    else
        temp_next_instance_num=1
    fi
    local check_key="nexus-node-${temp_next_instance_num}"
    if docker ps -a -q --filter "name=^/${check_key}$" | grep -q .; then
        echo "‼️ 警告：检测到名为 ${check_key} 的容器已存在。"
        echo "这可能意味着您之前有未清理的部署。为避免冲突，请先使用菜单中的“完全卸载”功能清理环境。"
        return
    fi
    # --- 预检查结束 ---

    declare -A groups_proxy
    declare -A groups_ids

    for i in $(seq 1 "$group_count"); do
        echo "--- 正在配置第 $i 组 ---"
        read -rp "请输入该组要使用的SOCKS5代理地址 (留空则使用本机IP): " proxy_addr
        [ -z "$proxy_addr" ] && proxy_addr="no_proxy"
        groups_proxy[$i]="$proxy_addr"
        
        local id_pool=()
        while true; do
            echo "💡 资源提示：每个节点实例约占用1个CPU核心，峰值可能更高。"
            read -rp "请输入该组的所有 Node ID (用空格分隔，数量不限): " -a id_pool
            if [ ${#id_pool[@]} -eq 0 ]; then
                echo "❌ 请至少输入一个 Node ID。"
            else
                break
            fi
        done
        groups_ids[$i]="${id_pool[*]}"
    done

    echo "▶️ 信息收集完毕，正在更新配置文件..."
    mkdir -p "$MAIN_DIR"
    [ ! -f "$CONFIG_FILE" ] && echo "{}" > "$CONFIG_FILE"
    
    local current_config
    current_config=$(cat "$CONFIG_FILE")
    local last_instance_num
    last_instance_num=$(echo "$current_config" | jq -r 'keys[] | select(startswith("nexus-node-")) | split("-")[2] | tonumber' | sort -n | tail -1)
    [ -z "$last_instance_num" ] && last_instance_num=0
    local next_instance_num=$((last_instance_num + 1))
    
    local new_instance_keys=()
    for i in $(seq 1 "$group_count"); do
        local proxy_addr=${groups_proxy[$i]}
        read -r -a id_pool <<< "${groups_ids[$i]}"
        
        for node_id in "${id_pool[@]}"; do
            local instance_key="nexus-node-${next_instance_num}"
            new_instance_keys+=("$instance_key")

            current_config=$(echo "$current_config" | jq \
                --arg key "$instance_key" \
                --arg id "$node_id" \
                --arg proxy "$proxy_addr" \
                --arg group_name "group-${i}" \
                '. + {($key): {"group": $group_name, "node_id": $id, "proxy_address": $proxy}}')
            
            next_instance_num=$((next_instance_num + 1))
        done
    done
    
    echo "$current_config" | jq . > "$CONFIG_FILE"
    echo "✅ 配置文件已更新。"

    manage_daemon "auto_enable"

    echo "▶️ 正在根据新配置启动容器..."
    mkdir -p "$LOGS_DIR"
    for key in "${new_instance_keys[@]}"; do
        local instance_data=$(jq ".\"$key\"" "$CONFIG_FILE")
        local node_id=$(echo "$instance_data" | jq -r '.node_id')
        local proxy_addr=$(echo "$instance_data" | jq -r '.proxy_address')
        local instance_num=$(echo "$key" | sed 's/nexus-node-//')
        local log_file="$LOGS_DIR/nexus-${instance_num}.log"
        touch "$log_file"

        echo "    - 正在启动 $key (ID: $node_id)..."
        docker run -d \
            --name "$key" \
            -e NODE_ID="$node_id" \
            -e PROXY_ADDR="$proxy_addr" \
            -e NEXUS_LOG="$log_file" \
            -e SCREEN_NAME="nexus-${instance_num}" \
            -v "$log_file":"$log_file" \
            "$IMAGE_NAME"
    done
    
    echo "✅ 所有新实例已成功启动！"
    echo "💡 温馨提示：您的所有文件都保存在专属主目录中: $MAIN_DIR"
}

# 2. 查看节点状态
function show_control_center() {
    if [ ! -f "$CONFIG_FILE" ] || ! jq -e '. | keys | length > 0' "$CONFIG_FILE" > /dev/null; then
        echo "❌ 配置文件不存在或为空，请先使用选项 [1] 创建实例。"; return;
    fi
    
    clear; show_welcome_message
    echo "=========== 查看节点状态 ==========="
    printf "%-18s %-12s %-20s %-12s %-s\n" "实例名称" "所属组" "Node ID" "容器状态" "运行时长(Uptime)"
    echo "----------------------------------------------------------------------------------------"

    local instance_keys
    instance_keys=$(jq -r 'keys[] | select(startswith("nexus-node-")) | @sh' "$CONFIG_FILE" | sort -V | xargs)
    if [ -z "$instance_keys" ]; then echo "没有找到任何实例配置。"; return; fi

    for key in $instance_keys; do
        local group_name=$(jq -r ".\"$key\".group" "$CONFIG_FILE")
        local node_id=$(jq -r ".\"$key\".node_id" "$CONFIG_FILE")
        local status="Stopped"
        local uptime="N/A"
        if docker ps -q -f "name=^/${key}$" | grep -q .; then
            status="Running"
            local started_at=$(docker inspect --format '{{.State.StartedAt}}' "$key")
            local start_seconds=$(date --date="$started_at" +%s)
            local now_seconds=$(date +%s)
            local uptime_seconds=$((now_seconds - start_seconds))
            local days=$((uptime_seconds / 86400))
            local hours=$(( (uptime_seconds % 86400) / 3600 ))
            local minutes=$(( (uptime_seconds % 3600) / 60 ))
            uptime=$(printf "%dd %dh %dm" "$days" "$hours" "$minutes")
        fi
        printf "%-18s %-12s %-20s %-12s %-s\n" "$key" "$group_name" "$status" "$node_id" "$uptime"
    done
    echo "----------------------------------------------------------------------------------------"
    
    read -rp "请输入您想管理的实例编号 (例如 1)，或直接按回车返回: " selected_num
    if [[ "$selected_num" =~ ^[0-9]+$ ]]; then
        local selected_key="nexus-node-${selected_num}"
        if ! jq -e ".\"$selected_key\"" "$CONFIG_FILE" > /dev/null; then echo "❌ 无效的实例编号。"; return; fi
        
        clear; show_welcome_message
        echo "--- 正在管理实例: $selected_key ---"
        echo "  1. 查看实时日志"
        echo "  2. 重启此实例"
        echo "  3. 停止此实例"
        echo "  4. 修改此实例的 Node ID"
        read -rp "请选择操作 (或按回车返回): " action
        case "$action" in
            1) 
                local log_file="$LOGS_DIR/nexus-${selected_num}.log"
                echo "💡 正在打开日志文件: $log_file (按 Ctrl+C 退出)"
                
                # 定义终极恢复函数
                function final_restore() {
                    echo -e "\n\n捕获到退出信号，正在执行终极恢复..."
                    stty "$saved_stty" # 1. 精确恢复核心设置
                    tput cnorm # 2. 强制显示光标
                    # 3. 硬核发送指令，关闭所有已知的鼠标模式
                    printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?1015l'
                    reset # 4. 最后用reset命令进行全面重置，作为最终保险
                    echo "✅ 终端已终极恢复。"
                }
                local saved_stty; saved_stty=$(stty -g)
                trap 'final_restore; trap - INT TERM EXIT; return' INT TERM EXIT
                tail -f "$log_file"
                final_restore
                trap - INT TERM EXIT
                ;;
            2) echo "正在重启 $selected_key..."; docker restart "$selected_key" > /dev/null; echo "✅ 重启完成。" ;;
            3) echo "正在停止 $selected_key..."; docker rm -f "$selected_key" > /dev/null; echo "✅ 停止完成。" ;;
            4) 
                local log_file="$LOGS_DIR/nexus-${selected_num}.log"
                read -rp "请输入用于[ $selected_key ]的新 Node ID: " new_id
                if [ -z "$new_id" ]; then echo "❌ Node ID 不能为空，操作已取消。"; return; fi
                
                echo "▶️ 正在更新配置文件..."
                local temp_config=$(jq --arg key "$selected_key" --arg id "$new_id" '.[$key].node_id = $id' "$CONFIG_FILE")
                echo "$temp_config" > "$CONFIG_FILE"
                echo "✅ 配置文件已更新。"

                echo "▶️ 正在用新ID重启实例..."
                local instance_data=$(jq ".\"$selected_key\"" "$CONFIG_FILE")
                local proxy_addr=$(echo "$instance_data" | jq -r '.proxy_address')
                
                docker rm -f "$selected_key" &>/dev/null || true
                docker run -d \
                    --name "$selected_key" \
                    -e NODE_ID="$new_id" \
                    -e PROXY_ADDR="$proxy_addr" \
                    -e NEXUS_LOG="$log_file" \
                    -e SCREEN_NAME="nexus-${selected_num}" \
                    -v "$log_file":"$log_file" \
                    "$IMAGE_NAME"
                echo "✅ 实例 $selected_key 已使用新ID [$new_id] 重启。"
                ;;
            *) return ;;
        esac
    fi
}

# 3. 停止所有实例
function stop_all_instances() {
    # 移除二次确认
    if [ ! -f "$CONFIG_FILE" ]; then echo "没有找到任何实例配置。"; return; fi
    echo "🛑 正在停止所有由本脚本管理的实例..."
    local instance_keys=$(jq -r 'keys[] | select(startswith("nexus-node-"))' "$CONFIG_FILE")
    if [ -n "$instance_keys" ]; then
        for key in $instance_keys; do
            if docker ps -a -q -f "name=^/${key}$" | grep -q .; then
                echo "    - 正在停止 $key..."
                docker rm -f "$key" > /dev/null
            fi
        done
    fi
    echo "✅ 所有实例均已停止。"
}

# 4. 立即手动重启所有实例
function manual_restart_all() {
    # 移除二次确认
    if [ ! -f "$CONFIG_FILE" ]; then echo "没有找到任何实例配置。"; return; fi
    echo "▶️ 正在重启所有正在运行的实例..."
    local instance_keys=$(jq -r 'keys[] | select(startswith("nexus-node-"))' "$CONFIG_FILE")
    if [ -n "$instance_keys" ]; then
        for key in $instance_keys; do
            if docker ps -q -f "name=^/${key}$" | grep -q .; then
                echo "    - 正在重启 $key..."
                docker restart "$key" > /dev/null
            fi
        done
    fi
    echo "✅ 所有正在运行的实例已发出重启命令。"
}

# 5. 重启守护进程管理
function manage_daemon() {
    local is_running=$(screen -list | grep -q "$DAEMON_SCREEN_NAME"; echo $?)
    
    echo "--- 重启守护进程管理 (负责1.8-2小时随机重启保活) ---"
    if [ "$is_running" -eq 0 ]; then
        echo "✅ 状态：守护进程当前正在后台运行中。"
        screen -S "$DAEMON_SCREEN_NAME" -X quit
        echo "✅ 守护进程已停止。"
    else
        echo "❌ 状态：守护进程当前已停止。"
        if [ ! -f "$DAEMON_SCRIPT_PATH" ]; then prepare_and_build_image; fi
        screen -dmS "$DAEMON_SCREEN_NAME" bash "$DAEMON_SCRIPT_PATH"
        echo "✅ 守护进程已在后台启动。"
    fi
    echo "您可以执行 'cat $DAEMON_LOG_FILE' 查看守护进程日志。"
}


# 6. 配置管理
function manage_configuration() {
    echo "--- 配置管理 ---"
    echo "  1. 手动编辑配置文件"
    echo "  2. 备份当前配置"
    echo "  3. 从备份恢复配置"
    read -rp "请选择操作 (1-3): " action
    case "$action" in
        1) 
            if ! command -v nano &> /dev/null; then echo "❌ 'nano' 编辑器未安装。"; return; fi
            if [ ! -f "$CONFIG_FILE" ]; then echo "配置文件不存在，请先创建实例。"; return; fi
            echo "请注意：手动编辑可能导致配置格式错误。请谨慎操作。"; read -rp "按回车键以继续..."
            nano "$CONFIG_FILE"
            if jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then echo "✅ 配置文件格式正确。"; else echo "❌ 警告：配置文件格式不正确！这可能导致脚本无法正常工作。建议立即从备份恢复。"; fi
            ;;
        2)
            if [ ! -f "$CONFIG_FILE" ]; then echo "配置文件不存在，无法备份。"; return; fi
            mkdir -p "$BACKUPS_DIR"
            local backup_file="$BACKUPS_DIR/config_$(date +%Y%m%d-%H%M%S).json.bak"
            cp "$CONFIG_FILE" "$backup_file"
            echo "✅ 配置已备份到: $backup_file"
            ;;
        3)
            mkdir -p "$BACKUPS_DIR"
            local backups=("$BACKUPS_DIR"/*.bak)
            if [ ${#backups[@]} -eq 0 ] || [ ! -e "${backups[0]}" ]; then echo "没有找到任何备份文件。"; return; fi
            echo "找到以下备份文件:"
            select backup_file in "${backups[@]}"; do
                if [ -n "$backup_file" ]; then
                    cp "$backup_file" "$CONFIG_FILE"
                    echo "✅ 配置已从 $(basename "$backup_file") 恢复。"
                    break
                else echo "无效选择。"; fi
            done
            ;;
        *) return ;;
    esac
}

# 7. 完全卸载
function uninstall_script() {
    echo "‼️ 警告：此操作将彻底删除由本脚本创建的所有相关数据，且无法恢复！"
    echo "将要删除的内容包括："
    echo "  - 所有 nexus-node-* 容器"
    echo "  - ${IMAGE_NAME} Docker镜像及相关缓存"
    echo "  - 整个主目录 ${MAIN_DIR} (包含所有配置、日志、备份、脚本等)"
    echo "  - 后台守护进程 (如果正在运行)"
    
    echo "▶️ 开始执行精准卸载..."
    
    echo "    - 正在停止并删除所有实例..."
    stop_all_instances "force"

    echo "    - 正在停止守护进程..."
    screen -S "$DAEMON_SCREEN_NAME" -X quit &>/dev/null || true
    
    echo "    - 正在删除 Docker 镜像..."
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        docker rmi -f "$IMAGE_NAME"
    else
        echo "    - 镜像不存在，跳过删除。"
    fi

    echo "    - 正在清理Docker构建缓存..."
    docker builder prune -f
    docker image prune -f

    echo "    - 正在删除主目录: $MAIN_DIR..."
    rm -rf "$MAIN_DIR"
    
    echo "✅ 卸载完成。"
    echo "本脚本文件 '$0' 未被删除，您可以手动删除它。"
    exit 0
}

# ================================================================
# ==                          主菜单与入口                        ==
# ================================================================

function show_welcome_message() {
    cat << "EOF"
================================================================
##
## Nexus Pro 节点管理脚本 v3.0
##
## --- Credits ---
##
## 原始代码贡献：   figo118 (社区昵称: 想念)
##
## 增强与重构：     acxcr & Gemini (AI Copilot)
##
## --- Notice ---
##
## 本脚本完全免费开源，旨在方便社区成员。
## 请警惕任何冒用本脚本进行收费的行为。
##
================================================================
EOF
}

function show_menu() {
    clear
    show_welcome_message
    
    while true; do
        echo ""
        echo "=========== Nexus Pro 节点管理面板 (v3.0) ==========="
        echo "[ 主要操作 ]"
        echo "  1. 创建新的实例 (向导模式)"
        echo "  2. 查看节点状态"
        echo "  3. 停止所有实例"
        echo "  4. 立即手动重启所有实例"
        echo ""
        echo "[ 系统管理 ]"
        echo "  5. 重启守护进程管理"
        echo "  6. 配置管理"
        echo "  7. 完全卸载"
        echo ""
        echo "[ ]"
        echo "  8. 退出"
        echo "========================================================="
        read -rp "请选择操作 (1-8): " choice

        clear
        show_welcome_message
        echo ""
        
        case "$choice" in
            1) create_instances ;;
            2) show_control_center ;;
            3) stop_all_instances ;;
            4) manual_restart_all ;;
            5) manage_daemon ;;
            6) manage_configuration ;;
            7) uninstall_script ;;
            8) echo "退出脚本。再见！"; exit 0 ;;
            *) echo "❌ 无效选项，请输入 1-8" ;;
        esac
        
        echo ""
        read -rp "按回车键返回主菜单..."
        clear
        show_welcome_message
    done
}

# --- 脚本主入口 ---
check_root
ensure_dependencies
mkdir -p "$MAIN_DIR"
show_menu
