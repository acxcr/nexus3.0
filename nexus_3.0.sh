#!/bin/bash
#
# 脚本名称: nexus_3.0.sh
# 描述: Nexus Pro 节点管理脚本 v3.0, 集成了代理、轮换和高级管理功能。
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
ROTATE_SCRIPT_PATH="$MAIN_DIR/nexus-rotate.sh"
START_SCRIPT_PATH="$MAIN_DIR/start.sh"
LOGS_DIR="$MAIN_DIR/logs"
BACKUPS_DIR="$MAIN_DIR/backups"
ROTATE_SCRIPT_LOG_FILE="$LOGS_DIR/nexus-rotate-cron.log"

# 定时任务命令
CRON_JOB_COMMAND="0 */2 * * * ${ROTATE_SCRIPT_PATH} >> ${ROTATE_SCRIPT_LOG_FILE} 2>&1"


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
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        echo "✅ Docker 镜像 [$IMAGE_NAME] 已存在，无需重新构建。"
        return
    fi

    echo "▶️ Docker 镜像 [$IMAGE_NAME] 不存在，开始准备构建..."
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

    # 2. 动态创建 entrypoint.sh (包含域名预解析逻辑)
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

CONFIG_DIR="/root/.nexus"
CONFIG_FILE="$CONFIG_DIR/config.json"
mkdir -p "$CONFIG_DIR"
echo '{ "node_id": "'$NODE_ID'" }' > "$CONFIG_FILE"
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
screen -dmS "$SCREEN_NAME" bash -c "$PROXY_COMMAND nexus-network start &>> $LOG_FILE"

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

    # 3. 动态创建轮换脚本 nexus-rotate.sh
    echo "    - 正在动态创建 nexus-rotate.sh..."
    cat > "$ROTATE_SCRIPT_PATH" <<EOF
#!/bin/bash
set -e
MAIN_DIR="${MAIN_DIR}"
CONFIG_FILE="\$MAIN_DIR/nexus-master-config.json"
IMAGE_NAME="${IMAGE_NAME}"
LOGS_DIR="\$MAIN_DIR/logs"

if [ ! -f "\$CONFIG_FILE" ]; then exit 0; fi

instance_keys=\$(jq -r 'keys[] | select(startswith("nexus-group-"))' "\$CONFIG_FILE")
if [ -z "\$instance_keys" ]; then exit 0; fi

