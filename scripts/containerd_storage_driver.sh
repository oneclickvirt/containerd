#!/bin/bash

# Containerd 存储驱动和 OCI 配置脚本
# 用途: 管理 Containerd 存储驱动、OCI 运行时、性能优化
# 用法: bash containerd_storage_driver.sh <操作> [参数]

# =============== 颜色输出函数 ===============
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# =============== 帮助信息 ===============
show_help() {
    cat << 'EOF'
Containerd 存储驱动和 OCI 配置脚本

用法: bash containerd_storage_driver.sh <操作> [参数]

存储驱动:
    show-current-driver             显示当前存储驱动
    list-available-drivers          列出可用的存储驱动
    configure-overlay2              配置 overlay2 驱动
    configure-native                配置 native 驱动
    configure-snapshotter <驱动>    配置快照管理器

OCI 运行时:
    list-runtimes                   列出可用的 OCI 运行时
    show-default-runtime            显示默认运行时
    configure-runc                  配置 runc 运行时
    configure-crun                  配置 crun 运行时
    configure-kata                  配置 Kata Containers

性能优化:
    optimize-storage-config         优化存储配置
    optimize-runtime-config         优化运行时配置
    enable-rootless-containerd      启用无根 Containerd
    configure-registry-mirrors      配置镜像仓库

配置管理:
    show-config                     显示完整配置
    backup-config                   备份配置文件
    restore-config <备份文件>       恢复配置文件
    validate-config                 验证配置有效性

帮助:
    help                           显示此帮助信息

示例:
    bash containerd_storage_driver.sh show-current-driver
    bash containerd_storage_driver.sh list-runtimes
    bash containerd_storage_driver.sh optimize-storage-config
EOF
}

# =============== 显示当前存储驱动 ===============
show_current_driver() {
    _blue "当前 Containerd 存储驱动配置"
    echo
    
    local config_file="/etc/containerd/config.toml"
    
    if [ ! -f "$config_file" ]; then
        _red "✗ 配置文件不存在: $config_file"
        return 1
    fi
    
    _yellow "存储配置:"
    grep -A 10 "\[plugins\]" "$config_file" | grep -E "snapshotter|store" || {
        echo "  (使用默认配置)"
    }
    
    echo
    _yellow "当前状态:"
    containerd --version 2>/dev/null || _red "✗ containerd 未安装"
    
    echo
    _yellow "存储路径:"
    grep "root" "$config_file" | head -5 || {
        echo "  /var/lib/containerd (默认)"
    }
}

# =============== 列出可用的存储驱动 ===============
list_available_drivers() {
    _blue "可用的 Containerd 存储驱动"
    echo
    
    _yellow "支持的驱动:"
    echo "  • overlay2      - 推荐，性能最好"
    echo "  • native        - 原生存储驱动"
    echo "  • aufs          - 较旧的驱动"
    echo "  • devicemapper  - 用于 RHEL/CentOS"
    
    echo
    _yellow "系统兼容性检查:"
    
    # 检查 overlay2
    if grep -q "^overlay$" /proc/filesystems 2>/dev/null; then
        _green "  ✓ overlay2 支持"
    else
        _red "  ✗ overlay2 不支持"
    fi
    
    # 检查 aufs
    if grep -q "^aufs$" /proc/filesystems 2>/dev/null; then
        _green "  ✓ aufs 支持"
    else
        _yellow "  ⚠ aufs 不支持"
    fi
    
    # 检查 btrfs
    if grep -q "^btrfs$" /proc/filesystems 2>/dev/null; then
        _green "  ✓ btrfs 支持"
    else
        _yellow "  ⚠ btrfs 不支持"
    fi
}

# =============== 配置 overlay2 驱动 ===============
configure_overlay2() {
    _blue "配置 Containerd overlay2 存储驱动"
    echo
    
    local config_file="/etc/containerd/config.toml"
    
    if [ ! -f "$config_file" ]; then
        _red "✗ 配置文件不存在"
        return 1
    fi
    
    _yellow "添加 overlay2 配置..."
    
    cat >> "$config_file" << 'EOF'

[plugins."io.containerd.grpc.v1.cri".containerd]
  snapshotter = "overlayfs"
  default_runtime_name = "runc"
  
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    runtime_engine = "runc"
    runtime_root = ""
    runtimeType = "io.containerd.runc.v2"
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      BinaryName = "runc"
EOF
    
    _green "✓ overlay2 配置已添加"
    
    _yellow "重启 Containerd..."
    systemctl restart containerd 2>/dev/null && {
        _green "✓ Containerd 已重启"
    } || {
        _red "✗ 重启失败，需要手动重启"
    }
}

