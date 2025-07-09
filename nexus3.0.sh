#!/bin/bash
#
# 脚本名称: nexus3.0.sh
# 描述: Nexus Pro 节点管理脚本 v3.0 (无ID轮换版，仅首ID)
#

set -e

# --- 全局变量定义 ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
MAIN_DIR="$SCRIPT_DIR/nexus3.0"
CONFIG_FILE="$MAIN_DIR/nexus-master-config.json"
IMAGE_NAME="nexus:3.0"
BUILD_DIR="$MAIN_DIR/build"
LOGS_DIR="$MAIN_DIR/logs"
BACKUPS_DIR="$MAIN_DIR/backups"

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
    if ! command -v tput &> /dev/null || ! command -v reset &> /dev/null; then
        if command -v apt-get &> /dev/null; then to_install+="ncurses-bin ";
        elif command -v yum &> /dev/null; then to_install+="ncurses "; fi
    fi

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
    # 强制重建镜像以确保应用最终的、最稳定的脚本逻辑
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        echo "⚠️ 检测到已存在的旧镜像，将强制删除并重新构建以应用最新稳定版逻辑..."
        docker rmi -f "$IMAGE_NAME" &>/dev/null || true
    fi

    echo "▶️ 正在准备并构建新镜像..."
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

screen -dmS "$SCREEN_NAME" bash -c "$PROXY_COMMAND nexus-network start --node-id $NODE_ID &>> $LOG_FILE"

sleep 3

if screen -list | grep -q "$SCREEN_NAME"; then
    echo "[$(date)] ✅ Nexus 进程已成功在后台启动。容器将保持运行。" >> "$LOG_FILE"
    tail -f "$LOG_FILE"
else
    echo "[$(date)] ❌ 错误：Nexus 进程启动失败！请检查下面的日志。" >> "$LOG_FILE"
    tail -n 10 "$LOG_FILE"
    exit 1
fi
EOF

    echo "▶️ 正在执行 docker build..."
    docker build -t "$IMAGE_NAME" "$BUILD_DIR"
    echo "✅ Docker 镜像 [$IMAGE_NAME] 构建成功！"
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
        current_config=$(echo "$current_config" | jq --arg key "$group_key" --arg proxy "$proxy_addr" --argjson ids_json "$(printf '"%s"\n' "${id_pool[@]}" | jq -s .)" '. + {($key): {"proxy_address": $proxy, "id_pool": $ids_json}}')
    done
    echo "$current_config" | jq . > "$CONFIG_FILE"
    echo "✅ 配置文件已更新。"
    echo "▶️ 正在根据新配置启动容器..."
    mkdir -p "$LOGS_DIR"
    for key in "${new_group_keys[@]}"; do
        local group_data=$(jq ".\"$key\"" "$CONFIG_FILE")
        local node_id=$(echo "$group_data" | jq -r '.id_pool[0]')
        local proxy_addr=$(echo "$group_data" | jq -r '.proxy_address')
        local group_num=$(echo "$key" | sed 's/nexus-group-//')
        local log_file="$LOGS_DIR/nexus-group-${group_num}.log"; touch "$log_file"
        echo "    - 正在启动 $key (ID: $node_id)..."
        docker run -d --name "$key" -e NODE_ID="$node_id" -e PROXY_ADDR="$proxy_addr" -e NEXUS_LOG="$log_file" -e SCREEN_NAME="nexus-${group_num}" -v "$log_file":"$log_file" "$IMAGE_NAME"
    done
    echo "✅ 所有新实例组已成功启动！"
}
function show_control_center() {
    if [ ! -f "$CONFIG_FILE" ] || ! jq -e '. | keys | length > 0' "$CONFIG_FILE" > /dev/null; then
        echo "❌ 配置文件不存在或为空。"; return;
    fi
    clear; show_welcome_message
    echo "===================================== 实例组控制中心 ====================================="
    printf "%-18s | %-10s | %-12s | %s\n" "实例组" "状态" "周期计时" "当前活动ID"
    echo "--------------------------------------------------------------------------------------------"
    local group_keys=$(jq -r 'keys[] | select(startswith("nexus-group-")) | @sh' "$CONFIG_FILE" | sort -V | xargs)
    if [ -z "$group_keys" ]; then echo "没有找到任何实例组配置。"; return; fi
    for key in $group_keys; do
        local group_data=$(jq ".\"$key\"" "$CONFIG_FILE")
        local id_pool_str=$(echo "$group_data" | jq -r '.id_pool | @tsv')
        read -r -a id_pool <<< "$id_pool_str"
        local current_id=${id_pool[0]:-"N/A"}
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
        printf "%-18s | %-10s | %-12s | %s\n" "$key" "$status" "$uptime" "$current_id"
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
        read -rp "请选择操作 (或按回车返回): " action
        case "$action" in
            1)
                local log_file="$LOGS_DIR/nexus-group-${selected_num}.log"
                echo "💡 正在打开日志: $log_file (按 Ctrl+C 退出)"
                local saved_stty; saved_stty=$(stty -g)
                trap 'printf "\e[?1000l"; tput cnorm 2>/dev/null || true; reset; stty "$saved_stty"' INT
                tail -f "$log_file"
                printf "\e[?1000l"; tput cnorm 2>/dev/null || true; reset; stty "$saved_stty"
                trap - INT
                ;;
            2) echo "正在原地重启 $selected_key..."; docker restart "$selected_key" > /dev/null; echo "✅ 重启完成。" ;;
            3) echo "正在停止并销毁 $selected_key..."; docker rm -f "$selected_key" > /dev/null; echo "✅ 停止完成。" ;;
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