for key in \$instance_keys; do
    echo "[$(date)] --- 正在处理实例组: \$key ---"
    instance_data=\$(jq ".\\"\$key\\"" "\$CONFIG_FILE")
    proxy_address=\$(echo "\$instance_data" | jq -r '.proxy_address')
    id_pool_str=\$(echo "\$instance_data" | jq -r '.id_pool | @tsv')
    current_id_index=\$(echo "\$instance_data" | jq -r '.current_id_index')
    read -r -a id_pool <<< "\$id_pool_str"
    pool_size=\${#id_pool[@]}
    if [ \$pool_size -eq 0 ]; then continue; fi
    next_id_index=\$(( (current_id_index + 1) % pool_size ))
    new_node_id=\${id_pool[\$next_id_index]}

    echo "[$(date)]     - 新 Node ID: \$new_node_id"
    group_num=\$(echo "\$key" | sed 's/nexus-group-//')
    log_file="\$LOGS_DIR/nexus-group-\${group_num}.log"
    mkdir -p "\$LOGS_DIR" && touch "\$log_file"

    docker rm -f "\$key" &>/dev/null || true
    
    docker run -d \\
        --name "\$key" \\
        -e NODE_ID="\$new_node_id" \\
        -e PROXY_ADDR="\$proxy_address" \\
        -e NEXUS_LOG="\$log_file" \\
        -e SCREEN_NAME="nexus-group-\${group_num}" \\
        -v "\$log_file":"\$log_file" \\
        "\$IMAGE_NAME"

    jq ".\\"\$key\\".current_id_index = \$next_id_index" "\$CONFIG_FILE" > "\$CONFIG_FILE.tmp" && mv "\$CONFIG_FILE.tmp" "\$CONFIG_FILE"
    echo "[$(date)]     - 实例组 \$key 已重启并更新状态。"
done
echo "[$(date)] 所有实例组轮换完成。"
EOF
    chmod +x "$ROTATE_SCRIPT_PATH"

    # 4. 动态创建给高手用的 start.sh
    echo "    - 正在动态创建 start.sh..."
    cat > "$START_SCRIPT_PATH" <<EOF
#!/bin/bash
# 这是一个自动生成的辅助脚本，用于非交互式地启动所有已配置的节点。
set -e

MAIN_DIR=\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" &> /dev/null && pwd)
CONFIG_FILE="\$MAIN_DIR/nexus-master-config.json"
IMAGE_NAME="${IMAGE_NAME}"
LOGS_DIR="\$MAIN_DIR/logs"
ROTATE_SCRIPT_PATH="\$MAIN_DIR/nexus-rotate.sh"
CRON_JOB_COMMAND="0 */2 * * * \${ROTATE_SCRIPT_PATH} >> \${LOGS_DIR}/nexus-rotate-cron.log 2>&1"

echo "▶️ 开始执行批量启动程序..."

if [ ! -f "\$CONFIG_FILE" ] || ! jq -e '. | keys | length > 0' "\$CONFIG_FILE" > /dev/null; then
    echo "❌ 错误：配置文件 \$CONFIG_FILE 不存在或为空。"
    echo "请先在配置文件中加入节点信息，或使用主脚本的向导模式创建。"
    exit 1
fi

echo "✅ 配置文件加载成功。"

cron_job_exists=\$(crontab -l 2>/dev/null | grep -q "\$ROTATE_SCRIPT_PATH"; echo \$?)
if [ "\$cron_job_exists" -ne 0 ]; then
    (crontab -l 2>/dev/null; echo "\$CRON_JOB_COMMAND") | crontab -
    echo "💡 检测到自动轮换未开启，已为您自动添加定时任务。"
fi

mkdir -p "\$LOGS_DIR"
instance_keys=\$(jq -r 'keys[] | select(startswith("nexus-group-"))' "\$CONFIG_FILE")
for key in \$instance_keys; do
    if docker ps -q -f "name=^/\${key}$" | grep -q .; then
        echo "   - 实例组 \$key 已在运行，跳过。"
    else
        echo "   - 正在启动实例组 \$key..."
        instance_data=\$(jq ".\\"\$key\\"" "\$CONFIG_FILE")
        current_id_index=\$(echo "\$instance_data" | jq -r '.current_id_index')
        node_id=\$(echo "\$instance_data" | jq -r ".id_pool[\$current_id_index]")
        proxy_addr=\$(echo "\$instance_data" | jq -r '.proxy_address')
        group_num=\$(echo "\$key" | sed 's/nexus-group-//')
        log_file="\$LOGS_DIR/nexus-group-\${group_num}.log"
        touch "\$log_file"

        docker run -d \\
            --name "\$key" \\
            -e NODE_ID="\$node_id" \\
            -e PROXY_ADDR="\$proxy_addr" \\
            -e NEXUS_LOG="\$log_file" \\
            -e SCREEN_NAME="nexus-group-\${group_num}" \\
            -v "\$log_file":"\$log_file" \\
            "\$IMAGE_NAME"
    fi
done

echo "✅ 所有已配置的实例组均已启动或正在运行。"
EOF
    chmod +x "$START_SCRIPT_PATH"

    # 5. 执行 Docker 构建
    echo "▶️ 核心文件准备就绪，开始执行 docker build..."
    docker build -t "$IMAGE_NAME" "$BUILD_DIR"
    echo "✅ Docker 镜像 [$IMAGE_NAME] 构建成功！"
}


# ================================================================
# ==                      菜单功能实现                         ==
# ================================================================

