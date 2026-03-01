#!/bin/bash

# Containerd 镜像管理脚本
# 用途: 管理和维护 Containerd 容器镜像
# 用法: bash containerd_image_manage.sh <操作> [参数]
# 示例: bash containerd_image_manage.sh list
#       bash containerd_image_manage.sh pull alpine:latest
#       bash containerd_image_manage.sh remove alpine:latest

# =============== 颜色输出函数 ===============
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# =============== 帮助信息 ===============
show_help() {
    cat << EOF
Containerd 镜像管理脚本

用法: bash containerd_image_manage.sh <操作> [参数]

操作:
    list                列出所有镜像
    ls                  同 list
    pull <镜像>         拉取镜像
    pull-all <列表>     批量拉取镜像 (镜像用空格分隔)
    push <镜像>         推送镜像到仓库
    inspect <镜像>      查看镜像详细信息
    info <镜像>         同 inspect
    remove <镜像>       删除镜像
    rm <镜像>           同 remove
    remove-all          删除所有镜像
    tag <镜像> <标签>   给镜像添加标签
    size                显示镜像大小
    search <名称>       搜索镜像 (需要连接到注册表)
    clean               清理未使用的镜像
    export <镜像> <文件> 导出镜像到文件
    import <文件> <镜像> 从文件导入镜像
    help                显示此帮助信息

镜像名称格式:
    alpine              (默认使用 docker.io)
    alpine:3.18
    docker.io/library/alpine:latest
    quay.io/name/image:tag
    registry.example.com/image:tag

示例:
    # 列出所有镜像
    bash containerd_image_manage.sh list
    
    # 拉取镜像
    bash containerd_image_manage.sh pull alpine:latest
    bash containerd_image_manage.sh pull docker.io/library/ubuntu:20.04
    bash containerd_image_manage.sh pull quay.io/podman/podman:latest
    
    # 批量拉取镜像
    bash containerd_image_manage.sh pull-all alpine:latest ubuntu:20.04 debian:stable
    
    # 查看镜像详细信息
    bash containerd_image_manage.sh inspect alpine:latest
    
    # 删除镜像
    bash containerd_image_manage.sh remove alpine:latest
    
    # 删除所有镜像 (危险操作)
    bash containerd_image_manage.sh remove-all
    
    # 清理未使用的镜像
    bash containerd_image_manage.sh clean

高级操作:
    # 给镜像添加标签
    ctr images tag docker.io/library/alpine:latest alpine:myversion
    
    # 导出镜像
    ctr images export image.tar alpine:latest
    
    # 导入镜像
    ctr images import image.tar

EOF
}

# =============== 检查环境 ===============
check_environment() {
    if ! command -v ctr >/dev/null 2>&1; then
        _red "✗ ctr 命令不可用"
        return 1
    fi
}

# =============== 列出镜像 ===============
list_images() {
    _blue "列出所有镜像:"
    echo
    
    if ctr images ls; then
        echo
        _green "✓ 镜像列表获取成功"
        return 0
    else
        _red "✗ 获取镜像列表失败"
        return 1
    fi
}

# =============== 拉取镜像 ===============
pull_image() {
    local image="$1"
    
    if [ -z "$image" ]; then
        _red "✗ 缺少镜像参数"
        return 1
    fi
    
    # 自动补全 docker.io 前缀
    if ! echo "$image" | grep -q "/"; then
        image="docker.io/library/$image"
    fi
    
    _yellow "拉取镜像: $image"
    echo
    
    if ctr images pull "$image"; then
        echo
        _green "✓ 镜像拉取成功"
        return 0
    else
        _red "✗ 镜像拉取失败"
        return 1
    fi
}