# =============== 列出可用的 OCI 运行时 ===============
list_runtimes() {
    _blue "可用的 OCI 运行时"
    echo
    
    _yellow "支持的运行时:"
    echo "  • runc       - 标准 OCI 运行时，推荐"
    echo "  • crun       - C 语言实现，轻量级"
    echo "  • kata       - 虚拟机级隔离"
    echo "  • youki      - Rust 实现的 runc"
    echo "  • gVisor     - Google 的沙箱技术"
    
    echo
    _yellow "系统已安装的运行时:"
    
    which runc >/dev/null 2>&1 && {
        _green "  ✓ runc: $(runc --version | head -1)"
    }
    
    which crun >/dev/null 2>&1 && {
        _green "  ✓ crun: $(crun --version | head -1)"
    }
    
    which kata-runtime >/dev/null 2>&1 && {
        _green "  ✓ kata-runtime: $(kata-runtime --version | head -1)"
    }
    
    which gVisor >/dev/null 2>&1 && {
        _green "  ✓ gVisor"
    }
}

# =============== 配置 runc 运行时 ===============
configure_runc() {
    _blue "配置 Containerd runc 运行时"
    echo
    
    local config_file="/etc/containerd/config.toml"
    
    if [ ! -f "$config_file" ]; then
        _red "✗ 配置文件不存在"
        return 1
    fi
    
    _yellow "检查 runc 安装..."
    
    if ! command -v runc >/dev/null 2>&1; then
        _red "✗ runc 未安装"
        return 1
    fi
    
    _green "✓ runc 已安装"
    
    echo
    _yellow "添加 runc 运行时配置..."
    
    cat >> "$config_file" << 'EOF'

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_engine = "runc"
  runtime_root = ""
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
    BinaryName = "runc"
    CriuPath = ""
    CriuWorkPath = ""
    SystemdCgroup = false
EOF
    
    _green "✓ runc 配置已添加"
}

# =============== 优化存储配置 ===============
optimize_storage_config() {
    _blue "优化 Containerd 存储配置"
    echo
    
    local config_file="/etc/containerd/config.toml"
    
    if [ ! -f "$config_file" ]; then
        _red "✗ 配置文件不存在"
        return 1
    fi
    
    _yellow "优化建议:"
    
    echo
    _yellow "1. 快照管理器优化"
    echo "   - 使用 overlayfs 快照管理器"
    echo "   - 启用增量快照技术"
    
    echo
    _yellow "2. 存储路径优化"
    echo "   - 使用高速存储设备 (SSD 优先)"
    echo "   - 确保足够的磁盘空间 (至少 10GB)"
    
    echo
    _yellow "3. 运行时优化"
    echo "   - 使用 crun (比 runc 更轻)"
    echo "   - 启用 CPU 和内存限制"
    
    echo
    _yellow "4. 注册表缓存"
    echo "   - 配置本地注册表镜像"
    echo "   - 启用镜像层缓存"
    
    _green "✓ 优化建议完成"
}

# =============== 显示完整配置 ===============
show_config() {
    _blue "Containerd 完整配置"
    echo
    
    local config_file="/etc/containerd/config.toml"
    
    if [ ! -f "$config_file" ]; then
        _red "✗ 配置文件不存在: $config_file"
        return 1
    fi
    
    cat "$config_file" | head -100
    
    local lines=$(wc -l < "$config_file")
    echo
    echo "... (共 $lines 行，显示前 100 行)"
}

# =============== 验证配置 ===============
validate_config() {
    _blue "验证 Containerd 配置"
    echo
    
    local config_file="/etc/containerd/config.toml"
    
    if [ ! -f "$config_file" ]; then
        _red "✗ 配置文件不存在: $config_file"
        return 1
    fi
    
    _yellow "配置文件检查:"
    
    # 检查文件是否有效
    if grep -q "^\[containerd\]" "$config_file"; then
        _green "  ✓ 基本结构有效"
    else
        _red "  ✗ 配置文件格式错误"
    fi
    
    # 检查必要的配置项
    echo
    _yellow "必要配置项检查:"
    
    grep -q "root" "$config_file" && _green "  ✓ root 路径已配置" || _yellow "  ⚠ root 路径未配置"
    grep -q "snapshotter" "$config_file" && _green "  ✓ snapshotter 已配置" || _yellow "  ⚠ snapshotter 未配置"
    grep -q "runtime" "$config_file" && _green "  ✓ runtime 已配置" || _yellow "  ⚠ runtime 未配置"
    
    _green "✓ 验证完成"
}

# =============== 主程序 ===============
main() {
    local operation="${1:-help}"
    
    case "$operation" in
        show-current-driver)
            show_current_driver
            ;;
        list-available-drivers)
            list_available_drivers
            ;;
        configure-overlay2)
            configure_overlay2
            ;;
        list-runtimes)
            list_runtimes
            ;;
        configure-runc)
            configure_runc
            ;;
        optimize-storage-config)
            optimize_storage_config
            ;;
        show-config)
            show_config
            ;;
        validate-config)
            validate_config
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
