#!/bin/bash

# Containerd 容器创建脚本
# 用途: 快速创建和配置 Containerd 容器
# 用法: bash containerd_create_container.sh <容器名> <镜像> [命令]
# 示例: bash containerd_create_container.sh test alpine:latest sh

# =============== 颜色输出函数 ===============
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# =============== 帮助信息 ===============
show_help() {
    cat << EOF
Containerd 容器创建脚本

用法: bash containerd_create_container.sh <容器名> <镜像> [命令]

参数:
    容器名      容器的唯一标识符
    镜像        容器镜像，格式: [registry/]repository[:tag]
    命令        容器启动命令 (默认: 容器中的默认命令)

示例:
    # 创建基于 Alpine 的交互式容器
    bash containerd_create_container.sh test1 alpine:latest sh
    
    # 创建基于 Debian 的容器
    bash containerd_create_container.sh test2 debian:latest bash
    
    # 创建运行 sleep 的后台容器
    bash containerd_create_container.sh test3 alpine:latest sleep 1000

支持的镜像:
    - docker.io/library/alpine:latest
    - docker.io/library/debian:latest
    - docker.io/library/ubuntu:latest
    - docker.io/library/busybox:latest

EOF
}

# =============== 检查环境 ===============
check_environment() {
    _yellow "检查 Containerd 环境..."
    
    # 检查 ctr 命令
    if ! command -v ctr >/dev/null 2>&1; then
        _red "✗ ctr 命令不可用，请先运行 containerdinstall.sh"
        exit 1
    fi
    
    # 检查 containerd 服务
    if ! pgrep -x containerd >/dev/null 2>&1 && ! systemctl is-active --quiet containerd 2>/dev/null; then
        _red "✗ containerd 服务未运行"
        _yellow "  尝试启动服务: systemctl start containerd"
        exit 1
    fi
    
    _green "✓ Containerd 环境检查通过"
}

# =============== 拉取镜像 ===============
pull_image() {
    local image="$1"
    
    _yellow "拉取镜像: $image..."
    
    if ctr images pull "$image" >/dev/null 2>&1; then
        _green "✓ 镜像拉取成功"
        return 0
    else
        # 尝试添加 docker.io 前缀
        local full_image="docker.io/library/$image"
        _yellow "尝试完整镜像路径: $full_image"
        
        if ctr images pull "$full_image" >/dev/null 2>&1; then
            _green "✓ 镜像拉取成功"
            return 0
        else
            _red "✗ 镜像拉取失败"
            return 1
        fi
    fi
}

# =============== 创建容器 ===============
create_container() {
    local container_name="$1"
    local image="$2"
    shift 2
    local command="$@"
    
    _blue "创建容器..."
    log "容器名: $container_name"
    log "镜像: $image"
    log "命令: ${command:-默认}"
    
    # 检查容器是否已存在
    if ctr containers ls 2>/dev/null | grep -q "^$container_name"; then
        _red "✗ 容器 $container_name 已存在"
        return 1
    fi
    
    # 创建容器
    local cmd_args=""
    if [ -n "$command" ]; then
        cmd_args="--args-raw"
    fi
    
    if ctr run $cmd_args -d "$image" "$container_name" $command >/dev/null 2>&1; then
        _green "✓ 容器创建成功"
        return 0
    else
        # 尝试完整镜像路径
        local full_image="docker.io/library/$image"
        _yellow "  尝试完整镜像路径..."
        
        if ctr run $cmd_args -d "$full_image" "$container_name" $command >/dev/null 2>&1; then
            _green "✓ 容器创建成功"
            return 0
        else
            _red "✗ 容器创建失败"
            return 1
        fi
    fi
}

# =============== 显示容器信息 ===============
show_container_info() {
    local container_name="$1"
    
    _blue "容器信息:"
    ctr containers info "$container_name" 2>/dev/null || _red "✗ 无法获取容器信息"
}

# =============== 日志函数 ===============
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# =============== 主程序 ===============
main() {
    local container_name="${1:-}"
    local image="${2:-}"
    shift 2
    local command="$@"
    
    # 显示帮助或错误
    if [ -z "$container_name" ] || [ -z "$image" ]; then
        if [ "$container_name" = "help" ] || [ "$container_name" = "-h" ] || [ "$container_name" = "--help" ]; then
            show_help
        else
            _red "错误: 缺少必要参数"
            show_help
        fi
        exit 1
    fi
    
    _blue "============================================"
    _blue "  Containerd 容器创建"
    _blue "============================================"
    echo
    
    # 检查环境
    check_environment
    echo
    
    # 拉取镜像
    log "步骤 1/3: 拉取镜像"
    if ! pull_image "$image"; then
        exit 1
    fi
    echo
    
    # 创建容器
    log "步骤 2/3: 创建容器"
    if ! create_container "$container_name" "$image" $command; then
        exit 1
    fi
    echo
    
    # 显示容器信息
    log "步骤 3/3: 显示容器信息"
    ctr containers ls
    
    echo
    _green "============================================"
    _green "✓ 容器创建完成！"
    _green "============================================"
    echo
    
    _blue "常用命令:"
    _yellow "  列出容器: ctr containers ls"
    _yellow "  删除容器: ctr containers delete $container_name"
    _yellow "  查看镜像: ctr images ls"
}

# 执行主程序
main "$@"
