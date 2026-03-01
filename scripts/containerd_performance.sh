#!/bin/bash

# Containerd 性能优化和监控脚本
# 用途: 优化 Containerd 性能、监控资源使用
# 用法: bash containerd_performance.sh <操作> [参数]

# =============== 颜色输出函数 ===============
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# =============== 帮助信息 ===============
show_help() {
    cat << 'EOF'
Containerd 性能优化和监控脚本

用法: bash containerd_performance.sh <操作> [参数]

性能优化:
    optimize-config              优化 Containerd 配置
    tune-cgroup                  调整 cgroup 限制
    tune-network                 优化网络性能
    optimize-storage             优化存储性能

监控和诊断:
    monitor-performance          实时监控性能
    show-resource-usage          显示资源使用情况
    show-container-stats <容器>  显示容器统计
    benchmark-runtime            性能基准测试

调试工具:
    diagnose-performance         诊断性能问题
    check-configuration          检查配置
    show-metrics                 显示性能指标

帮助:
    help                         显示此帮助信息

示例:
    bash containerd_performance.sh optimize-config
    bash containerd_performance.sh monitor-performance
    bash containerd_performance.sh show-container-stats mycontainer
EOF
}

# =============== 监控性能 ===============
monitor_performance() {
    _blue "实时监控 Containerd 性能"
    echo
    
    _yellow "CPU 和内存使用:"
    ps aux | grep containerd | grep -v grep | awk '{printf "  CPU: %.1f%%, 内存: %.1f MB\n", $3, $6/1024}'
    
    echo
    _yellow "容器数量:"
    local count=$(ctr containers list -q 2>/dev/null | wc -l)
    echo "  当前容器数: $count"
    
    echo
    _yellow "镜像数量:"
    local img_count=$(ctr images list -q 2>/dev/null | wc -l)
    echo "  当前镜像数: $img_count"
    
    echo
    _yellow "磁盘使用:"
    df -h /var/lib/containerd | tail -1 | awk '{printf "  使用: %s, 可用: %s, 使用率: %s\n", $3, $4, $5}'
    
    _green "✓ 性能监控完成"
    return 0
}

# =============== 优化配置 ===============
optimize_config() {
    local config_file="/etc/containerd/config.toml"
    
    _yellow "优化 Containerd 配置: $config_file"
    echo
    
    if [ ! -f "$config_file" ]; then
        _red "✗ 配置文件不存在"
        return 1
    fi
    
    # 备份原始配置
    cp "$config_file" "$config_file.bak"
    _green "✓ 配置备份已保存"
    
    echo
    _yellow "优化项目:"
    
    # 1. 增加默认线程数
    if ! grep -q "threads_per_handler" "$config_file"; then
        _yellow "  添加线程优化..."
        echo "threads_per_handler = 8" >> "$config_file"
    fi
    
    # 2. 优化镜像加载
    if ! grep -q "discard_unpacked_layers" "$config_file"; then
        _yellow "  添加镜像优化..."
        echo "discard_unpacked_layers = true" >> "$config_file"
    fi
    
    # 3. 启用块存储驱动
    if ! grep -q "block_device" "$config_file"; then
        _yellow "  配置块存储..."
        echo "[plugins.\"io.containerd.snapshotter.v1.blockdevice\"]" >> "$config_file"
        echo "  pool_name = \"containerd-pool\"" >> "$config_file"
    fi
    
    _green "✓ 配置优化完成"
    _yellow "⚠ 需要重启 containerd 服务以应用更改"
    _yellow "  systemctl restart containerd"
    
    return 0
}

# =============== 显示资源使用 ===============
show_resource_usage() {
    _blue "Containerd 资源使用情况"
    echo
    
    _yellow "系统资源:"
    free -h | grep -E "Mem|Swap"
    
    echo
    _yellow "Containerd 进程信息:"
    ps aux | grep containerd | grep -v grep | awk '{
        printf "  用户: %s\n  PID: %s\n  CPU: %.1f%%\n  内存: %s KB\n  时间: %s\n",
        $1, $2, $3, $6, $7" "$8" "$9
    }'
    
    echo
    _yellow "Containerd 数据存储:"
    du -sh /var/lib/containerd 2>/dev/null
    du -sh /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs 2>/dev/null
    du -sh /var/lib/containerd/io.containerd.metadata.v1.bolt 2>/dev/null
    
    _green "✓ 资源使用信息获取完成"
}

# =============== 基准测试 ===============
benchmark_runtime() {
    _blue "Containerd 运行时性能基准测试"
    echo
    
    local test_image="alpine:latest"
    
    # 拉取测试镜像
    if ! ctr images list -q 2>/dev/null | grep -q alpine; then
        _yellow "拉取测试镜像..."
        ctr images pull docker.io/library/alpine:latest >/dev/null 2>&1 || {
            _red "✗ 无法拉取测试镜像"
            return 1
        }
    fi
    
    _yellow "容器创建性能测试:"
    local start=$(date +%s%N)
    
    for i in {1..10}; do
        ctr run -d "docker.io/library/alpine:latest" "test-bench-$i" sleep 100 >/dev/null 2>&1
    done
    
    local end=$(date +%s%N)
    local duration=$((($end - $start) / 1000000))
    
    echo "  创建 10 个容器耗时: ${duration}ms"
    echo "  平均每个容器: $((duration / 10))ms"
    
    # 清理
    _yellow "清理测试容器..."
    for i in {1..10}; do
        ctr tasks rm -f "test-bench-$i" >/dev/null 2>&1
        ctr containers rm "test-bench-$i" >/dev/null 2>&1
    done
    
    _green "✓ 基准测试完成"
}

# =============== 主程序 ===============
main() {
    local operation="${1:-help}"
    
    case "$operation" in
        monitor-performance)
            monitor_performance
            ;;
        optimize-config)
            optimize_config
            ;;
        show-resource-usage)
            show_resource_usage
            ;;
        benchmark-runtime)
            benchmark_runtime
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