# 1. 创建新的实例组
function create_instance_groups() {
    prepare_and_build_image

    cat <<'EOF'
--- 您将开始创建新的实例组 ---

核心概念:
  - 1 个实例组 = 1 个共享代理IP + 1 个包含1-4个ID的轮换池。
  - 每个实例组在任何时候，仅有1个ID处于活动状态，因此只运行1个容器实例。
  - 您创建 N 个组，就会有 N 个实例在后台同时运行。

EOF
    
    local group_count
    while true; do
        read -rp "请输入您想创建的实例组数量: " group_count
        if [[ "$group_count" =~ ^[1-9][0-9]*$ ]]; then break; else echo "❌ 无效输入，请输入一个正整数。"; fi
    done

    declare -A groups_proxy
    declare -A groups_ids

    for i in $(seq 1 "$group_count"); do
        echo "--- 正在配置第 $i 组 ---"
        read -rp "请输入该组要使用的SOCKS5代理地址 (留空则使用本机IP): " proxy_addr
        [ -z "$proxy_addr" ] && proxy_addr="no_proxy"
        groups_proxy[$i]="$proxy_addr"
        
        local id_pool=()
        while true; do
            read -rp "请输入该组的 Node ID (用空格分隔, 1-4个): " -a id_pool
            if [ ${#id_pool[@]} -eq 0 ]; then
                echo "❌ 请至少输入一个 Node ID。"
            elif [ ${#id_pool[@]} -gt 4 ]; then
                echo "❌ 最多只能输入4个 Node ID，您输入了 ${#id_pool[@]} 个。"
            else
                break
            fi
        done
        groups_ids[$i]="${id_pool[*]}"
    done

    echo "▶️ 信息收集完毕，正在更新配置文件..."
    mkdir -p "$MAIN_DIR"
    [ ! -f "$CONFIG_FILE" ] && echo "{}" > "$CONFIG_FILE"
    
    local current_config=$(cat "$CONFIG_FILE")
    local last_group_num=$(echo "$current_config" | jq -r 'keys[] | select(startswith("nexus-group-")) | split("-")[2] | tonumber' | sort -n | tail -1)
    [ -z "$last_group_num" ] && last_group_num=0
    
    local new_group_keys=()
    for i in $(seq 1 "$group_count"); do
        local next_group_num=$((last_group_num + i))
        local group_key="nexus-group-${next_group_num}"
        new_group_keys+=("$group_key")

        local proxy_addr=${groups_proxy[$i]}
        read -r -a id_pool <<< "${groups_ids[$i]}"

        current_config=$(echo "$current_config" | jq \
            --arg key "$group_key" \
            --arg proxy "$proxy_addr" \
            --argjson ids_json "$(printf '"%s"\n' "${id_pool[@]}" | jq -s .)" \
            '. + {($key): {"proxy_address": $proxy, "id_pool": $ids_json, "current_id_index": 0}}')
    done
    
    echo "$current_config" | jq . > "$CONFIG_FILE"
    echo "✅ 配置文件已更新。"

    manage_auto_rotation "auto_enable"

    echo "▶️ 正在根据新配置启动容器 (每组启动1个)..."
    mkdir -p "$LOGS_DIR"
    for key in "${new_group_keys[@]}"; do
        local group_data=$(jq ".\"$key\"" "$CONFIG_FILE")
        local node_id=$(echo "$group_data" | jq -r '.id_pool[0]')
        local proxy_addr=$(echo "$group_data" | jq -r '.proxy_address')
        local group_num=$(echo "$key" | sed 's/nexus-group-//')
        local log_file="$LOGS_DIR/nexus-group-${group_num}.log"
        touch "$log_file"

        echo "    - 正在启动 $key (使用初始ID: $node_id)..."
        docker run -d \
            --name "$key" \
            -e NODE_ID="$node_id" \
            -e PROXY_ADDR="$proxy_addr" \
            -e NEXUS_LOG="$log_file" \
            -e SCREEN_NAME="nexus-group-${group_num}" \
            -v "$log_file":"$log_file" \
            "$IMAGE_NAME"
    done
    
    echo "✅ 所有新实例组已成功启动！"
    echo ""
    echo "💡 温馨提示："
    echo "   您的所有工作文件都已保存在专属主目录中:"
    echo "   - 主目录:         $MAIN_DIR"
    echo "   - 配置文件:       $CONFIG_FILE"
    echo "   - 日志目录:       $LOGS_DIR"
    echo "   - 快速启动脚本:   $START_SCRIPT_PATH"
}

# 2. 实例控制中心 (折叠式高级视图)
function show_control_center() {
    if [ ! -f "$CONFIG_FILE" ] || ! jq -e '. | keys | length > 0' "$CONFIG_FILE" > /dev/null; then
        echo "❌ 配置文件不存在或为空，请先使用选项 [1] 创建实例组。"
        return
    fi
    
    clear; show_welcome_message
    echo "=========== 实例组控制中心 (高级视图) ==========="
    
    local group_keys
    group_keys=$(jq -r 'keys[] | select(startswith("nexus-group-")) | @sh' "$CONFIG_FILE" | sort -V | xargs)
    if [ -z "$group_keys" ]; then echo "没有找到任何实例组配置。"; return; fi

    for key in $group_keys; do
        echo "------------------------------------------------------------------------------------------------------------------"
        local group_num=$(echo "$key" | sed 's/nexus-group-//')
        local group_data=$(jq ".\"$key\"" "$CONFIG_FILE")
        local current_id_index=$(echo "$group_data" | jq -r '.current_id_index')
        local id_pool_str=$(echo "$group_data" | jq -r '.id_pool | @tsv')
        read -r -a id_pool <<< "$id_pool_str"
        local proxy_addr=$(echo "$group_data" | jq -r '.proxy_address')
        local status="Stopped"
        if docker ps -q -f "name=^/${key}$" | grep -q .; then status="Running"; fi

        printf "%-18s %-12s %-45.45s\n" "实例组名称" "容器状态" "使用的代理"
        printf "%-18s %-12s %-45.45s\n" "$key" "$status" "$proxy_addr"
        echo ""
        echo "  当前/备选 Node ID 列表:"
        for i in "${!id_pool[@]}"; do
            if [ "$i" -eq "$current_id_index" ]; then
                printf "    ▶ %s (当前活动)\n" "${id_pool[$i]}"
            else
                printf "    - %s (备选)\n" "${id_pool[$i]}"
            fi
        done
    done
    echo "------------------------------------------------------------------------------------------------------------------"

    read -rp "请输入您想管理的实例组编号 (例如 1 表示 nexus-group-1)，或直接按回车返回: " selected_num
    if [[ "$selected_num" =~ ^[0-9]+$ ]]; then
        local selected_key="nexus-group-${selected_num}"
        if ! jq -e ".\"$selected_key\"" "$CONFIG_FILE" > /dev/null; then echo "❌ 无效的实例组编号。"; return; fi
        
        clear; show_welcome_message
        echo "--- 正在管理实例组: $selected_key ---"
        echo "  1. 查看实时日志"
        echo "  2. 重启此实例组"
        echo "  3. 停止此实例组"
        read -rp "请选择操作 (或按回车返回): " action
        case "$action" in
            1) echo "💡 正在打开日志文件: $LOGS_DIR/nexus-group-${selected_num}.log (按 Ctrl+C 退出)"; tail -f "$LOGS_DIR/nexus-group-${selected_num}.log" ;;
            2) echo "正在重启 $selected_key..."; docker restart "$selected_key"; echo "✅ 重启完成。" ;;
            3) echo "正在停止 $selected_key..."; docker rm -f "$selected_key" > /dev/null; echo "✅ 停止完成。" ;;
            *) return ;;
        esac
    fi
}

