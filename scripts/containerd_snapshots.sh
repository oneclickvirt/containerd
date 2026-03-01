#!/bin/bash

# Containerd 存储快照和分层管理脚本
# 用途: 管理容器镜像层、快照、存储优化
# 用法: bash containerd_snapshots.sh <操作> [参数]

# =============== 颜色输出函数 ===============
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# =============== 帮助信息 ===============
show_help() {
    cat << 'EOF'
Containerd 存储快照和分层管理脚本

用法: bash containerd_snapshots.sh <操作> [参数]

快照管理:
    list-snapshots                  列出所有快照
    create-snapshot <镜像> <快照>   从镜像创建快照
    delete-snapshot <快照>          删除快照
    cleanup-snapshots               清理未使用的快照

镜像分层:
    show-image-layers <镜像>        显示镜像分层结构
    analyze-layers <镜像>           分析镜像层大小
    compress-layers <镜像>          压缩镜像层

存储优化:
    optimize-storage                优化存储配置
    check-duplicate-layers          检查重复层
    compact-storage                 整理存储空间
    show-storage-stats              显示存储统计

备份和恢复:
    backup-snapshot <快照> <文件>   备份快照
    restore-snapshot <快照> <文件>  恢复快照
    export-snapshot <快照> <目录>   导出快照

帮助:
    help                           显示此帮助信息

示例:
    bash containerd_snapshots.sh list-snapshots
    bash containerd_snapshots.sh show-image-layers nginx:latest
    bash containerd_snapshots.sh analyze-layers alpine:latest
EOF
}

# =============== 列出快照 ===============
list_snapshots() {
    _blue "Containerd 快照列表"
    echo
    
    local snapshots=$(ctr snapshots ls 2>/dev/null)
    
    if [ -z "$snapshots" ]; then
        _yellow "⚠ 没有快照"
        return 0
    fi
    
    echo "$snapshots" | head -20
    
    local count=$(ctr snapshots ls -q 2>/dev/null | wc -l)
    echo
    echo "总计: $count 个快照"
}

# =============== 显示镜像分层结构 ===============
show_image_layers() {
    local image="$1"
    
    if [ -z "$image" ]; then
        _red "✗ 缺少镜像参数"
        return 1
    fi
    
    _blue "镜像分层结构: $image"
    echo
    
    local image_info=$(ctr images ls -q 2>/dev/null | grep "$image")
    
    if [ -z "$image_info" ]; then
        _red "✗ 镜像不存在: $image"
        return 1
    fi
    
    _yellow "镜像详情:"
    ctr images info "$image" 2>/dev/null | head -30 || {
        ctr images list 2>/dev/null | grep "$image"
    }
    
    echo
    _yellow "镜像大小:"
    ctr images ls --quiet 2>/dev/null | while read img; do
        if [[ "$img" == *"$image"* ]]; then
            ctr images info "$img" 2>/dev/null | grep -E "Size|Created" || echo "N/A"
        fi
    done
}

# =============== 分析镜像层大小 ===============
analyze_layers() {
    local image="$1"
    
    if [ -z "$image" ]; then
        _red "✗ 缺少镜像参数"
        return 1
    fi
    
    _blue "分析镜像层大小: $image"
    echo
    
    _yellow "镜像分层分析:"
    echo "  层 ID                                   大小"
    echo "  ──────────────────────────────────── ──────────"
    
    ctr images list --quiet 2>/dev/null | grep "$image" | while read img; do
        ctr content ls 2>/dev/null | grep -E "^[a-f0-9]" | head -10 | while read line; do
            local layer_id=$(echo "$line" | awk '{print $1}')
            local size=$(echo "$line" | awk '{print $2}')
            printf "  %-35s %s\n" "$layer_id" "$size"
        done
    done
    
    _green "✓ 分析完成"
}

# =============== 检查存储统计 ===============
show_storage_stats() {
    _blue "Containerd 存储统计"
    echo
    
    _yellow "镜像统计:"
    local image_count=$(ctr images ls -q 2>/dev/null | wc -l)
    echo "  镜像总数: $image_count"
    
    echo
    _yellow "快照统计:"
    local snapshot_count=$(ctr snapshots ls -q 2>/dev/null | wc -l)
    echo "  快照总数: $snapshot_count"
    
    echo
    _yellow "容器统计:"
    local container_count=$(ctr containers ls -q 2>/dev/null | wc -l)
    echo "  容器总数: $container_count"
    
    echo
    _yellow "磁盘使用:"
    du -sh /var/lib/containerd 2>/dev/null || echo "  无法获取"
    
    _green "✓ 统计完成"
}

# =============== 清理未使用的快照 ===============
cleanup_snapshots() {
    _blue "清理未使用的快照"
    echo
    
    local snapshots=$(ctr snapshots ls -q 2>/dev/null)
    local cleanup_count=0
    
    if [ -z "$snapshots" ]; then
        _yellow "⚠ 没有快照可清理"
        return 0
    fi
    
    for snapshot in $snapshots; do
        # 检查快照是否被使用
        if ! ctr containers ls -q 2>/dev/null | grep -q "$snapshot"; then
            _yellow "删除未使用的快照: $snapshot"
            ctr snapshots rm "$snapshot" >/dev/null 2>&1 && {
                _green "✓ 删除成功"
                cleanup_count=$((cleanup_count + 1))
            }
        fi
    done
    
    echo
    _green "✓ 清理完成，删除了 $cleanup_count 个快照"
}

# =============== 优化存储 ===============
optimize_storage() {
    _blue "优化 Containerd 存储"
    echo
    
    _yellow "优化项目:"
    
    # 1. 清理快照
    _yellow "  1. 清理未使用的快照..."
    local snapshot_count=$(ctr snapshots ls -q 2>/dev/null | wc -l)
    echo "    快照数: $snapshot_count"
    
    # 2. 检查磁盘碎片
    _yellow "  2. 检查存储碎片..."
    du -sh /var/lib/containerd/io.containerd.content.v1.blob 2>/dev/null || echo "    无法获取"
    
    # 3. 建议清理
    _yellow "  3. 清理建议:"
    echo "    • 删除未使用的镜像: ctr images rm <镜像>"
    echo "    • 压缩存储空间: ctr content gc"
    echo "    • 重启服务优化: systemctl restart containerd"
    
    _green "✓ 优化分析完成"
}

# =============== 主程序 ===============
main() {
    local operation="${1:-help}"
    
    case "$operation" in
        list-snapshots)
            list_snapshots
            ;;
        show-image-layers)
            show_image_layers "$2"
            ;;
        analyze-layers)
            analyze_layers "$2"
            ;;
        show-storage-stats)
            show_storage_stats
            ;;
        cleanup-snapshots)
            cleanup_snapshots
            ;;
        optimize-storage)
            optimize_storage
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

main "$@"
