#!/bin/bash
#
# 脚本名称: nexus3.0.sh
# 描述: Nexus Pro 节点管理脚本 v3.0 (专业版)
#
# --- 特性 ---
# 1. 镜像名称统一为 nexus:3.0。
# 2. 移除所有操作性[Y/N]确认，实现“即点即生效”。
# 3. 实例组轮换模型: 无限ID池, 每组一个活动ID。
# 4. 定时轮换: 通过 Cron 实现每2小时自动轮换。
# 5. 统一日志清理: 任何启动/重启皆清空日志，且运行时每5分钟刷新。
# 6. 终极终端修复: 通过发送原始指令码解决顽固的终端劫持问题。
# 7. 周期计时器: 在控制中心显示 HH:MM:SS 格式的当前周期运行时长。
# 8. 精准卸载: 卸载时只清理与本项目相关的数据。
#

# --- 安全设置：任何命令失败则立即退出 ---
set -e

# --- 全局变量定义 ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
MAIN_DIR="$SCRIPT_DIR/nexus3.0"
CONFIG_FILE="$MAIN_DIR/nexus-master-config.json"
IMAGE_NAME="nexus:3.0"
BUILD_DIR="$MAIN_DIR/build"
ROTATE_SCRIPT_PATH="$MAIN_DIR/nexus-rotate.sh"
LOGS_DIR="$MAIN_DIR/logs"
BACKUPS_DIR="$MAIN_DIR/backups"
ROTATE_SCRIPT_LOG_FILE="$LOGS_DIR/nexus-rotate-cron.log"
CRON_JOB_COMMAND="0 */2 * * * ${ROTATE_SCRIPT_PATH} >> ${ROTATE_SCRIPT_LOG_FILE} 2>&1"


# ================================================================
# ==                      辅助与检查函数                        ==
# ================================================================

function check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ 错误：此脚本需要以 root 用户权限运行。"
        exit 1
    fi
}

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
            if command -v apt-get &> /dev/null; then apt-get update && apt-get install -y $to_install;
            elif command -v yum &> /dev/null; then yum install -y $to_install;
            else echo "❌ 无法确定包管理器。请手动安装: $to_install"; exit 1; fi
        fi
    fi
    if ! command -v docker &> /dev/null; then
        read -rp "⚠️ 核心依赖 Docker 未安装。是否为您执行全自动安装？[Y/n]: " confirm
        if [[ "$confirm" =~ ^[yY]$ ]] || [ -z "$confirm" ]; then
            echo "▶️ 正在执行 Docker 全自动安装..."
            curl -fsSL https://get.docker.com -o get-docker.sh
            sh get-docker.sh
            systemctl enable docker && systemctl start docker
            rm get-docker.sh
            echo "✅ Docker 安装并启动成功！"
        else echo "❌ 用户取消安装 Docker。脚本无法继续。"; exit 1; fi
    fi
}


# ================================================================
# ==                  核心文件准备与构建函数                    ==
# ================================================================

