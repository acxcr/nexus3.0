#!/bin/bash
set -e

# === 核心路径与变量 ===
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
MAIN_DIR="$SCRIPT_DIR/nexus3.0"
BUILD_DIR="$MAIN_DIR/build"
LOGS_DIR="$MAIN_DIR/logs"
BACKUPS_DIR="$MAIN_DIR/backups"
CONFIG_FILE="$MAIN_DIR/nexus-master-config.json"
IMAGE_NAME="nexus:latest"

# === 初始化依赖与目录结构 ===
function init_environment() {
    mkdir -p "$BUILD_DIR" "$LOGS_DIR" "$BACKUPS_DIR"
    command -v docker &> /dev/null || { echo "请先安装 Docker。"; exit 1; }
    [ -f "$CONFIG_FILE" ] || echo "{}" > "$CONFIG_FILE"
}

# === 构建镜像 ===
function build_image() {
    echo "▶️ 构建 Nexus 镜像..."
    cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y curl bash jq proxychains4 screen ncurses-bin
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
if [ -z "$NODE_ID" ]; then echo "缺少 NODE_ID"; exit 1; fi
if [ -n "$PROXY_ADDR" ] && [ "$PROXY_ADDR" != "no_proxy" ]; then
    cat > /etc/proxychains4.conf <<EOCF
strict_chain
proxy_dns
[ProxyList]
$PROXY_ADDR
EOCF
    CMD="proxychains4 nexus-network start --node-id $NODE_ID"
else
    CMD="nexus-network start --node-id $NODE_ID"
fi
truncate -s 0 "$LOG_FILE"
screen -dmS nexus bash -c "$CMD &>> $LOG_FILE"
sleep 3
tail -f "$LOG_FILE"
EOF

    docker build -t "$IMAGE_NAME" "$BUILD_DIR"
    echo "✅ 镜像构建完成。"
}
# === 创建实例组 ===
function create_instance_groups() {
    read -rp "请输入要创建的组数量: " group_count
    [[ "$group_count" =~ ^[1-9][0-9]*$ ]] || { echo "无效输入"; return; }

    config=$(cat "$CONFIG_FILE")
    last_index=$(echo "$config" | jq -r 'keys[] | select(test("^nexus-group-")) | split("-")[2] | tonumber' | sort -n | tail -1)
    [ -z "$last_index" ] && last_index=0

    for i in $(seq 1 "$group_count"); do
        group_num=$((last_index + i))
        group_key="nexus-group-$group_num"
        group_name="g$group_num"
        read -rp "组 $group_name 的代理地址（留空默认 no_proxy）: " proxy
        [ -z "$proxy" ] && proxy="no_proxy"

        read -rp "请输入该组的 Node ID（空格分隔）: " -a id_pool
        [ "${#id_pool[@]}" -eq 0 ] && { echo "至少需要一个 ID"; continue; }

        echo "▶️ 正在启动 $group_name 中的所有节点..."
        for j in "${!id_pool[@]}"; do
            index=$((j + 1))
            container_name="nexus-${group_name}-${index}"
            log_file="$LOGS_DIR/${group_name}-${index}.log"
            docker rm -f "$container_name" &>/dev/null || true
            docker run -d \
                --name "$container_name" \
                -e NODE_ID="${id_pool[j]}" \
                -e PROXY_ADDR="$proxy" \
                -e NEXUS_LOG="$log_file" \
                -v "$log_file":"$log_file" \
                "$IMAGE_NAME"
            echo "    - 启动容器 $container_name"
        done

        # 更新配置
        id_json=$(printf '"%s"\n' "${id_pool[@]}" | jq -s .)
        config=$(echo "$config" | jq --arg key "$group_key" --arg proxy "$proxy" --argjson ids "$id_json" '. + {($key): {proxy_address: $proxy, id_pool: $ids}}')
    done

    echo "$config" | jq . > "$CONFIG_FILE"
    echo "✅ 所有实例组已完成部署。"
}
# === 展示控制中心 ===
function show_control_center() {
    local config=$(cat "$CONFIG_FILE")
    local keys=$(echo "$config" | jq -r 'keys[] | select(test("^nexus-group-"))' | sort)

    for key in $keys; do
        local group_num=$(echo "$key" | cut -d- -f3)
        local group_name="g$group_num"
        local proxy=$(echo "$config" | jq -r --arg k "$key" '.[$k].proxy_address')
        local ids=($(echo "$config" | jq -r --arg k "$key" '.[$k].id_pool[]'))

        echo ""
        echo "============================== 组 $group_name =============================="
        echo "代理地址：$proxy"
        echo ""
        printf "%-20s | %-8s | %-10s | %s\n" "容器名" "状态" "运行时间" "Node ID"
        echo "----------------------------------------------------------------------------"

        for i in "${!ids[@]}"; do
            local idx=$((i + 1))
            local cname="nexus-${group_name}-${idx}"
            local nid="${ids[$i]}"
            local status="Stopped"
            local uptime="N/A"

            if docker ps -q -f "name=^/${cname}$" | grep -q .; then
                status="Running"
                local started=$(docker inspect -f '{{.State.StartedAt}}' "$cname" 2>/dev/null)
                if [ -n "$started" ]; then
                    local start_ts=$(date -d "$started" +%s)
                    local now_ts=$(date +%s)
                    local diff=$((now_ts - start_ts))
                    uptime=$(printf "%02d:%02d:%02d" $((diff/3600)) $((diff%3600/60)) $((diff%60)))
                fi
            fi
            printf "%-20s | %-8s | %-10s | %s\n" "$cname" "$status" "$uptime" "$nid"
        done

        echo "----------------------------------------------------------------------------"
        echo "操作选项："
        echo "  1. 查看日志   2. 重启容器   3. 停止容器   4. 跳过本组"
        read -rp "请选择 (1/2/3/4): " action

        if [[ "$action" =~ ^[1-3]$ ]]; then
            read -rp "请输入要操作的容器编号 (例如 1): " index
            [[ "$index" =~ ^[0-9]+$ ]] || { echo "无效编号"; continue; }
            local cname="nexus-${group_name}-${index}"
            local log_file="$LOGS_DIR/${group_name}-${index}.log"
            case "$action" in
                1) echo "按 Ctrl+C 退出日志查看"; tail -f "$log_file" ;;
                2) docker restart "$cname" && echo "已重启 $cname" ;;
                3) docker rm -f "$cname" && echo "已停止并删除 $cname" ;;
            esac
        fi
    done
}

