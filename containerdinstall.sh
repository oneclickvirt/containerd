#!/bin/bash

# Containerd 环境一键安装脚本
# 用途: 在 Linux 系统上自动检测、安装和配置 Containerd 容器运行时

# 日期: 2025-03-01

# =============== 颜色输出函数 ===============
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# =============== 系统检测 ===============
detect_os() {
    # 检测操作系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        VER=$(lsb_release -sr)
    else
        _red "无法检测到操作系统"
        exit 1
    fi
    
    _blue "检测到系统: $OS $VER"
    
    # 检测架构
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        armv7l)
            ARCH="arm"
            ;;
    esac
    
    _blue "系统架构: $ARCH"
}

# =============== 检查必要条件 ===============
check_requirements() {
    _yellow "检查系统必要条件..."
    
    # 检查是否为 root 用户
    if [ "$EUID" -ne 0 ]; then
        _red "请使用 root 用户运行此脚本"
        exit 1
    fi
    
    # 检查网络连接
    if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
        _yellow "⚠ 网络连接可能不稳定"
    else
        _green "✓ 网络连接正常"
    fi
}

# =============== 安装依赖 ===============
install_dependencies() {
    _yellow "安装系统依赖..."
    
    case "$OS" in
        debian|ubuntu)
            apt-get update
            apt-get install -y \
                ca-certificates \
                curl \
                wget \
                git \
                iptables \
                net-tools \
                bridge-utils \
                gnupg \
                lsb-release \
                openssh-server \
                openssh-client
            ;;
        centos|rhel|fedora|rocky|almalinux)
            yum install -y \
                ca-certificates \
                curl \
                wget \
                git \
                iptables \
                net-tools \
                bridge-utils \
                openssl \
                openssh-server \
                openssh-clients
            ;;
        alpine)
            apk add --no-cache \
                ca-certificates \
                curl \
                wget \
                git \
                iptables \
                net-tools \
                bridge \
                openssh
            ;;
        *)
            _red "不支持的操作系统: $OS"
            exit 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        _green "✓ 系统依赖安装完成"
    else
        _red "✗ 系统依赖安装失败"
        exit 1
    fi
}

# =============== 下载并安装 Containerd ===============
install_containerd() {
    _yellow "安装 Containerd..."
    
    # 获取最新版本号
    local version=$(curl -s https://api.github.com/repos/containerd/containerd/releases/latest | grep tag_name | cut -d'"' -f4 | sed 's/v//')
    
    if [ -z "$version" ]; then
        _yellow "⚠ 无法获取最新版本，使用默认版本 1.7.0"
        version="1.7.0"
    fi
    
    _blue "Containerd 版本: $version"
    
    local download_url="https://github.com/containerd/containerd/releases/download/v${version}/containerd-${version}-linux-${ARCH}.tar.gz"
    local tmp_file="/tmp/containerd-${version}.tar.gz"
    
    # 下载
    _yellow "下载 Containerd (${version})..."
    if ! curl -L -o "$tmp_file" "$download_url" 2>/dev/null; then
        _red "✗ 下载失败"
        exit 1
    fi
    
    # 解压
    _yellow "解压 Containerd..."
    tar -xzf "$tmp_file" -C / 2>/dev/null
    
    # 清理
    rm -f "$tmp_file"
    
    _green "✓ Containerd 安装完成"
}

# =============== 下载并安装 runc ===============
install_runc() {
    _yellow "安装 runc..."
    
    # 获取最新版本号
    local version=$(curl -s https://api.github.com/repos/opencontainers/runc/releases/latest | grep tag_name | cut -d'"' -f4 | sed 's/v//')
    
    if [ -z "$version" ]; then
        _yellow "⚠ 无法获取最新版本，使用默认版本 1.1.0"
        version="1.1.0"
    fi
    
    _blue "runc 版本: $version"
    
    local download_url="https://github.com/opencontainers/runc/releases/download/v${version}/runc.${ARCH}"
    
    # 下载
    _yellow "下载 runc..."
    if ! curl -L -o /usr/local/sbin/runc "$download_url" 2>/dev/null; then
        _red "✗ 下载失败，尝试使用包管理器..."
        
        case "$OS" in
            debian|ubuntu)
                apt-get install -y runc
                ;;
            centos|rhel|fedora|rocky|almalinux)
                yum install -y runc
                ;;
            *)
                _red "✗ 无法安装 runc"
                exit 1
                ;;
        esac
    else
        chmod +x /usr/local/sbin/runc
        _green "✓ runc 安装完成"
    fi
}