# =============== 批量拉取镜像 ===============
pull_images_batch() {
    local images=("$@")
    
    if [ ${#images[@]} -eq 0 ]; then
        _red "✗ 缺少镜像参数"
        return 1
    fi
    
    _yellow "批量拉取 ${#images[@]} 个镜像..."
    echo
    
    local success=0
    local failed=0
    
    for image in "${images[@]}"; do
        _yellow "拉取: $image"
        
        # 自动补全 docker.io 前缀
        if ! echo "$image" | grep -q "/"; then
            image="docker.io/library/$image"
        fi
        
        if ctr images pull "$image" >/dev/null 2>&1; then
            _green "  ✓ 成功"
            success=$((success + 1))
        else
            _red "  ✗ 失败"
            failed=$((failed + 1))
        fi
    done
    
    echo
    _blue "拉取结果: 成功 $success, 失败 $failed"
    
    if [ $failed -eq 0 ]; then
        _green "✓ 所有镜像拉取成功"
        return 0
    else
        _red "✗ 部分镜像拉取失败"
        return 1
    fi
}

# =============== 推送镜像 ===============
push_image() {
    local image="$1"
    
    if [ -z "$image" ]; then
        _red "✗ 缺少镜像参数"
        return 1
    fi
    
    _yellow "推送镜像: $image"
    echo
    
    if ctr images push "$image"; then
        echo
        _green "✓ 镜像推送成功"
        return 0
    else
        _red "✗ 镜像推送失败"
        return 1
    fi
}

# =============== 查看镜像信息 ===============
inspect_image() {
    local image="$1"
    
    if [ -z "$image" ]; then
        _red "✗ 缺少镜像参数"
        return 1
    fi
    
    # 自动补全 docker.io 前缀
    if ! echo "$image" | grep -q "/"; then
        image="docker.io/library/$image"
    fi
    
    _blue "镜像详细信息: $image"
    echo
    
    if ctr images info "$image" 2>/dev/null; then
        echo
        _green "✓ 镜像信息获取成功"
        return 0
    else
        _red "✗ 镜像不存在或获取信息失败"
        return 1
    fi
}

# =============== 删除镜像 ===============
remove_image() {
    local image="$1"
    
    if [ -z "$image" ]; then
        _red "✗ 缺少镜像参数"
        return 1
    fi
    
    # 自动补全 docker.io 前缀
    if ! echo "$image" | grep -q "/"; then
        image="docker.io/library/$image"
    fi
    
    _yellow "删除镜像: $image"
    
    if ctr images remove "$image" >/dev/null 2>&1; then
        _green "✓ 镜像已删除"
        return 0
    else
        _red "✗ 删除镜像失败"
        return 1
    fi
}

# =============== 删除所有镜像 ===============
remove_all_images() {
    _blue "删除所有镜像"
    echo
    
    _yellow "⚠ 此操作将删除所有镜像，请确认..."
    read -p "是否继续? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        _yellow "操作已取消"
        return 0
    fi
    
    local images=$(ctr images ls -q 2>/dev/null)
    
    if [ -z "$images" ]; then
        _yellow "没有镜像需要删除"
        return 0
    fi
    
    _yellow "删除镜像..."
    echo "$images" | while read -r image; do
        _yellow "  删除: $image"
        ctr images remove "$image" >/dev/null 2>&1 || true
    done
    
    echo
    _green "✓ 所有镜像已删除"
    return 0
}

# =============== 给镜像添加标签 ===============
tag_image() {
    local image="$1"
    local tag="$2"
    
    if [ -z "$image" ] || [ -z "$tag" ]; then
        _red "✗ 缺少参数"
        return 1
    fi
    
    # 自动补全 docker.io 前缀
    if ! echo "$image" | grep -q "/"; then
        image="docker.io/library/$image"
    fi
    
    _yellow "给镜像添加标签: $image → $tag"
    
    if ctr images tag "$image" "$tag" >/dev/null 2>&1; then
        _green "✓ 标签添加成功"
        return 0
    else
        _red "✗ 标签添加失败"
        return 1
    fi
}

# =============== 显示镜像大小 ===============
show_image_sizes() {
    _blue "镜像大小统计:"
    echo
    
    if ctr images ls -q 2>/dev/null | while read -r image; do
        local size=$(ctr images info "$image" 2>/dev/null | grep -o '"size":"[0-9]*' | cut -d'"' -f4)
        if [ -n "$size" ]; then
            printf "%-40s %10d bytes\n" "$image" "$size"
        fi
    done; then
        _green "✓ 大小统计完成"
        return 0
    else
        _yellow "⚠ 无法获取所有镜像的大小信息"
        return 0
    fi
}

# =============== 清理未使用镜像 ===============
clean_images() {
    _blue "清理未使用的镜像..."
    echo
    
    _yellow "检查未使用的镜像..."
    
    # 获取所有容器使用的镜像
    local used_images=$(ctr containers ls 2>/dev/null | awk '{print $2}' | grep -v ID)
    
    local removed=0
    
    # 遍历所有镜像，检查是否被使用
    ctr images ls -q 2>/dev/null | while read -r image; do
        if ! echo "$used_images" | grep -q "$image"; then
            _yellow "删除未使用的镜像: $image"
            if ctr images remove "$image" >/dev/null 2>&1; then
                removed=$((removed + 1))
            fi
        fi
    done
    
    echo
    _green "✓ 清理完成"
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
        list|ls)
            list_images
            ;;
        pull)
            pull_image "$2"
            ;;
        pull-all)
            shift
            pull_images_batch "$@"
            ;;
        push)
            push_image "$2"
            ;;
        inspect|info)
            inspect_image "$2"
            ;;
        remove|rm)
            remove_image "$2"
            ;;
        remove-all)
            remove_all_images
            ;;
        tag)
            tag_image "$2" "$3"
            ;;
        size)
            show_image_sizes
            ;;
        clean)
            clean_images
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
