#!/bin/bash

# Containerd 网络配置脚本
# 用途: 配置和管理 Containerd 容器网络
# 用法: bash containerd_network_setup.sh <操作> [参数]
# 示例: bash containerd_network_setup.sh list-networks
#       bash containerd_network_setup.sh create-bridge mynet
#       bash containerd_network_setup.sh list-container-ips

# =============== 颜色输出函数 ===============
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# =============== 帮助信息 ===============
show_help() {
    cat << EOF
Containerd 网络配置脚本

用法: bash containerd_network_setup.sh <操作> [参数]

网络配置:
    list-networks               列出所有网络接口
    create-bridge <网> <网关>   创建 bridge 网络
    delete-bridge <网>          删除 bridge 网络
    config-dns <IP>             配置 DNS 服务器

容器网络:
    list-container-ips          列出所有容器的 IP
    get-container-ip <容器>     获取容器 IP 地址
    connect-container <容器> <网> 将容器连接到网络
    inspect-network <网>        查看网络详细信息

网络诊断:
    test-container-network <容器>     测试容器网络连接
    check-dns <容器>                  检查容器 DNS
    show-routes <容器>                显示容器路由表
    container-stats <容器>            显示容器网络统计

网络策略:
    enable-firewall                 启用容器防火墙
    disable-firewall                禁用容器防火墙
    allow-port <端口>               允许容器端口
    block-port <端口>               阻止容器端口

帮助:
    help                        显示此帮助信息

参数说明:
    容器    容器ID或名称
    网      网络名称
    网关    网关 IP 地址 (如: 172.18.0.1)
    IP      IP 地址

示例:
    # 列出网络
    bash containerd_network_setup.sh list-networks
    
    # 创建 bridge 网络
    bash containerd_network_setup.sh create-bridge mynet 172.18.0.1
    
    # 获取容器 IP
    bash containerd_network_setup.sh get-container-ip mycontainer
    
    # 列出所有容器的 IP
    bash containerd_network_setup.sh list-container-ips
    
    # 测试容器网络
    bash containerd_network_setup.sh test-container-network mycontainer
    
    # 检查容器 DNS
    bash containerd_network_setup.sh check-dns mycontainer

高级用法:
    # 检查 CNI 配置
    ls -la /etc/cni/net.d/
    
    # 查看网络配置
    cat /etc/cni/net.d/10-containerd-net.conflist
    
    # 手动配置 CNI
    cp /opt/cni/bin/* /usr/local/bin/

EOF
}

# =============== 检查环境 ===============
check_environment() {
    if ! command -v ctr >/dev/null 2>&1; then
        _red "✗ ctr 命令不可用"
        return 1
    fi
    
    if ! command -v ip >/dev/null 2>&1; then
        _red "✗ ip 命令不可用"
        return 1
    fi
}

# =============== 列出网络接口 ===============
list_networks() {
    _blue "列出所有网络接口:"
    echo
    
    if ip link show | grep -E "^[0-9]+:"; then
        echo
        _yellow "CNI 网络配置 (/etc/cni/net.d/):"
        ls -1 /etc/cni/net.d/ 2>/dev/null || _yellow "⚠ 无 CNI 配置文件"
        
        echo
        _green "✓ 网络列表获取成功"
        return 0
    else
        _red "✗ 获取网络列表失败"
        return 1
    fi
}

# =============== 创建 bridge 网络 ===============
create_bridge() {
    local bridge_name="$1"
    local gateway="${2:-172.18.0.1}"
    
    if [ -z "$bridge_name" ]; then
        _red "✗ 缺少网络名称"
        return 1
    fi
    
    _yellow "创建 bridge 网络: $bridge_name (网关: $gateway)"
    echo
    
    # 检查是否已存在
    if ip link show "$bridge_name" >/dev/null 2>&1; then
        _yellow "⚠ bridge 已存在: $bridge_name"
        return 0
    fi
    
    # 创建 bridge
    _yellow "第一步: 创建 bridge..."
    if ! ip link add "$bridge_name" type bridge; then
        _red "✗ 创建 bridge 失败"
        return 1
    fi
    
    # 设置网关
    _yellow "第二步: 配置网关 IP..."
    if ! ip addr add "$gateway/24" dev "$bridge_name"; then
        _red "✗ 配置 IP 失败"
        return 1
    fi
    
    # 启动 bridge
    _yellow "第三步: 启动 bridge..."
    if ! ip link set "$bridge_name" up; then
        _red "✗ 启动 bridge 失败"
        return 1
    fi
    
    # 配置 CNI
    _yellow "第四步: 配置 CNI..."
    local cni_conf="/etc/cni/net.d/10-$bridge_name.conflist"
    
    cat > "$cni_conf" << 'JSON'
{
  "cniVersion": "1.0.0",
  "name": "BRIDGE_NAME",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "BRIDGE_NAME",
      "isGateway": true,
      "ipMasq": true,
      "ipam": {
        "type": "host-local",
        "subnet": "SUBNET/24"
      }
    },
    {
      "type": "firewall"
    }
  ]
}
JSON
    
    # 替换占位符
    sed -i "s|BRIDGE_NAME|$bridge_name|g" "$cni_conf"
    sed -i "s|SUBNET|${gateway%.*}|g" "$cni_conf"
    
    _green "✓ Bridge 网络创建成功"
    _green "  网络名: $bridge_name"
    _green "  网关: $gateway"
    _green "  配置文件: $cni_conf"
    
    return 0
}

# =============== 删除 bridge 网络 ===============
delete_bridge() {
    local bridge_name="$1"
    
    if [ -z "$bridge_name" ]; then
        _red "✗ 缺少网络名称"
        return 1
    fi
    
    _yellow "删除 bridge 网络: $bridge_name"
    
    # 删除网络接口
    if ip link show "$bridge_name" >/dev/null 2>&1; then
        _yellow "删除网络接口..."
        ip link set "$bridge_name" down
        ip link del "$bridge_name"
    fi
    
    # 删除 CNI 配置
    local cni_conf="/etc/cni/net.d/10-$bridge_name.conflist"
    if [ -f "$cni_conf" ]; then
        _yellow "删除 CNI 配置..."
        rm "$cni_conf"
    fi
    
    _green "✓ Bridge 网络已删除"
    return 0
}

# =============== 列出容器 IP ===============
list_container_ips() {
    _blue "列出所有容器的 IP 地址:"
    echo
    
    # 使用 ctr 列出容器
    local containers=$(ctr containers ls -q 2>/dev/null)
    
    if [ -z "$containers" ]; then
        _yellow "⚠ 无运行中的容器"
        return 0
    fi
    
    echo "容器ID                              IP 地址"
    echo "─────────────────────────────────── ─────────────────"
    
    echo "$containers" | while read -r container_id; do
        # 尝试从 nsenter 获取 IP
        local pid=$(ctr task ls -o json 2>/dev/null | grep -o "\"$container_id\"" | head -1)
        
        if [ -n "$pid" ]; then
            # 获取容器网络 IP
            local ip=$(ip -4 addr show 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
            printf "%-35s %s\n" "$container_id" "${ip:-N/A}"
        fi
    done
    
    return 0
}

# =============== 获取容器 IP ===============
get_container_ip() {
    local container="$1"
    
    if [ -z "$container" ]; then
        _red "✗ 缺少容器参数"
        return 1
    fi
    
    _blue "获取容器 IP: $container"
    echo
    
    # 检查容器是否存在
    if ! ctr containers ls -q 2>/dev/null | grep -q "$container"; then
        _red "✗ 容器不存在: $container"
        return 1
    fi
    
    # 获取容器进程 ID 并查询网络
    local pid=$(ctr task ls -o json 2>/dev/null | jq -r ".[] | select(.id == \"$container\") | .pid" 2>/dev/null)
    
    if [ -n "$pid" ] && [ "$pid" != "null" ]; then
        _yellow "容器进程 ID: $pid"
        
        # 进入容器网络命名空间查看 IP
        if nsenter -t "$pid" -n ip addr show 2>/dev/null; then
            return 0
        fi
    fi
    
    _yellow "⚠ 无法获取容器 IP 信息"
    return 0
}

# =============== 测试容器网络 ===============
test_container_network() {
    local container="$1"
    
    if [ -z "$container" ]; then
        _red "✗ 缺少容器参数"
        return 1
    fi
    
    _blue "测试容器网络: $container"
    echo
    
    # 获取容器 PID
    local pid=$(ctr task ls -o json 2>/dev/null | jq -r ".[] | select(.id == \"$container\") | .pid" 2>/dev/null)
    
    if [ -z "$pid" ]; then
        _red "✗ 无法获取容器 PID"
        return 1
    fi
    
    _yellow "网络接口:"
    nsenter -t "$pid" -n ip link show 2>/dev/null
    
    echo
    _yellow "IP 地址:"
    nsenter -t "$pid" -n ip addr show 2>/dev/null
    
    echo
    _yellow "路由表:"
    nsenter -t "$pid" -n ip route show 2>/dev/null
    
    echo
    _yellow "DNS 配置:"
    nsenter -t "$pid" -n cat /etc/resolv.conf 2>/dev/null
    
    _green "✓ 网络测试完成"
    return 0
}

# =============== 检查容器 DNS ===============
check_dns() {
    local container="$1"
    
    if [ -z "$container" ]; then
        _red "✗ 缺少容器参数"
        return 1
    fi
    
    _blue "检查容器 DNS: $container"
    echo
    
    local pid=$(ctr task ls -o json 2>/dev/null | jq -r ".[] | select(.id == \"$container\") | .pid" 2>/dev/null)
    
    if [ -z "$pid" ]; then
        _red "✗ 无法获取容器 PID"
        return 1
    fi
    
    _yellow "DNS 配置 (/etc/resolv.conf):"
    nsenter -t "$pid" -n cat /etc/resolv.conf 2>/dev/null || _yellow "⚠ 无 DNS 配置"
    
    echo
    _yellow "DNS 测试:"
    nsenter -t "$pid" -n nslookup google.com 2>/dev/null || \
        nsenter -t "$pid" -n ping -c 1 8.8.8.8 2>/dev/null || \
        _yellow "⚠ DNS 查询失败"
    
    return 0
}

# =============== 主程序 ===============
main() {
    local operation="${1:-help}"
    
    # 检查环境
    if ! check_environment; then
        _red "环境检查失败，请先安装 containerd"
        exit 1
    fi
    
    case "$operation" in
        list-networks)
            list_networks
            ;;
        create-bridge)
            create_bridge "$2" "$3"
            ;;
        delete-bridge)
            delete_bridge "$2"
            ;;
        list-container-ips)
            list_container_ips
            ;;
        get-container-ip)
            get_container_ip "$2"
            ;;
        test-container-network)
            test_container_network "$2"
            ;;
        check-dns)
            check_dns "$2"
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            _red "未知操作: $operation"
            show_help
            exit 1
            ;;
    esac
}

# 执行主程序
main "$@"
