#!/bin/bash
set -e

# === 核心路径与变量定义 ===
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
MAIN_DIR="$SCRIPT_DIR/nexus3.0"
BUILD_DIR="$MAIN_DIR/build"
LOGS_DIR="$MAIN_DIR/logs"
BACKUPS_DIR="$MAIN_DIR/backups"
CONFIG_FILE="$MAIN_DIR/nexus-master-config.json"
IMAGE_NAME="nexus:latest"

# === 初始化依赖与目录结构 ===
function ensure_dependencies() {
    echo "▶️ 检查并安装依赖..."
    local pkgs=(curl bash jq proxychains4 screen ncurses-bin)
    local missing=()
    for p in "${pkgs[@]}"; do dpkg -s "$p" &>/dev/null || missing+=("$p"); done
    if [ "${#missing[@]}" -ne 0 ]; then
        echo "缺少以下依赖：${missing[*]}"
        apt-get update && apt-get install -y "${missing[@]}"
    fi
}

function init_environment() {
    mkdir -p "$BUILD_DIR" "$LOGS_DIR" "$BACKUPS_DIR"
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
# === 创建新的实例组 ===
function create_instance_groups() {
    read -rp "请输入要创建的组数量: " group_count
    [[ "$group_count" =~ ^[1-9][0-9]*$ ]] || { echo "无效输入"; return; }

    config=$(cat "$CONFIG_FILE")
    last_index=$(echo "$config" | jq -r 'keys[] | select(test("^nexus-group-")) | split("-")[2] | tonumber' | sort -n | tail -1)
    [ -z "$last_index" ] && last_index=0

    declare -A group_proxies
    declare -A group_ids

    for i in $(seq 1 "$group_count"); do
        group_num=$((last_index + i))
        group_key="nexus-group-$group_num"
        group_name="g$group_num"
        echo -e "\n------ 配置组 $group_name ------"
        read -rp "组 $group_name 的代理地址（留空默认 no_proxy）: " proxy
        [ -z "$proxy" ] && proxy="no_proxy"
        read -rp "请输入该组的 Node ID（空格分隔）: " -a id_pool
        [ "${#id_pool[@]}" -eq 0 ] && { echo "⚠️ 该组未提供任何 ID，跳过"; continue; }

        group_proxies["$group_key"]="$proxy"
        group_ids["$group_key"]="${id_pool[*]}"
    done

    echo -e "\n▶️ 所有组配置已完成，正在准备部署..."
    ensure_dependencies
    build_image

    for key in "${!group_proxies[@]}"; do
        group_num=$(echo "$key" | cut -d- -f3)
        group_name="g$group_num"
        proxy="${group_proxies[$key]}"
        IFS=' ' read -r -a ids <<< "${group_ids[$key]}"

        echo "▶️ 启动 $group_name（共 ${#ids[@]} 个节点）..."
        for i in "${!ids[@]}"; do
            index=$((i + 1))
            node_id="${ids[$i]}"
            container_name="nexus-${group_name}-${index}"
            log_file="$LOGS_DIR/${group_name}-${index}.log"

            docker rm -f "$container_name" &>/dev/null || true
            docker run -d \
                --name "$container_name" \
                -e NODE_ID="$node_id" \
                -e PROXY_ADDR="$proxy" \
                -e NEXUS_LOG="$log_file" \
                -v "$log_file":"$log_file" \
                "$IMAGE_NAME"
            echo "    ✅ 启动 $container_name"
        done

        # 更新配置文件
        ids_json=$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)
        config=$(echo "$config" | jq --arg k "$key" --arg p "$proxy" --argjson ids "$ids_json" '.[$k] = {proxy_address: $p, id_pool: $ids}')
    done

    echo "$config" > "$CONFIG_FILE"
    echo -e "\n✅ 所有实例组已成功部署并写入配置文件。"
}
# === 从配置文件部署未部署的组 ===
function deploy_from_config_file() {
    echo "▶️ 扫描配置文件并部署未运行的容器..."

    [ -f "$CONFIG_FILE" ] || { echo "❌ 未找到配置文件：$CONFIG_FILE"; return; }
    ensure_dependencies
    build_image

    config=$(cat "$CONFIG_FILE")
    groups=$(echo "$config" | jq -r 'keys[]')

    for key in $groups; do
        group_num=$(echo "$key" | cut -d- -f3)
        group_name="g$group_num"
        proxy=$(echo "$config" | jq -r --arg k "$key" '.[$k].proxy_address')
        ids=$(echo "$config" | jq -r --arg k "$key" '.[$k].id_pool[]')

        i=1
        for node_id in $ids; do
            container_name="nexus-${group_name}-${i}"
            log_file="$LOGS_DIR/${group_name}-${i}.log"

            if docker ps -a --format '{{.Names}}' | grep -q "^$container_name$"; then
                echo "⏩ 已存在容器 $container_name，跳过"
            else
                echo "🚀 启动新容器 $container_name"
                docker run -d \
                    --name "$container_name" \
                    -e NODE_ID="$node_id" \
                    -e PROXY_ADDR="$proxy" \
                    -e NEXUS_LOG="$log_file" \
                    -v "$log_file":"$log_file" \
                    "$IMAGE_NAME"
                echo "    ✅ 启动 $container_name"
            fi
            i=$((i + 1))
        done
    done

    echo "✅ 所有尚未部署的容器已完成部署。"
}
# === 实例组控制中心 ===
function show_control_center() {
    config=$(cat "$CONFIG_FILE")
    groups=$(echo "$config" | jq -r 'keys[]')

    for key in $groups; do
        group_num=$(echo "$key" | cut -d- -f3)
        group_name="g$group_num"
        proxy=$(echo "$config" | jq -r --arg k "$key" '.[$k].proxy_address')
        ids=$(echo "$config" | jq -r --arg k "$key" '.[$k].id_pool[]')

        echo -e "\n============================== 组 $group_name =============================="
        echo "代理地址：$proxy"
        echo -e "\n容器名            | 状态   | 运行时间 | Node ID"
        echo "----------------------------------------------------------------------------"

        i=1
        for node_id in $ids; do
            cname="nexus-${group_name}-${i}"
            status=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "Not Found")
            uptime=$(docker inspect -f '{{.State.Running}} {{.State.StartedAt}}' "$cname" 2>/dev/null | awk '{print $2}' | xargs -I{} date -d {} '+%H:%M:%S' 2>/dev/null || echo "N/A")
            [ "$status" != "running" ] && uptime="N/A"
            printf "%-20s | %-7s | %-9s | %s\n" "$cname" "$status" "$uptime" "$node_id"
            i=$((i + 1))
        done

        echo "----------------------------------------------------------------------------"
        echo "操作选项："
        echo "  1. 查看日志   2. 重启容器   3. 停止容器   4. 跳过本组"
        read -rp "请选择 (1/2/3/4): " op
        i=1
        for node_id in $ids; do
            cname="nexus-${group_name}-${i}"
            log_file="$LOGS_DIR/${group_name}-${i}.log"
            case "$op" in
                1) echo -e "\n📜 日志：$cname"; tail -n 30 "$log_file" ;;
                2) docker restart "$cname" && echo "🔁 已重启 $cname" ;;
                3) docker stop "$cname" && echo "⛔ 已停止 $cname" ;;
                *) break ;;
            esac
            i=$((i + 1))
        done
    done
}