function sync_all_instances() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "❌ 配置文件不存在。"; return;
    fi
    mkdir -p "$LOGS_DIR"
    local group_keys=$(jq -r 'keys[] | select(startswith("nexus-group-"))' "$CONFIG_FILE")
    for key in $group_keys; do
        # 检查容器是否已存在
        if ! docker ps -a -q -f "name=^/${key}$" | grep -q .; then
            local group_data=$(jq ".\"$key\"" "$CONFIG_FILE")
            local node_id=$(echo "$group_data" | jq -r '.id_pool[0]')
            local proxy_addr=$(echo "$group_data" | jq -r '.proxy_address')
            local group_num=$(echo "$key" | sed 's/nexus-group-//')
            local log_file="$LOGS_DIR/nexus-group-${group_num}.log"; touch "$log_file"
            echo "    - 正在启动新增组 $key (ID: $node_id)..."
            docker run -d --name "$key" -e NODE_ID="$node_id" -e PROXY_ADDR="$proxy_addr" -e NEXUS_LOG="$log_file" -e SCREEN_NAME="nexus-${group_num}" -v "$log_file":"$log_file" "$IMAGE_NAME"
        fi
    done
    echo "✅ 新增实例组已全部启动（如有）。"
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
    echo "    - 正在清理Docker构建缓存..."
    docker builder prune -f
    echo "    - 正在删除主目录: $MAIN_DIR..."
    rm -rf "$MAIN_DIR"

    echo "✅ 精准卸载完成。"
    echo "本脚本文件 '$0' 未被删除，您可以手动删除它。"
    exit 0
}

function show_welcome_message() {
    cat << "EOF"
================================================================
##
## Nexus Pro 节点管理脚本 v3.0 (专业无轮换版)
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
        echo "[ 系统管理 ]"
        echo "  4. 配置管理 (编辑/备份/恢复)"
        echo "  5. 完全卸载"
        echo "  6. 退出"
        echo ""
        echo "[ 运维工具 ]"
        echo "  7. 补齐启动所有未运行实例组"
        echo "========================================================="
        read -rp "请选择操作 (1-7): " choice

        clear
        show_welcome_message
        echo ""

        case "$choice" in
            1) create_instance_groups ;;
            2) show_control_center ;;
            3) manage_batch_ops ;;
            4) manage_configuration ;;
            5) uninstall_script ;;
            6) echo "退出脚本。再见！"; exit 0 ;;
            7) sync_all_instances ;;
            *) echo "❌ 无效选项，请输入 1-7" ;;
        esac

        echo ""
        read -rp "按回车键返回主菜单..."
        clear
        show_welcome_message
    done
}

# === 主入口 ===
check_root
ensure_dependencies
mkdir -p "$MAIN_DIR" "$LOGS_DIR" "$BACKUPS_DIR"
show_menu