# 3. 停止所有实例组
function stop_all_instances() {
    local force_stop=$1
    if [ "$force_stop" != "force" ]; then
        read -rp "您确定要停止所有实例组吗？[y/N]: " confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then echo "操作已取消。"; return; fi
    fi
    if [ ! -f "$CONFIG_FILE" ]; then echo "没有找到任何实例配置。"; return; fi
    echo "🛑 正在停止所有由本脚本管理的实例组..."
    local group_keys=$(jq -r 'keys[] | select(startswith("nexus-group-"))' "$CONFIG_FILE")
    if [ -n "$group_keys" ]; then
        for key in $group_keys; do
            if docker ps -q -f "name=^/${key}$" | grep -q .; then
                echo "    - 正在停止 $key..."
                docker rm -f "$key" > /dev/null
            fi
        done
    fi
    echo "✅ 所有实例组均已停止。"
}

# 4. 自动轮换开关
function manage_auto_rotation() {
    local mode=$1
    local cron_job_exists=$(crontab -l 2>/dev/null | grep -qF "$ROTATE_SCRIPT_PATH"; echo $?)
    if [ "$mode" == "auto_enable" ]; then
        if [ "$cron_job_exists" -ne 0 ]; then
            (crontab -l 2>/dev/null | grep -vF "$ROTATE_SCRIPT_PATH"; echo "$CRON_JOB_COMMAND") | crontab -
            echo "💡 温馨提示：自动轮换功能已为您自动开启 (每2小时)。"
        fi
        return
    fi
    if [ "$cron_job_exists" -eq 0 ]; then
        read -rp "自动轮换当前已开启。您确定要关闭吗？[y/N]: " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then (crontab -l | grep -vF "$ROTATE_SCRIPT_PATH") | crontab -; echo "✅ 自动轮换已关闭。"; fi
    else
        read -rp "自动轮换当前已关闭。您确定要开启吗？[y/N]: " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then (crontab -l 2>/dev/null; echo "$CRON_JOB_COMMAND") | crontab -; echo "✅ 自动轮换已开启。"; fi
    fi
}

