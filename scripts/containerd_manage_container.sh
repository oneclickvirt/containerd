#!/bin/bash

# Containerd 容器管理脚本
# 用途: 管理和维护 Containerd 容器
# 用法: bash containerd_manage_container.sh <操作> <容器ID/名称> [参数]
# 示例: bash containerd_manage_container.sh list
#       bash containerd_manage_container.sh inspect mycontainer
#       bash containerd_manage_container.sh stop mycontainer
#       bash containerd_manage_container.sh remove mycontainer

# =============== 颜色输出函数 ===============
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# =============== 帮助信息 ===============
show_help() {
    cat << EOF
Containerd 容器管理脚本

用法: bash containerd_manage_container.sh <操作> [参数]

操作:
    list                列出所有容器
    ls                  同 list
    inspect <容器>      查看容器详细信息
    info <容器>         同 inspect
    start <容器>        启动容器
    run <容器>          同 start
    stop <容器>         停止容器
    kill <容器>         强制停止容器
    remove <容器>       删除容器
    rm <容器>           同 remove
    logs <容器>         查看容器日志
    exec <容器> <cmd>   在容器中执行命令
    stats <容器>        查看容器状态信息
    help                显示此帮助信息

示例:
    # 列出所有容器
    bash containerd_manage_container.sh list
    
    # 查看容器详细信息
    bash containerd_manage_container.sh inspect mycontainer
    
    # 启动容器
    bash containerd_manage_container.sh start mycontainer
    
    # 在容器中执行命令
    bash containerd_manage_container.sh exec mycontainer cat /etc/os-release
    
    # 查看容器状态
    bash containerd_manage_container.sh stats mycontainer
    
    # 停止并删除容器
    bash containerd_manage_container.sh stop mycontainer
    bash containerd_manage_container.sh remove mycontainer

高级操作:
    # 列出所有容器 (包含 ID 和状态)
    ctr containers ls
    
    # 查看容器详细信息
    ctr containers info <container-id>
    
    # 启动任务 (容器进程)
    ctr run -d <image> <container> <command>
    
    # 停止任务
    ctr tasks kill <container>
    
    # 删除容器
    ctr containers delete <container>

EOF
}

# =============== 检查环境 ===============
check_environment() {
    if ! command -v ctr >/dev/null 2>&1; then
        _red "✗ ctr 命令不可用"
        return 1
    fi
}

# =============== 列出容器 ===============
list_containers() {
    _blue "列出所有容器:"
    echo
    
    if ctr containers ls; then
        echo
        _green "✓ 容器列表获取成功"
        return 0
    else
        _red "✗ 获取容器列表失败"
        return 1
    fi
}

# =============== 查看容器信息 ===============
inspect_container() {
    local container="$1"
    
    if [ -z "$container" ]; then
        _red "✗ 缺少容器参数"
        return 1
    fi
    
    _blue "容器详细信息: $container"
    echo
    
    if ctr containers info "$container" 2>/dev/null; then
        echo
        _green "✓ 容器信息获取成功"
        return 0
    else
        _red "✗ 容器不存在或获取信息失败"
        return 1
    fi
}

# =============== 启动容器 ===============
start_container() {
    local container="$1"
    
    if [ -z "$container" ]; then
        _red "✗ 缺少容器参数"
        return 1
    fi
    
    _yellow "启动容器: $container"
    
    # 检查容器是否存在
    if ! ctr containers info "$container" >/dev/null 2>&1; then
        _red "✗ 容器不存在: $container"
        return 1
    fi
    
    # 启动任务 (容器进程)
    if ctr tasks start "$container" >/dev/null 2>&1; then
        _green "✓ 容器已启动"
        return 0
    else
        _yellow "⚠ 任务可能已在运行，尝试获取状态..."
        
        if ctr tasks list 2>/dev/null | grep -q "$container"; then
            _green "✓ 任务已在运行"
            return 0
        else
            _red "✗ 启动容器失败"
            return 1
        fi
    fi
}