# === 一键停止/重启所有容器 ===
function manage_all_containers() {
    echo "1. 停止所有容器"
    echo "2. 重启所有容器"
    read -rp "请选择操作: " action
    local config=$(cat "$CONFIG_FILE")
    local keys=$(echo "$config" | jq -r 'keys[] | select(test("^nexus-group-"))')
    for key in $keys; do
        local group_num=$(echo "$key" | cut -d- -f3)
        local group_name="g$group_num"
        local ids=($(echo "$config" | jq -r --arg k "$key" '.[$k].id_pool[]'))
        for i in "${!ids[@]}"; do
            local idx=$((i + 1))
            local cname="nexus-${group_name}-${idx}"
            if [ "$action" == "1" ]; then
                docker rm -f "$cname" &>/dev/null && echo "已停止 $cname"
            elif [ "$action" == "2" ]; then
                docker restart "$cname" &>/dev/null && echo "已重启 $cname"
            fi
        done
    done
}

# === 主菜单 ===
function show_menu() {
    while true; do
        echo ""
        echo "=========== Nexus 节点管理面板 ==========="
        echo "1. 创建新的实例组"
        echo "2. 实例组控制中心"
        echo "3. 停止 / 重启 所有容器"
        echo "4. 退出"
        read -rp "请选择操作: " choice
        case "$choice" in
            1) create_instance_groups ;;
            2) show_control_center ;;
            3) manage_all_containers ;;
            4) echo "再见！" ; exit 0 ;;
            *) echo "无效输入，请重新选择" ;;
        esac
    done
}

# === 启动入口 ===
init_environment
build_image
show_menu