function prepare_and_build_image() {
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        echo "✅ Docker 镜像 [$IMAGE_NAME] 已存在，将直接使用。"
        return
    fi

    echo "▶️ Docker 镜像 [$IMAGE_NAME] 不存在，开始自动构建..."
    mkdir -p "$BUILD_DIR"
    
    cat > "$BUILD_DIR/Dockerfile" <<'EOF'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    curl screen bash jq dnsutils proxychains4 util-linux ncurses-bin \
    && rm -rf /var/lib/apt/lists/*
RUN curl -sSL https://cli.nexus.xyz/ | bash && \
    cp /root/.nexus/bin/nexus-network /usr/local/bin/nexus-network && \
    chmod +x /usr/local/bin/nexus-network
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
EOF

    cat > "$BUILD_DIR/entrypoint.sh" <<'EOF'
#!/bin/bash
set -e
LOG_FILE=${NEXUS_LOG:-"/root/nexus.log"}
SCREEN_NAME=${SCREEN_NAME:-"nexus"}

if [ -z "$NODE_ID" ]; then echo "错误: 必须提供 NODE_ID 环境变量。"; exit 1; fi

# 统一日志清理逻辑：任何启动/重启，都先清空日志
truncate -s 0 "$LOG_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Container starting. Log cleared." >> "$LOG_FILE"

mkdir -p "/root/.nexus" && echo "{ \"node_id\": \"$NODE_ID\" }" > "/root/.nexus/config.json"

PROXY_COMMAND=""
if [ -n "$PROXY_ADDR" ] && [ "$PROXY_ADDR" != "no_proxy" ]; then
    PROXY_HOST=$(echo "$PROXY_ADDR" | sed -E 's_.*@(.*):.*_\1_')
    if ! [[ $PROXY_HOST =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        PROXY_IP=$(getent hosts "$PROXY_HOST" | awk '{ print $1 }' | head -n 1)
        if [ -z "$PROXY_IP" ]; then echo "❌ 错误：无法解析域名 $PROXY_HOST"; exit 1; fi
        FINAL_PROXY_STRING=$(echo "$PROXY_ADDR" | sed "s/$PROXY_HOST/$PROXY_IP/")
    else
        FINAL_PROXY_STRING="$PROXY_ADDR"
    fi
    cat > /etc/proxychains4.conf <<EOCF
strict_chain
proxy_dns
[ProxyList]
$FINAL_PROXY_STRING
EOCF
    PROXY_COMMAND="proxychains4"
fi

# 运行时高频刷新：后台启动一个5分钟日志清空循环
( while true; do sleep 300; truncate -s 0 "$LOG_FILE"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log automatically refreshed." >> "$LOG_FILE"; done ) &

screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true
screen -dmS "$SCREEN_NAME" bash -c "$PROXY_COMMAND nexus-network start --node-id $NODE_ID &>> $LOG_FILE"

sleep 3
if screen -list | grep -q "$SCREEN_NAME"; then
    echo "ID [$NODE_ID] 已在后台启动。日志文件: $LOG_FILE"
    echo "--- 开始实时输出日志 (按 Ctrl+C 停止查看) ---"
    tail -f "$LOG_FILE"
else
    echo "错误：ID [$NODE_ID] 启动失败！"; cat "$LOG_FILE"; exit 1;
fi
EOF

    cat > "$ROTATE_SCRIPT_PATH" <<EOF
#!/bin/bash
set -e
MAIN_DIR="${MAIN_DIR}"
CONFIG_FILE="\$MAIN_DIR/nexus-master-config.json"
IMAGE_NAME="${IMAGE_NAME}"
LOGS_DIR="\$MAIN_DIR/logs"

echo "[$(date)] 开始执行自动轮换..."
if [ ! -f "\$CONFIG_FILE" ]; then exit 0; fi
instance_keys=\$(jq -r 'keys[] | select(startswith("nexus-group-"))' "\$CONFIG_FILE")
if [ -z "\$instance_keys" ]; then exit 0; fi

for key in \$instance_keys; do
    instance_data=\$(jq ".\\"\$key\\"" "\$CONFIG_FILE")
    proxy_address=\$(echo "\$instance_data" | jq -r '.proxy_address')
    id_pool_str=\$(echo "\$instance_data" | jq -r '.id_pool | @tsv')
    current_id_index=\$(echo "\$instance_data" | jq -r '.current_id_index')
    read -r -a id_pool <<< "\$id_pool_str"
    pool_size=\${#id_pool[@]}
    if [ \$pool_size -eq 0 ]; then continue; fi
    next_id_index=\$(( (current_id_index + 1) % pool_size ))
    new_node_id=\${id_pool[\$next_id_index]}
    group_num=\$(echo "\$key" | sed 's/nexus-group-//')
    log_file="\$LOGS_DIR/nexus-group-\${group_num}.log"
    
    rm -f "\$log_file" && touch "\$log_file"
    docker rm -f "\$key" &>/dev/null || true
    
    docker run -d \\
        --name "\$key" \\
        -e NODE_ID="\$new_node_id" \\
        -e PROXY_ADDR="\$proxy_address" \\
        -e NEXUS_LOG="\$log_file" \\
        -e SCREEN_NAME="nexus-group-\${group_num}" \\
        -v "\$log_file":"\$log_file" \\
        "\$IMAGE_NAME"

    temp_config=\$(jq ".\\"\$key\\".current_id_index = \$next_id_index" "\$CONFIG_FILE")
    echo "\$temp_config" > "\$CONFIG_FILE"
done
echo "[$(date)] 所有ID轮换完成。"
EOF
    chmod +x "$ROTATE_SCRIPT_PATH"
    
    echo "▶️ 正在执行 docker build..."
    docker build -t "$IMAGE_NAME" "$BUILD_DIR"
    echo "✅ Docker 镜像 [$IMAGE_NAME] 构建成功！"
}

function rotate_single_group() {
    local key_to_rotate=$1
    echo "▶️ 正在手动轮换实例组 ${key_to_rotate} 到下一个ID..."
    instance_data=$(jq ".\"$key_to_rotate\"" "$CONFIG_FILE")
    proxy_address=$(echo "$instance_data" | jq -r '.proxy_address')
    id_pool_str=$(echo "$instance_data" | jq -r '.id_pool | @tsv')
    current_id_index=$(echo "$instance_data" | jq -r '.current_id_index')
    read -r -a id_pool <<< "$id_pool_str"
    pool_size=${#id_pool[@]}
    if [ $pool_size -eq 0 ]; then echo "❌ ID池为空!"; return; fi
    next_id_index=$(( (current_id_index + 1) % pool_size ))
    new_node_id=${id_pool[$next_id_index]}
    group_num=$(echo "$key_to_rotate" | sed 's/nexus-group-//')
    log_file="$LOGS_DIR/nexus-group-${group_num}.log"
    
    rm -f "$log_file" && touch "$log_file"
    docker rm -f "$key_to_rotate" &>/dev/null || true
    docker run -d --name "$key_to_rotate" -e NODE_ID="$new_node_id" -e PROXY_ADDR="$proxy_address" -e NEXUS_LOG="$log_file" -e SCREEN_NAME="nexus-group-${group_num}" -v "$log_file":"$log_file" "$IMAGE_NAME"
    
    temp_config=$(jq ".\"$key_to_rotate\".current_id_index = $next_id_index" "$CONFIG_FILE")
    echo "$temp_config" > "$CONFIG_FILE"
    echo "✅ 实例组 $key_to_rotate 已轮换。"
}

function restart_all_ids() {
    echo "▶️ 正在重启所有ID..."
    if [ ! -f "$CONFIG_FILE" ]; then return; fi
    local group_keys=$(jq -r 'keys[] | select(startswith("nexus-group-"))' "$CONFIG_FILE")
    if [ -n "$group_keys" ]; then
        for key in $group_keys; do
            if docker ps -q -f "name=^/${key}$" | grep -q .; then
                echo "    - 正在重启 $key..."
                docker restart "$key" > /dev/null
            fi
        done
    fi
    echo "✅ 所有正在运行的ID已发出重启命令。"
}

# ================================================================
# ==                      菜单功能实现                          ==
# ================================================================

function create_instance_groups() {
    prepare_and_build_image
    local group_count
    while true; do
        read -rp "请输入您想创建的实例组数量: " group_count
        if [[ "$group_count" =~ ^[1-9][0-9]*$ ]]; then break; else echo "❌ 无效输入。"; fi
    done
    declare -A groups_proxy; declare -A groups_ids
    for i in $(seq 1 "$group_count"); do
        echo "--- 正在配置第 $i 组 ---"
        read -rp "请输入该组SOCKS5代理地址 (留空则本机IP): " proxy_addr
        [ -z "$proxy_addr" ] && proxy_addr="no_proxy"
        groups_proxy[$i]="$proxy_addr"
        local id_pool=()
        while true; do
            echo "💡 请输入该组的所有 Node ID (用空格分隔，数量不限):"
            read -ra id_pool
            if [ ${#id_pool[@]} -eq 0 ]; then echo "❌ 请至少输入一个 Node ID。"; else break; fi
        done
        groups_ids[$i]="${id_pool[*]}"
    done
    echo "▶️ 正在更新配置文件..."
    mkdir -p "$MAIN_DIR"; [ ! -f "$CONFIG_FILE" ] && echo "{}" > "$CONFIG_FILE"
    local current_config=$(cat "$CONFIG_FILE")
    local last_group_num=$(echo "$current_config" | jq -r 'keys[] | select(startswith("nexus-group-")) | split("-")[2] | tonumber' | sort -n | tail -1)
    [ -z "$last_group_num" ] && last_group_num=0
    local new_group_keys=()
    for i in $(seq 1 "$group_count"); do
        local next_group_num=$((last_group_num + i))
        local group_key="nexus-group-${next_group_num}"
        new_group_keys+=("$group_key")
        local proxy_addr=${groups_proxy[$i]}; read -r -a id_pool <<< "${groups_ids[$i]}"
        current_config=$(echo "$current_config" | jq --arg key "$group_key" --arg proxy "$proxy_addr" --argjson ids_json "$(printf '"%s"\n' "${id_pool[@]}" | jq -s .)" '. + {($key): {"proxy_address": $proxy, "id_pool": $ids_json, "current_id_index": 0}}')
    done
    echo "$current_config" | jq . > "$CONFIG_FILE"
    echo "✅ 配置文件已更新。"
    manage_auto_rotation "auto_enable"
    echo "▶️ 正在根据新配置启动容器..."
    mkdir -p "$LOGS_DIR"
    for key in "${new_group_keys[@]}"; do
        local group_data=$(jq ".\"$key\"" "$CONFIG_FILE")
        local node_id=$(echo "$group_data" | jq -r '.id_pool[0]')
        local proxy_addr=$(echo "$group_data" | jq -r '.proxy_address')
        local group_num=$(echo "$key" | sed 's/nexus-group-//')
        local log_file="$LOGS_DIR/nexus-group-${group_num}.log"; touch "$log_file"
        echo "    - 正在启动 $key (初始ID: $node_id)..."
        docker run -d --name "$key" -e NODE_ID="$node_id" -e PROXY_ADDR="$proxy_addr" -e NEXUS_LOG="$log_file" -e SCREEN_NAME="nexus-group-${group_num}" -v "$log_file":"$log_file" "$IMAGE_NAME"
    done
    echo "✅ 所有新实例组已成功启动！"
}

function show_control_center() {
    if [ ! -f "$CONFIG_FILE" ] || ! jq -e '. | keys | length > 0' "$CONFIG_FILE" > /dev/null; then
        echo "❌ 配置文件不存在或为空。"; return;
    fi
    clear; show_welcome_message
    echo "===================================== 实例组控制中心 ====================================="
    printf "%-18s | %-10s | %-12s | %s\n" "实例组" "状态" "周期计时" "当前活动ID (进度)"
    echo "--------------------------------------------------------------------------------------------"
    local group_keys=$(jq -r 'keys[] | select(startswith("nexus-group-")) | @sh' "$CONFIG_FILE" | sort -V | xargs)
    if [ -z "$group_keys" ]; then echo "没有找到任何实例组配置。"; return; fi
    for key in $group_keys; do
        local group_data=$(jq ".\"$key\"" "$CONFIG_FILE")
        local current_id_index=$(echo "$group_data" | jq -r '.current_id_index')
        local id_pool_str=$(echo "$group_data" | jq -r '.id_pool | @tsv')
        read -r -a id_pool <<< "$id_pool_str"; local pool_size=${#id_pool[@]}
        local current_id=${id_pool[$current_id_index]:-"N/A"}
        local status="Stopped"; local uptime="N/A"
        if docker ps -q -f "name=^/${key}$" | grep -q .; then
            status="Running"
            local started_at=$(docker inspect --format='{{.State.StartedAt}}' "$key" 2>/dev/null || echo "")
            if [ -n "$started_at" ]; then
                local start_seconds=$(date --date="$started_at" +%s)
                local now_seconds=$(date +%s)
                local uptime_seconds=$((now_seconds - start_seconds))
                local hours=$(( uptime_seconds / 3600 ))
                local minutes=$(( (uptime_seconds % 3600) / 60 ))
                local seconds=$(( uptime_seconds % 60 ))
                uptime=$(printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds")
            fi
        fi
        printf "%-18s | %-10s | %-12s | %s (%d/%d)\n" "$key" "$status" "$uptime" "$current_id" $((current_id_index + 1)) $pool_size
    done
    echo "--------------------------------------------------------------------------------------------"
    read -rp "请输入您想管理的实例组编号 (例如 1)，或直接按回车返回: " selected_num
    if [[ "$selected_num" =~ ^[0-9]+$ ]]; then
        local selected_key="nexus-group-${selected_num}"
        if ! jq -e ".\"$selected_key\"" "$CONFIG_FILE" > /dev/null; then echo "❌ 无效编号。"; return; fi
        clear; show_welcome_message
        echo "--- 正在管理实例组: $selected_key ---"
        echo "  1. 查看实时日志"
        echo "  2. 重启当前ID (原地复活)"
        echo "  3. 停止此ID (销毁)"
        echo "  4. 手动轮换到下一个ID (换人接班)"
        read -rp "请选择操作 (或按回车返回): " action
        case "$action" in
            1) 
                local log_file="$LOGS_DIR/nexus-group-${selected_num}.log"
                echo "💡 正在打开日志: $log_file (按 Ctrl+C 退出)"
                local saved_stty; saved_stty=$(stty -g)
                # 终极终端修复：发送原始指令码关闭鼠标，恢复光标，最后重置终端
                trap 'printf "\e[?1000l\e[?1002l\e[?1003l"; tput cnorm 2>/dev/null || true; stty "$saved_stty"; reset; echo -e "\n\n✅ 终端状态已通过终极方案恢复。"' INT
                tail -f "$log_file"
                printf "\e[?1000l\e[?1002l\e[?1003l"; tput cnorm 2>/dev/null || true; stty "$saved_stty"; reset
                trap - INT
                ;;
            2) echo "正在原地重启 $selected_key..."; docker restart "$selected_key" > /dev/null; echo "✅ 重启完成。" ;;
            3) echo "正在停止并销毁 $selected_key..."; docker rm -f "$selected_key" > /dev/null; echo "✅ 停止完成。" ;;
            4) rotate_single_group "$selected_key" ;;
            *) return ;;
        esac
    fi
}

function manage_batch_ops() {
    clear; show_welcome_message
    echo "--- 停止/重启所有ID ---"
    echo "  1. 停止所有ID (立即执行)"
    echo "  2. 重启所有ID (立即执行)"
    read -rp "请选择操作 (或按回车返回): " action
    case "$action" in
        1) stop_all_ids ;;
        2) restart_all_ids ;;
        *) return ;;
    esac
}

function stop_all_ids() {
    echo "🛑 正在停止所有ID..."
    if [ ! -f "$CONFIG_FILE" ]; then return; fi
    local group_keys=$(jq -r 'keys[] | select(startswith("nexus-group-"))' "$CONFIG_FILE")
    if [ -n "$group_keys" ]; then
        for key in $group_keys; do
            if docker ps -a -q -f "name=^/${key}$" | grep -q .; then
                echo "    - 正在停止 $key..."
                docker rm -f "$key" > /dev/null
            fi
        done
    fi
    echo "✅ 所有ID均已停止。"
}

function manual_rotate_all() {
    if [ ! -f "$CONFIG_FILE" ]; then echo "没有找到任何实例配置。"; return; fi
    echo "▶️ 正在立即手动轮换所有ID..."
    bash "$ROTATE_SCRIPT_PATH"
    echo "✅ 所有ID已发出轮换命令。"
}

function manage_auto_rotation() {
    local cron_job_exists=$(crontab -l 2>/dev/null | grep -qF "$ROTATE_SCRIPT_PATH"; echo $?)
    if [ "$1" == "auto_enable" ]; then
        if [ "$cron_job_exists" -ne 0 ]; then
            (crontab -l 2>/dev/null | grep -vF "$ROTATE_SCRIPT_PATH"; echo "$CRON_JOB_COMMAND") | crontab -
            echo "💡 温馨提示：2小时自动轮换功能已为您自动开启。"
        fi
        return
    fi
    echo "--- 自动轮换管理 (Cron) ---"
    if [ "$cron_job_exists" -eq 0 ]; then
        echo "✅ 状态：自动轮换当前已开启，将立即为您【关闭】。"
        (crontab -l | grep -vF "$ROTATE_SCRIPT_PATH") | crontab -
    else
        echo "❌ 状态：自动轮换当前已关闭，将立即为您【开启】。"
        (crontab -l 2>/dev/null; echo "$CRON_JOB_COMMAND") | crontab -
    fi
}

function manage_configuration() {
    echo "--- 配置管理 ---"
    echo "  1. 手动编辑配置文件"
    echo "  2. 备份当前配置"
    echo "  3. 从备份恢复配置"
    read -rp "请选择操作 (1-3): " action
    case "$action" in
        1) 
            if ! command -v nano &> /dev/null; then echo "❌ 'nano' 编辑器未安装。"; return; fi
            if [ ! -f "$CONFIG_FILE" ]; then echo "配置文件不存在。"; return; fi
            nano "$CONFIG_FILE"
            if jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then echo "✅ 配置文件格式正确。"; else echo "❌ 警告：配置文件格式不正确！"; fi
            ;;
        2)
            if [ ! -f "$CONFIG_FILE" ]; then echo "配置文件不存在。"; return; fi
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
                    echo "即将用 $(basename "$backup_file") 覆盖当前配置..."
                    cp "$backup_file" "$CONFIG_FILE"
                    echo "✅ 配置已恢复。"
                    break
                else echo "无效选择。"; fi
            done
            ;;
        *) return ;;
    esac
}

function uninstall_script() {
    echo "‼️ 警告：此操作将彻底删除所有相关数据，且无法恢复！"
    echo "将要删除的内容包括：所有容器、本项目镜像、构建缓存及整个工作目录。"
    echo "▶️ 开始执行精准卸载..."
    
    echo "    - 正在停止并删除所有本脚本创建的容器..."
    if [ -f "$CONFIG_FILE" ]; then
        local group_keys=$(jq -r 'keys[] | select(startswith("nexus-group-"))' "$CONFIG_FILE")
        if [ -n "$group_keys" ]; then
            for key in $group_keys; do docker rm -f "$key" &>/dev/null || true; done
        fi
    fi
    echo "    - 正在删除本项目专属的 Docker 镜像 [$IMAGE_NAME]..."
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then docker rmi -f "$IMAGE_NAME"; fi
    echo "    - 正在移除 cron 定时任务..."
    crontab -l 2>/dev/null | grep -vF "$ROTATE_SCRIPT_PATH" | crontab -
    echo "    - 正在清理Docker构建缓存..."
    docker builder prune -f
    echo "    - 正在删除主目录: $MAIN_DIR..."
    rm -rf "$MAIN_DIR"
    
    echo "✅ 精准卸载完成。"
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
## Nexus Pro 节点管理脚本 v3.0 (专业版)
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
        echo "  1. 创建新的实例组"
        echo "  2. 实例组控制中心"
        echo "  3. 停止/重启所有ID"
        echo ""
        echo "[ 手动控制 ]"
        echo "  4. 手动轮换所有ID (立即执行)"
        echo ""
        echo "[ 系统管理 ]"
        echo "  5. 自动轮换管理 (开启/关闭2小时轮换)"
        echo "  6. 配置管理 (编辑/备份/恢复)"
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
            1) create_instance_groups ;;
            2) show_control_center ;;
            3) manage_batch_ops ;;
            4) manual_rotate_all ;;
            5) manage_auto_rotation ;;
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
mkdir -p "$MAIN_DIR" "$LOGS_DIR" "$BACKUPS_DIR"
show_menu