# =============== 停止容器 ===============
stop_container() {
    local container="$1"
    
    if [ -z "$container" ]; then
        _red "✗ 缺少容器参数"
        return 1
    fi
    
    _yellow "停止容器: $container"
    
    if ctr tasks kill "$container" >/dev/null 2>&1; then
        _green "✓ 容器已停止"
        return 0
    else
        _yellow "⚠ 容器可能已停止"
        return 0
    fi
}

# =============== 强制停止容器 ===============
kill_container() {
    local container="$1"
    
    if [ -z "$container" ]; then
        _red "✗ 缺少容器参数"
        return 1
    fi
    
    _yellow "强制停止容器: $container"
    
    if ctr tasks kill -s 9 "$container" >/dev/null 2>&1; then
        _green "✓ 容器已强制停止"
        return 0
    else
        _yellow "⚠ 容器可能已停止"
        return 0
    fi
}

# =============== 删除容器 ===============
remove_container() {
    local container="$1"
    
    if [ -z "$container" ]; then
        _red "✗ 缺少容器参数"
        return 1
    fi
    
    _yellow "删除容器: $container"
    
    # 先停止任务
    ctr tasks kill "$container" 2>/dev/null || true
    sleep 1
    
    # 删除容器
    if ctr containers delete "$container" >/dev/null 2>&1; then
        _green "✓ 容器已删除"
        return 0
    else
        _red "✗ 删除容器失败"
        return 1
    fi
}

# =============== 查看容器日志 ===============
show_logs() {
    local container="$1"
    
    if [ -z "$container" ]; then
        _red "✗ 缺少容器参数"
        return 1
    fi
    
    _blue "容器日志: $container"
    echo
    
    # Containerd 的日志可能在 /var/log/containers/ 或容器的标准输出
    _yellow "注意: Containerd 的日志输出取决于容器的启动方式"
    _yellow "通常日志位置: /var/log/containers/ 或 containerd 日志目录"
    echo
    
    # 尝试获取容器信息
    if ctr containers info "$container" >/dev/null 2>&1; then
        _green "✓ 容器存在"
        echo
        _yellow "获取容器详细信息..."
        ctr containers info "$container" | tail -20
        return 0
    else
        _red "✗ 容器不存在"
        return 1
    fi
}

# =============== 在容器中执行命令 ===============
exec_command() {
    local container="$1"
    shift
    local command="$@"
    
    if [ -z "$container" ] || [ -z "$command" ]; then
        _red "✗ 缺少容器或命令参数"
        return 1
    fi
    
    _yellow "在容器中执行命令: $command"
    echo
    
    # Containerd 使用 ctr tasks exec 执行命令
    # 注意: 这需要容器正在运行
    if ctr tasks exec --exec-id $(date +%s%N) "$container" $command; then
        _green "✓ 命令执行成功"
        return 0
    else
        _red "✗ 命令执行失败"
        return 1
    fi
}

# =============== 查看容器状态 ===============
show_stats() {
    local container="$1"
    
    if [ -z "$container" ]; then
        _red "✗ 缺少容器参数"
        return 1
    fi
    
    _blue "容器状态信息: $container"
    echo
    
    # 列出所有任务，查看容器状态
    if ctr tasks list 2>/dev/null | grep "$container"; then
        _green "✓ 容器正在运行"
    else
        _yellow "⚠ 容器未运行或不存在"
    fi
    
    echo
    _yellow "容器详细信息:"
    ctr containers info "$container" 2>/dev/null | grep -E "ID|Status|Image|Runtime" || true
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
        list|ls)
            list_containers
            ;;
        inspect|info)
            inspect_container "$2"
            ;;
        start|run)
            start_container "$2"
            ;;
        stop)
            stop_container "$2"
            ;;
        kill)
            kill_container "$2"
            ;;
        remove|rm)
            remove_container "$2"
            ;;
        logs)
            show_logs "$2"
            ;;
        exec)
            exec_command "$2" "${@:3}"
            ;;
        stats)
            show_stats "$2"
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