# === 停止 / 重启 所有容器 ===
function manage_all_containers() {
    echo "⚙️ 操作所有 nexus 容器"
    echo "1. 停止全部"
    echo "2. 重启全部"
    read -rp "选择操作: " act
    containers=$(docker ps -a --format '{{.Names}}' | grep '^nexus-g')
    case "$act" in
        1) for c in $containers; do docker stop "$c"; echo "⛔ 停止 $c"; done ;;
        2) for c in $containers; do docker restart "$c"; echo "🔁 重启 $c"; done ;;
        *) echo "❌ 无效选择" ;;
    esac
}

# === 主菜单入口 ===
function show_menu() {
    while true; do
        echo ""
        echo "=========== Nexus 节点管理面板 ==========="
        echo "1. 创建新的实例组"
        echo "2. 实例组控制中心"
        echo "3. 停止 / 重启 所有容器"
        echo "4. 扫描配置文件部署新组"
        echo "5. 退出"
        read -rp "请选择操作: " choice
        case "$choice" in
            1) create_instance_groups ;;
            2) show_control_center ;;
            3) manage_all_containers ;;
            4) deploy_from_config_file ;;
            5) echo "再见！"; exit 0 ;;
            *) echo "❌ 无效选择" ;;
        esac
    done
}

# === 主程序入口 ===
init_environment
show_menu