# =============== 配置 Containerd ===============
configure_containerd() {
    _yellow "配置 Containerd..."
    
    # 创建配置目录
    mkdir -p /etc/containerd
    
    # 生成默认配置
    if command -v containerd >/dev/null 2>&1; then
        containerd config default > /etc/containerd/config.toml
        
        # 修改 systemd cgroup driver
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        
        _green "✓ Containerd 配置完成"
    else
        _red "✗ containerd 命令不可用"
        exit 1
    fi
}

# =============== 启用服务 ===============
enable_services() {
    _yellow "启用 Containerd 服务..."
    
    case "$OS" in
        alpine)
            # 检查是否存在 containerd systemd 服务文件
            if [ -f /usr/local/lib/systemd/system/containerd.service ]; then
                systemctl daemon-reload
                systemctl enable containerd
                systemctl start containerd
            else
                _yellow "⚠ Alpine 系统可能需要手动启动 Containerd"
            fi
            ;;
        *)
            # systemd 系统
            if [ -f /etc/systemd/system/containerd.service ] || [ -f /usr/lib/systemd/system/containerd.service ]; then
                systemctl daemon-reload
                systemctl enable containerd
                systemctl start containerd
            else
                _yellow "⚠ 找不到 containerd systemd 服务文件"
            fi
            ;;
    esac
    
    sleep 2
    
    if systemctl is-active --quiet containerd 2>/dev/null || pgrep -x containerd >/dev/null 2>&1; then
        _green "✓ Containerd 服务已启动"
    else
        _yellow "⚠ Containerd 服务状态异常"
    fi
}

# =============== 配置镜像源 ===============
setup_registry() {
    _yellow "配置容器镜像源..."
    
    # 这里可以添加多个镜像源配置
    # 示例配置在注释中
    
    cat >> /etc/containerd/config.toml << 'EOF'

# 镜像源配置
[plugins."io.containerd.grpc.v1.cri".registry.mirrors]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
    endpoint = ["https://registry-1.docker.io"]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."gcr.io"]
    endpoint = ["https://gcr.io"]
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."ghcr.io"]
    endpoint = ["https://ghcr.io"]
EOF
    
    # 重启 Containerd 以加载新配置
    systemctl restart containerd
    
    _green "✓ 镜像源配置完成"
}

# =============== 验证安装 ===============
verify_installation() {
    _yellow "验证 Containerd 安装..."
    
    # 检查 containerd
    if command -v containerd >/dev/null 2>&1; then
        CONTAINERD_VER=$(containerd --version)
        _green "✓ Containerd 已安装: $CONTAINERD_VER"
    else
        _red "✗ Containerd 未安装"
        exit 1
    fi
    
    # 检查 ctr 工具
    if command -v ctr >/dev/null 2>&1; then
        _green "✓ ctr 命令行工具可用"
    else
        _yellow "⚠ ctr 命令行工具不可用"
    fi
    
    # 检查 runc
    if command -v runc >/dev/null 2>&1; then
        RUNC_VER=$(runc --version | head -1)
        _green "✓ runc 已安装: $RUNC_VER"
    else
        _red "✗ runc 未安装"
        exit 1
    fi
}

# =============== 创建工作目录 ===============
setup_working_dirs() {
    _yellow "创建工作目录..."
    
    mkdir -p /var/lib/containerd
    mkdir -p /var/log/containerd
    mkdir -p /etc/containerd/certs.d
    
    chmod 755 /var/lib/containerd
    chmod 755 /var/log/containerd
    
    _green "✓ 工作目录已创建"
}

# =============== 主程序 ===============
main() {
    _blue "============================================"
    _blue "  Containerd 容器运行时一键安装脚本"
    _blue "  Version: 1.0.0"
    _blue "  Date: 2025-03-01"
    _blue "============================================"
    echo
    
    # 执行各个步骤
    detect_os
    check_requirements
    install_dependencies
    install_containerd
    install_runc
    configure_containerd
    setup_working_dirs
    enable_services
    setup_registry
    verify_installation
    
    echo
    _green "============================================"
    _green "  ✓ Containerd 安装完成！"
    _green "============================================"
    echo
    _blue "接下来的步骤:"
    _yellow "1. 拉取镜像: ctr images pull docker.io/library/alpine:latest"
    _yellow "2. 创建容器: bash scripts/containerd_create_container.sh"
    _yellow "3. 查看文档: https://containerd.io/docs/"
    echo
}

# 执行主程序
main "$@"