# 5. 配置管理
function manage_configuration() {
    echo "--- 配置管理 ---"
    echo "  a. 手动编辑配置文件"
    echo "  b. 备份当前配置"
    echo "  c. 从备份恢复配置"
    read -rp "请选择操作 (或按回车返回): " action
    case "$action" in
        a) 
            if ! command -v nano &> /dev/null; then echo "❌ 'nano' 编辑器未安装。"; return; fi
            if [ ! -f "$CONFIG_FILE" ]; then echo "配置文件不存在，请先创建实例组。"; return; fi
            echo "请注意：手动编辑可能导致配置格式错误。请谨慎操作。"; read -rp "按回车键以继续..."
            nano "$CONFIG_FILE"
            if jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then echo "✅ 配置文件格式正确。"; else echo "❌ 警告：配置文件格式不正确！这可能导致脚本无法正常工作。建议立即从备份恢复。"; fi
            ;;
        b)
            if [ ! -f "$CONFIG_FILE" ]; then echo "配置文件不存在，无法备份。"; return; fi
            mkdir -p "$BACKUPS_DIR"
            local backup_file="$BACKUPS_DIR/config_$(date +%Y%m%d-%H%M%S).json.bak"
            cp "$CONFIG_FILE" "$backup_file"
            echo "✅ 配置已备份到: $backup_file"
            ;;
        c)
            mkdir -p "$BACKUPS_DIR"
            local backups=("$BACKUPS_DIR"/*.bak)
            if [ ${#backups[@]} -eq 0 ] || [ ! -e "${backups[0]}" ]; then echo "没有找到任何备份文件。"; return; fi
            echo "找到以下备份文件:"
            select backup_file in "${backups[@]}"; do
                if [ -n "$backup_file" ]; then
                    read -rp "您确定要用 $(basename "$backup_file") 覆盖当前配置吗？此操作不可逆！[y/N]: " confirm
                    if [[ "$confirm" =~ ^[yY]$ ]]; then cp "$backup_file" "$CONFIG_FILE"; echo "✅ 配置已从 $(basename "$backup_file") 恢复。"; fi
                    break
                else echo "无效选择。"; fi
            done
            ;;
        *) return ;;
    esac
}

# 6. 完全卸载
function uninstall_script() {
    echo "‼️ 警告：此操作将彻底删除本机上由本脚本创建的所有相关数据，且无法恢复！"
    echo "将要删除的内容包括："
    echo "  - 所有 nexus-group-* 容器"
    echo "  - ${IMAGE_NAME} Docker镜像"
    echo "  - 整个主目录 ${MAIN_DIR} (包含所有配置、日志、备份、脚本等)"
    echo "  - cron定时轮换任务"
    read -rp "您确定要继续吗? (请输入 y/Y 确认): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then echo "操作已取消。"; return; fi
    
    echo "▶️ 开始执行卸载..."
    
    echo "    - 正在停止并删除所有实例组容器..."
    local containers_to_remove=$(docker ps -a -q --filter "name=nexus-group-")
    if [ -n "$containers_to_remove" ]; then
        docker rm -f $containers_to_remove > /dev/null
    fi
    echo "    ✅ 所有相关容器已删除。"

    echo "    - 正在删除 Docker 镜像..."
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        docker rmi -f "$IMAGE_NAME"
    else
        echo "    - 镜像不存在，跳过删除。"
    fi

    echo "    - 正在移除 cron 定时任务..."
    crontab -l 2>/dev/null | grep -vF "$ROTATE_SCRIPT_PATH" | crontab -
    
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
        echo "  1. 创建新的实例组 (向导模式)"
        echo "  2. 实例控制中心 (查看状态、日志、重启等)"
        echo "  3. 停止所有实例组"
        echo ""
        echo "[ 系统管理 ]"
        echo "  4. 自动轮换开关 (开启/关闭)"
        echo "  5. 配置管理 (编辑/备份/恢复)"
        echo "  6. 完全卸载 (清理所有相关文件和容器)"
        echo ""
        echo "[ ]"
        echo "  7. 退出"
        echo "========================================================="
        read -rp "请选择操作 (1-7): " choice

        clear
        show_welcome_message
        echo ""
        
        case "$choice" in
            1) create_instance_groups ;;
            2) show_control_center ;;
            3) stop_all_instances ;;
            4) manage_auto_rotation ;;
            5) manage_configuration ;;
            6) uninstall_script ;;
            7) echo "退出脚本。再见！"; exit 0 ;;
            *) echo "❌ 无效选项，请输入 1-7" ;;
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
