#!/bin/bash
# from
# https://github.com/oneclickvirt/containerd
# 2026.03.01
#
# Supported environment variables (non-interactive mode / 支持的环境变量，可实现无交互安装):
#   WITHOUTCDN=TRUE             - Disable CDN acceleration / 禁用 CDN 加速
#   NEED_DISK_LIMIT=y           - Enable container disk size limitation (btrfs) / 启用容器磁盘大小限制 (btrfs)；默认: n
#   CONTAINERD_INSTALL_PATH=    - containerd data root path / containerd 数据根路径；默认: /var/lib/containerd
#   CONTAINERD_POOL_SIZE=20     - Storage pool size in GB / 存储池大小（GB），NEED_DISK_LIMIT=y 时必填
#   CONTAINERD_LOOP_FILE=       - Loop file path / 循环文件路径；默认: /opt/containerd-pool.img
#
# Example / 示例:
#   NEED_DISK_LIMIT=y CONTAINERD_POOL_SIZE=20 bash containerdinstall.sh
#   CONTAINERD_INSTALL_PATH=/data/containerd bash containerdinstall.sh

_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$*\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
export DEBIAN_FRONTEND=noninteractive
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
    _yellow "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
fi
if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi
if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi

# ======== 系统检测 ========
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch" "Alpine")
PACKAGE_UPDATE=(
    "! apt-get update && apt-get --fix-broken install -y && apt-get update"
    "apt-get update"
    "yum -y update"
    "yum -y update"
    "yum -y update"
    "pacman -Sy"
    "apk update"
)
PACKAGE_INSTALL=(
    "apt-get -y install"
    "apt-get -y install"
    "yum -y install"
    "yum -y install"
    "yum -y install"
    "pacman -Sy --noconfirm"
    "apk add --no-cache"
)

CMD=(
    "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)"
    "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)"
    "$(lsb_release -sd 2>/dev/null)"
    "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)"
    "$(grep . /etc/redhat-release 2>/dev/null)"
    "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')"
    "$(grep . /etc/alpine-release 2>/dev/null)"
)
SYS="${CMD[0]}"
[[ -n $SYS ]] || SYS="${CMD[1]}"
[[ -n $SYS ]] || SYS="${CMD[2]}"
[[ -n $SYS ]] || SYS="${CMD[3]}"
[[ -n $SYS ]] || SYS="${CMD[4]}"
[[ -n $SYS ]] || SYS="${CMD[5]}"
[[ -n $SYS ]] || SYS="${CMD[6]}"
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done
if [[ -z $SYSTEM ]]; then
    _red "ERROR: The script does not support the current system!"
    exit 1
fi

# ======== 架构检测 ========
ARCH_UNAME=$(uname -m)
case "$ARCH_UNAME" in
    x86_64)  ARCH_TYPE="amd64" ;;
    aarch64) ARCH_TYPE="arm64" ;;
    armv7l)  ARCH_TYPE="arm"   ;;
    *)
        _red "Unsupported arch: $ARCH_UNAME"
        exit 1
        ;;
esac
_blue "Detected system: $SYSTEM  arch: $ARCH_TYPE"

# ======== CDN 检测 ========
WITHOUTCDN_UPPER=$(echo "${WITHOUTCDN:-}" | tr '[:lower:]' '[:upper:]')
WITHOUT_CDN="false"
if [[ "$WITHOUTCDN_UPPER" == "TRUE" ]]; then
    WITHOUT_CDN="true"
fi

cdn_urls=("https://cdn0.spiritlhl.top/" "http://cdn1.spiritlhl.net/" "http://cdn2.spiritlhl.net/" "http://cdn3.spiritlhl.net/" "http://cdn4.spiritlhl.net/")
cdn_success_url=""

check_cdn() {
    local o_url=$1
    local shuffled_cdn_urls=($(shuf -e "${cdn_urls[@]}"))
    for cdn_url in "${shuffled_cdn_urls[@]}"; do
        if curl -4 -sL -k "${cdn_url}${o_url}" --max-time 6 | grep -q "success" >/dev/null 2>&1; then
            export cdn_success_url="$cdn_url"
            return
        fi
        sleep 0.5
    done
    export cdn_success_url=""
}

check_cdn_file() {
    if [[ "$WITHOUT_CDN" == "true" ]]; then
        export cdn_success_url=""
        _yellow "WITHOUTCDN=TRUE detected, CDN acceleration disabled"
        return
    fi
    check_cdn "https://raw.githubusercontent.com/spiritLHLS/ecs/main/back/test"
    if [ -n "$cdn_success_url" ]; then
        _yellow "CDN available, using CDN: $cdn_success_url"
    else
        _yellow "No CDN available, using direct connection"
    fi
}

check_cdn_file

# ======== 工具函数 ========
SYSCTL_CONF="/etc/sysctl.d/99-containerd.conf"

update_sysctl() {
    local key="${1%%=*}"
    local val="${1##*=}"
    mkdir -p /etc/sysctl.d
    if grep -q "^${key}" "$SYSCTL_CONF" 2>/dev/null; then
        sed -i "s|^${key}.*|${key}=${val}|g" "$SYSCTL_CONF"
    else
        echo "${key}=${val}" >> "$SYSCTL_CONF"
    fi
    sysctl -w "${key}=${val}" >/dev/null 2>&1 || true
}

is_private_ipv6() {
    local addr="$1"
    [[ "$addr" =~ ^fd ]] && return 0
    [[ "$addr" =~ ^fc ]] && return 0
    [[ "$addr" =~ ^fe[89ab] ]] && return 0
    [[ "$addr" == "::1" ]] && return 0
    return 1
}

# ======== 检测公网 IPv6 ========
check_ipv6() {
    IPV6=$(ip -6 addr show 2>/dev/null | grep global | awk '{print length, $2}' | sort -nr | head -n 1 | awk '{print $2}' | cut -d '/' -f1)
    if [[ -z "$IPV6" ]] || is_private_ipv6 "$IPV6"; then
        IPV6=""
        local API_NET=("https://ipv6.ip.sb" "https://ipget.net" "https://ipv6.ping0.cc" "https://api.my-ip.io/ip" "https://ipv6.icanhazip.com")
        for p in "${API_NET[@]}"; do
            local response
            response=$(curl -sLk6m8 "$p" 2>/dev/null | tr -d '[:space:]')
            if [[ $? -eq 0 ]] && echo "$response" | grep -qE '^[0-9a-fA-F:]+$' && echo "$response" | grep -q ':'; then
                IPV6="$response"
                break
            fi
            sleep 1
        done
    fi
    if [[ -n "$IPV6" ]] && ! is_private_ipv6 "$IPV6"; then
        _green "Detected public IPv6: $IPV6"
        IPV6_ENABLED=true
    else
        _yellow "No public IPv6 detected"
        IPV6_ENABLED=false
    fi
}

# ======== 检测主网络接口 ========
detect_interface() {
    interface=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    if [[ -z "$interface" ]]; then
        interface=$(ip link show | awk '/^[0-9]+: /{gsub(":", "", $2); if($2!="lo") {print $2; exit}}')
    fi
    _blue "Main network interface: $interface"
    echo "$interface" > /usr/local/bin/containerd_main_interface
}

# ======== btrfs 存储驱动支持 ========
check_storage_driver_support() {
    local driver="$1"
    case "$driver" in
        "btrfs")
            if command -v btrfs >/dev/null 2>&1; then
                modprobe btrfs 2>/dev/null || true
                return 0
            fi
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

install_storage_driver() {
    local driver="$1"
    local need_reboot=false
    case "$driver" in
        "btrfs")
            if ! command -v btrfs >/dev/null 2>&1; then
                _yellow "Installing btrfs-progs..."
                case $SYSTEM in
                    Debian|Ubuntu)
                        ${PACKAGE_INSTALL[int]} btrfs-progs 2>/dev/null || true
                        ;;
                    CentOS|Fedora)
                        ${PACKAGE_INSTALL[int]} btrfs-progs 2>/dev/null || true
                        ;;
                    Alpine)
                        ${PACKAGE_INSTALL[int]} btrfs-progs 2>/dev/null || true
                        ;;
                    *)
                        ${PACKAGE_INSTALL[int]} btrfs-progs 2>/dev/null || true
                        ;;
                esac
                modprobe btrfs 2>/dev/null || true
                if ! check_storage_driver_support "btrfs"; then
                    _yellow "btrfs module could not be loaded, a reboot is required."
                    _yellow "btrfs 模块无法加载，需要重启系统。"
                    need_reboot=true
                fi
            fi
            ;;
    esac
    if [ "$need_reboot" = true ]; then
        echo "$driver" > /usr/local/bin/containerd_storage_reboot
        _green "Storage driver $driver installed. System will reboot in 5 seconds to load kernel modules."
        _green "存储驱动 $driver 已安装。系统将在5秒后重启以加载内核模块。"
        _yellow "重启后请再次执行本脚本以继续安装（仅 btrfs 磁盘限制场景需要此步骤）。"
        sleep 5
        reboot
        exit 0
    fi
}

setup_containerd_btrfs_loop() {
    local pool_size_gb="$1"
    local loop_file="$2"
    local mount_point="$3"
    _yellow "Setting up containerd btrfs loop filesystem..."
    local loop_dir
    loop_dir=$(dirname "$loop_file")
    if [ ! -d "$loop_dir" ]; then
        mkdir -p "$loop_dir"
    fi
    # 若 containerd 正在运行，先停止
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet containerd 2>/dev/null; then
        systemctl stop containerd 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1 && rc-service containerd status >/dev/null 2>&1; then
        rc-service containerd stop 2>/dev/null || true
    fi
    # 若 loop 文件已存在且已挂载，则跳过格式化以避免损坏已有数据
    if [ -f "$loop_file" ] && losetup -j "$loop_file" 2>/dev/null | grep -q "$loop_file"; then
        _green "Loop file $loop_file already exists and is attached, skipping creation."
        local loop_device
        loop_device=$(losetup -j "$loop_file" | cut -d: -f1)
        mkdir -p "$mount_point"
        mount "$loop_device" "$mount_point" 2>/dev/null || true
        echo "$loop_device" > /usr/local/bin/containerd_loop_device
        echo "$loop_file" > /usr/local/bin/containerd_loop_file
        echo "$mount_point" > /usr/local/bin/containerd_mount_point
        return
    fi
    if [ -d "$mount_point" ] && [ "$(ls -A "$mount_point" 2>/dev/null)" ]; then
        _yellow "Backing up existing containerd data at $mount_point ..."
        mv "$mount_point" "${mount_point}.backup.$(date +%Y%m%d-%H%M%S)"
    fi
    _yellow "Creating ${pool_size_gb}GB loop file at $loop_file ..."
    fallocate -l "${pool_size_gb}G" "$loop_file"
    local loop_device
    loop_device=$(losetup --find --show "$loop_file")
    _green "Loop device created: $loop_device"
    _yellow "Creating btrfs filesystem on $loop_device ..."
    mkfs.btrfs -f "$loop_device"
    mkdir -p "$mount_point"
    mount "$loop_device" "$mount_point"
    if ! grep -q "$loop_file" /etc/fstab; then
        echo "$loop_file $mount_point btrfs loop,defaults 0 0" >> /etc/fstab
    fi
    chmod 755 "$mount_point"
    _green "containerd btrfs loop filesystem setup completed"
    echo "$loop_device" > /usr/local/bin/containerd_loop_device
    echo "$loop_file" > /usr/local/bin/containerd_loop_file
    echo "$mount_point" > /usr/local/bin/containerd_mount_point
}

try_storage_drivers() {
    local need_disk_limit="false"
    if [ -f /usr/local/bin/containerd_need_disk_limit ]; then
        need_disk_limit=$(cat /usr/local/bin/containerd_need_disk_limit)
    fi
    if [ "$need_disk_limit" != "true" ]; then
        _yellow "Using overlayfs snapshotter (standard installation, no disk size limitation)."
        _yellow "使用 overlayfs 快照器（标准安装，无硬盘大小限制）。"
        echo "overlayfs" > /usr/local/bin/containerd_storage_driver
        return 0
    fi
    # 处理重启后检测
    if [ -f /usr/local/bin/containerd_storage_reboot ]; then
        local reboot_driver
        reboot_driver=$(cat /usr/local/bin/containerd_storage_reboot)
        rm -f /usr/local/bin/containerd_storage_reboot
        _green "System rebooted. Checking storage driver: $reboot_driver"
        if check_storage_driver_support "$reboot_driver"; then
            echo "$reboot_driver" > /usr/local/bin/containerd_storage_driver
            return 0
        else
            _yellow "Storage driver $reboot_driver still not available after reboot. Falling back to overlayfs."
            echo "overlayfs" > /usr/local/bin/containerd_storage_driver
            return 0
        fi
    fi
    if [ -f /usr/local/bin/containerd_storage_driver ]; then
        _green "containerd storage driver already configured: $(cat /usr/local/bin/containerd_storage_driver)"
        return 0
    fi
    if check_storage_driver_support "btrfs"; then
        _green "btrfs is available, using btrfs snapshotter."
        echo "btrfs" > /usr/local/bin/containerd_storage_driver
        return 0
    else
        _yellow "Trying to install btrfs storage driver..."
        install_storage_driver "btrfs"
        if check_storage_driver_support "btrfs"; then
            echo "btrfs" > /usr/local/bin/containerd_storage_driver
            return 0
        else
            _yellow "btrfs installation failed. Falling back to overlayfs (no disk limit support)."
            echo "overlayfs" > /usr/local/bin/containerd_storage_driver
            return 0
        fi
    fi
}

# ======== 安装基础依赖 ========
install_base_deps() {
    _yellow "Installing base dependencies..."
    case $SYSTEM in
        Debian|Ubuntu)
            eval "${PACKAGE_UPDATE[int]}" 2>/dev/null || true
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates nftables iptables iproute2 \
                socat unzip tar jq 2>/dev/null || true
            ;;
        CentOS|Fedora)
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates nftables iptables iproute \
                socat unzip tar jq 2>/dev/null || true
            ;;
        Alpine)
            ${PACKAGE_UPDATE[int]} 2>/dev/null || true
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates nftables iptables iproute2 \
                socat unzip tar jq 2>/dev/null || true
            ;;
    esac
    _green "Base dependencies installed"
}

# ======== 安装 nerdctl-full (containerd + runc + nerdctl + CNI + buildkitd) ========
install_containerd_stack() {
    _yellow "Installing containerd stack (nerdctl-full bundle)..."

    local nerdctl_ver
    nerdctl_ver=$(curl -sL --connect-timeout 10 --max-time 15 \
        "https://api.github.com/repos/containerd/nerdctl/releases/latest" 2>/dev/null \
        | grep tag_name | cut -d'"' -f4 | sed 's/v//')
    if [[ -z "$nerdctl_ver" ]]; then
        nerdctl_ver="2.0.4"
    fi
    _blue "nerdctl version: $nerdctl_ver"

    local tarfile="nerdctl-full-${nerdctl_ver}-linux-${ARCH_TYPE}.tar.gz"
    local direct_url="https://github.com/containerd/nerdctl/releases/download/v${nerdctl_ver}/${tarfile}"
    local cdn_url="${cdn_success_url}${direct_url}"
    local tmp_tar
    tmp_tar=$(mktemp /tmp/nerdctl-full-XXXXXX.tar.gz)

    _yellow "Downloading nerdctl-full (this may take a while)..."
    local downloaded=false

    # Try CDN first (only if cdn_success_url is set)
    if [[ -n "$cdn_success_url" ]]; then
        _yellow "Trying CDN: $cdn_url"
        if curl -L --connect-timeout 30 --max-time 600 -o "$tmp_tar" "$cdn_url" 2>/dev/null; then
            local fsize
            fsize=$(stat -c%s "$tmp_tar" 2>/dev/null || stat -f%z "$tmp_tar" 2>/dev/null || echo 0)
            if [[ "$fsize" -gt 10485760 ]]; then  # must be >10MB
                if tar -tzf "$tmp_tar" >/dev/null 2>&1; then
                    downloaded=true
                    _green "CDN download successful (${fsize} bytes)"
                else
                    _yellow "CDN download corrupt (not valid gzip), trying direct..."
                fi
            else
                _yellow "CDN download too small (${fsize} bytes), trying direct..."
            fi
        fi
    fi

    # Fall back to direct GitHub
    if [[ "$downloaded" == "false" ]]; then
        _yellow "Trying direct GitHub: $direct_url"
        rm -f "$tmp_tar"
        tmp_tar=$(mktemp /tmp/nerdctl-full-XXXXXX.tar.gz)
        if curl -L --connect-timeout 30 --max-time 600 -o "$tmp_tar" "$direct_url" 2>/dev/null; then
            local fsize
            fsize=$(stat -c%s "$tmp_tar" 2>/dev/null || stat -f%z "$tmp_tar" 2>/dev/null || echo 0)
            if [[ "$fsize" -gt 10485760 ]] && tar -tzf "$tmp_tar" >/dev/null 2>&1; then
                downloaded=true
                _green "Direct download successful (${fsize} bytes)"
            fi
        fi
    fi

    if [[ "$downloaded" == "false" ]]; then
        _red "Failed to download nerdctl-full from CDN and direct GitHub"
        rm -f "$tmp_tar"
        exit 1
    fi

    if ! tar -C /usr/local -xzf "$tmp_tar"; then
        _red "Failed to extract nerdctl-full"
        rm -f "$tmp_tar"
        exit 1
    fi
    rm -f "$tmp_tar"

    # Verify critical binaries were extracted
    if [[ ! -x /usr/local/bin/containerd ]] || [[ ! -x /usr/local/bin/nerdctl ]]; then
        _red "containerd or nerdctl binary missing after extraction"
        exit 1
    fi
    _green "nerdctl-full extracted to /usr/local"

    # Make commands available immediately even when /usr/local/bin is absent from current PATH.
    for bin_name in nerdctl containerd ctr runc buildctl buildkitd; do
        if [[ -x "/usr/local/bin/${bin_name}" ]] && [[ ! -e "/usr/bin/${bin_name}" ]]; then
            ln -s "/usr/local/bin/${bin_name}" "/usr/bin/${bin_name}" 2>/dev/null || true
        fi
    done

    # containerd systemd 服务文件
    if [[ ! -f /etc/systemd/system/containerd.service ]] && \
       [[ ! -f /usr/lib/systemd/system/containerd.service ]] && \
       [[ ! -f /usr/local/lib/systemd/system/containerd.service ]]; then
        cat > /etc/systemd/system/containerd.service <<'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=1048576
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
    fi

    # buildkitd 服务
    if [[ ! -f /etc/systemd/system/buildkit.service ]]; then
        cat > /etc/systemd/system/buildkit.service <<'EOF'
[Unit]
Description=BuildKit
Requires=containerd.service
After=containerd.service

[Service]
ExecStart=/usr/local/bin/buildkitd --oci-worker=false --containerd-worker=true
Type=notify
Restart=always
RestartSec=5
Delegate=yes

[Install]
WantedBy=multi-user.target
EOF
    fi

    # 确保 /usr/local/bin 在 PATH 中（持久化且避免重复写入）
    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        export PATH="/usr/local/bin:$PATH"
    fi
    if [[ ! -f /etc/profile.d/containerd-path.sh ]]; then
        echo 'export PATH="/usr/local/bin:$PATH"' > /etc/profile.d/containerd-path.sh
        chmod 644 /etc/profile.d/containerd-path.sh
    fi
    if [[ -f /etc/profile ]] && ! grep -q 'containerd-path.sh' /etc/profile; then
        echo '[ -f /etc/profile.d/containerd-path.sh ] && . /etc/profile.d/containerd-path.sh' >> /etc/profile
    fi

    _green "containerd stack installed"
}

# ======== 配置 containerd ========
configure_containerd() {
    _yellow "Configuring containerd..."
    mkdir -p /etc/containerd
    if command -v containerd >/dev/null 2>&1; then
        containerd config default > /etc/containerd/config.toml 2>/dev/null || true
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    fi

    # 若需要硬盘限制，配置 btrfs 快照器和自定义 data root
    local need_disk_limit="false"
    if [ -f /usr/local/bin/containerd_need_disk_limit ]; then
        need_disk_limit=$(cat /usr/local/bin/containerd_need_disk_limit)
    fi
    local storage_driver="overlayfs"
    if [ -f /usr/local/bin/containerd_storage_driver ]; then
        storage_driver=$(cat /usr/local/bin/containerd_storage_driver)
    fi
    local containerd_install_path="/var/lib/containerd"
    if [ -f /usr/local/bin/containerd_install_path ]; then
        containerd_install_path=$(cat /usr/local/bin/containerd_install_path)
    fi

    if [ "$need_disk_limit" = "true" ] && [ "$storage_driver" = "btrfs" ]; then
        _yellow "Configuring containerd with btrfs snapshotter for disk size limitation..."
        # 设置 containerd root（data root）
        if [ "$containerd_install_path" != "/var/lib/containerd" ]; then
            if grep -q '^root = ' /etc/containerd/config.toml 2>/dev/null; then
                sed -i "s|^root = .*|root = \"${containerd_install_path}\"|" /etc/containerd/config.toml
            else
                sed -i "1s|^|\nroot = \"${containerd_install_path}\"\n|" /etc/containerd/config.toml
            fi
        fi
        # 将默认快照器从 overlayfs 切换为 btrfs
        if grep -q 'snapshotter = "overlayfs"' /etc/containerd/config.toml 2>/dev/null; then
            sed -i 's/snapshotter = "overlayfs"/snapshotter = "btrfs"/' /etc/containerd/config.toml
        elif grep -q "snapshotter = " /etc/containerd/config.toml 2>/dev/null; then
            sed -i 's|snapshotter = .*|snapshotter = "btrfs"|' /etc/containerd/config.toml
        fi
        # 为 nerdctl 写入默认快照器配置
        mkdir -p /etc/nerdctl
        if [ -f /etc/nerdctl/nerdctl.toml ]; then
            if grep -q 'snapshotter' /etc/nerdctl/nerdctl.toml; then
                sed -i 's|snapshotter.*|snapshotter = "btrfs"|' /etc/nerdctl/nerdctl.toml
            else
                echo 'snapshotter = "btrfs"' >> /etc/nerdctl/nerdctl.toml
            fi
        else
            echo 'snapshotter = "btrfs"' > /etc/nerdctl/nerdctl.toml
        fi
        _green "containerd configured with btrfs snapshotter (disk size limitation enabled)"
    else
        # 确保 nerdctl 使用 overlayfs（默认）
        mkdir -p /etc/nerdctl
        if [ ! -f /etc/nerdctl/nerdctl.toml ]; then
            echo 'snapshotter = "overlayfs"' > /etc/nerdctl/nerdctl.toml
        fi
        _green "containerd configured with overlayfs snapshotter (standard)"
    fi
}

# ======== 配置 CNI 网络 ========
configure_cni() {
    _yellow "Configuring CNI network..."
    mkdir -p /etc/cni/net.d

    cat > /etc/cni/net.d/10-containerd-net.conflist <<'EOF'
{
  "cniVersion": "1.0.0",
  "name": "containerd-net",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "ctn-br0",
      "isGateway": true,
      "ipMasq": true,
      "promiscMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [
          [{
            "subnet": "172.20.0.0/16",
            "gateway": "172.20.0.1"
          }]
        ],
        "routes": [
          {"dst": "0.0.0.0/0"}
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    },
    {
      "type": "firewall"
    },
    {
      "type": "tuning"
    }
  ]
}
EOF
    _green "CNI network configured"
}

# ======== 检测防火墙后端 ========
detect_firewall_backend() {
    if command -v nft >/dev/null 2>&1; then
        FIREWALL_BACKEND="nftables"
    elif command -v iptables >/dev/null 2>&1; then
        FIREWALL_BACKEND="iptables"
    else
        FIREWALL_BACKEND="none"
    fi
    echo "$FIREWALL_BACKEND" > /usr/local/bin/containerd_firewall_backend
    _blue "Firewall backend: $FIREWALL_BACKEND"
}

# ======== 设置防火墙规则（IPv4 NAT/FORWARD） ========
setup_firewall_rules() {
    _yellow "Setting up firewall rules for containerd-net (172.20.0.0/16)..."
    if [[ "$FIREWALL_BACKEND" == "nftables" ]]; then
        setup_nftables_ipv4
    elif [[ "$FIREWALL_BACKEND" == "iptables" ]]; then
        setup_iptables_ipv4
    else
        _yellow "No firewall backend available, skipping"
        return
    fi
    persist_firewall_rules
}

setup_nftables_ipv4() {
    nft delete table ip containerd 2>/dev/null || true
    nft add table ip containerd
    nft add chain ip containerd postrouting '{ type nat hook postrouting priority srcnat; policy accept; }'
    nft add rule ip containerd postrouting ip saddr 172.20.0.0/16 ip daddr != 172.20.0.0/16 masquerade
    nft add chain ip containerd forward '{ type filter hook forward priority filter; policy accept; }'
    nft add rule ip containerd forward ip saddr 172.20.0.0/16 accept
    nft add rule ip containerd forward ip daddr 172.20.0.0/16 accept
    _green "nftables IPv4 NAT/FORWARD rules configured"
}

setup_iptables_ipv4() {
    if ! command -v iptables >/dev/null 2>&1; then
        _yellow "iptables not found, skipping"
        return
    fi
    iptables -t nat -C POSTROUTING -s 172.20.0.0/16 ! -d 172.20.0.0/16 -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s 172.20.0.0/16 ! -d 172.20.0.0/16 -j MASQUERADE 2>/dev/null || true
    iptables -C FORWARD -s 172.20.0.0/16 -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -s 172.20.0.0/16 -j ACCEPT 2>/dev/null || true
    iptables -C FORWARD -d 172.20.0.0/16 -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -d 172.20.0.0/16 -j ACCEPT 2>/dev/null || true
    _green "iptables IPv4 NAT/FORWARD rules configured"
}

# ======== 持久化防火墙规则 ========
persist_firewall_rules() {
    if [[ "$FIREWALL_BACKEND" == "nftables" ]]; then
        persist_nftables_rules
    elif [[ "$FIREWALL_BACKEND" == "iptables" ]]; then
        persist_iptables_rules
    fi
}

persist_nftables_rules() {
    mkdir -p /etc/nftables.d
    local nft_file="/etc/nftables.d/containerd.nft"
    {
        echo '#!/usr/sbin/nft -f'
        if nft list table ip containerd >/dev/null 2>&1; then
            nft list table ip containerd
        fi
        if nft list table ip6 containerd >/dev/null 2>&1; then
            nft list table ip6 containerd
        fi
    } > "$nft_file"
    chmod 644 "$nft_file"
    if [[ -f /etc/nftables.conf ]]; then
        if ! grep -q 'include "/etc/nftables.d/' /etc/nftables.conf 2>/dev/null; then
            echo 'include "/etc/nftables.d/*.nft"' >> /etc/nftables.conf
        fi
    else
        cat > /etc/nftables.conf <<'NFTEOF'
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/*.nft"
NFTEOF
    fi
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable nftables 2>/dev/null || true
    fi
    _green "nftables rules persisted"
}

persist_iptables_rules() {
    mkdir -p /etc/iptables 2>/dev/null || true
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
    if [[ "$SYSTEM" == "Debian" || "$SYSTEM" == "Ubuntu" ]]; then
        if ! command -v netfilter-persistent >/dev/null 2>&1; then
            ${PACKAGE_INSTALL[int]} iptables-persistent 2>/dev/null || true
        fi
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable netfilter-persistent 2>/dev/null || true
        fi
    elif [[ "$SYSTEM" == "CentOS" || "$SYSTEM" == "Fedora" ]]; then
        service iptables save 2>/dev/null || \
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
    fi
}

# ======== 配置内核参数 ========
configure_kernel() {
    _yellow "Configuring kernel parameters..."
    modprobe overlay 2>/dev/null || true
    modprobe br_netfilter 2>/dev/null || true
    update_sysctl "net.ipv4.ip_forward=1"
    update_sysctl "net.bridge.bridge-nf-call-iptables=1"
    update_sysctl "net.bridge.bridge-nf-call-ip6tables=1"
    sysctl --system >/dev/null 2>&1 || true
    _green "Kernel parameters configured"
}

# ======== 启动服务 ========
start_services() {
    _yellow "Starting containerd and buildkitd services..."
    if [[ "$SYSTEM" == "Alpine" ]]; then
        rc-update add containerd default 2>/dev/null || true
        rc-service containerd start 2>/dev/null || true
    else
        systemctl daemon-reload
        systemctl enable containerd
        systemctl restart containerd
        sleep 3
        systemctl enable buildkit 2>/dev/null || true
        systemctl start buildkit 2>/dev/null || true
    fi
    sleep 2
    if pgrep -x containerd >/dev/null 2>&1; then
        _green "containerd is running"
    else
        _yellow "Warning: containerd may not be running. Check: systemctl status containerd"
    fi
}

# ======== 配置 IPv6 内核参数及防火墙规则 ========
adapt_ipv6() {
    _yellow "Configuring IPv6 kernel parameters..."
    update_sysctl "net.ipv6.conf.all.forwarding=1"
    update_sysctl "net.ipv6.conf.default.proxy_ndp=1"
    update_sysctl "net.ipv6.conf.all.proxy_ndp=1"
    if [[ -n "$interface" ]]; then
        update_sysctl "net.ipv6.conf.${interface}.proxy_ndp=1"
    fi
    sysctl --system >/dev/null 2>&1 || true

    local ipv6_subnet=""
    if [[ -f /usr/local/bin/containerd_ipv6_subnet ]]; then
        ipv6_subnet=$(cat /usr/local/bin/containerd_ipv6_subnet)
    fi

    if [[ "$FIREWALL_BACKEND" == "nftables" ]]; then
        nft delete table ip6 containerd 2>/dev/null || true
        nft add table ip6 containerd
        nft add chain ip6 containerd forward '{ type filter hook forward priority filter; policy accept; }'
        nft add rule ip6 containerd forward iifname "ctn-br1" accept
        nft add rule ip6 containerd forward oifname "ctn-br1" accept
        if [[ -n "$ipv6_subnet" ]]; then
            nft add rule ip6 containerd forward ip6 saddr "$ipv6_subnet" accept
            nft add rule ip6 containerd forward ip6 daddr "$ipv6_subnet" accept
        fi
        _green "nftables IPv6 FORWARD rules configured"
    elif [[ "$FIREWALL_BACKEND" == "iptables" ]] && command -v ip6tables >/dev/null 2>&1; then
        if [[ -n "$ipv6_subnet" ]]; then
            ip6tables -C FORWARD -s "${ipv6_subnet}" -j ACCEPT 2>/dev/null || \
                ip6tables -A FORWARD -s "${ipv6_subnet}" -j ACCEPT 2>/dev/null || true
            ip6tables -C FORWARD -d "${ipv6_subnet}" -j ACCEPT 2>/dev/null || \
                ip6tables -A FORWARD -d "${ipv6_subnet}" -j ACCEPT 2>/dev/null || true
        fi
        ip6tables -C FORWARD -i ctn-br1 -j ACCEPT 2>/dev/null || \
            ip6tables -A FORWARD -i ctn-br1 -j ACCEPT 2>/dev/null || true
        ip6tables -C FORWARD -o ctn-br1 -j ACCEPT 2>/dev/null || \
            ip6tables -A FORWARD -o ctn-br1 -j ACCEPT 2>/dev/null || true
        _green "iptables IPv6 FORWARD rules configured"
    fi
    persist_firewall_rules 2>/dev/null || true
}

# ======== 创建 IPv6 CNI 网络 ========
create_ipv6_network() {
    local ipv6_addr="$1"
    _yellow "Creating IPv6 CNI network..."

    # 计算 /80 子网 (取 IPv6 地址前缀)
    local prefix=""
    if command -v python3 >/dev/null 2>&1; then
        prefix=$(python3 -c "
import ipaddress, sys
try:
    addr = ipaddress.ip_address('${ipv6_addr}')
    net = ipaddress.ip_network(str(addr) + '/80', strict=False)
    print(str(net))
except Exception as e:
    sys.exit(1)
" 2>/dev/null || true)
    fi
    if [[ -z "$prefix" ]]; then
        prefix=$(echo "$ipv6_addr" | awk -F: '{print $1":"$2":"$3":"$4"::/80"}')
    fi

    echo "$prefix" > /usr/local/bin/containerd_ipv6_subnet

    cat > /etc/cni/net.d/11-containerd-ipv6.conflist <<EOF
{
  "cniVersion": "1.0.0",
  "name": "containerd-ipv6",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "ctn-br1",
      "isGateway": true,
      "ipMasq": false,
      "promiscMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [
          [{
            "subnet": "172.21.0.0/16",
            "gateway": "172.21.0.1"
          }],
          [{
            "subnet": "${prefix}"
          }]
        ],
        "routes": [
          {"dst": "0.0.0.0/0"},
          {"dst": "::/0"}
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    },
    {
      "type": "firewall"
    },
    {
      "type": "tuning"
    }
  ]
}
EOF
    _green "IPv6 CNI network (containerd-ipv6) created: $prefix"
}

# ======== 启动 NDP Responder ========
start_ndpresponder() {
    _yellow "Starting NDP responder for IPv6..."
    local arch_tag
    case "$ARCH_TYPE" in
        amd64) arch_tag="x86" ;;
        arm64) arch_tag="arm64" ;;
        *)     arch_tag="x86" ;;
    esac

    nerdctl rm -f ndpresponder 2>/dev/null || true

    nerdctl run -d \
        --restart always \
        --cpus 0.02 \
        --memory 64m \
        --cap-drop=ALL \
        --cap-add=NET_RAW \
        --cap-add=NET_ADMIN \
        --network host \
        --name ndpresponder \
        "spiritlhl/ndpresponder_${arch_tag}" \
        -i "${interface}" -N containerd-ipv6 2>/dev/null \
    && _green "NDP responder started" \
    || _yellow "ndpresponder start failed; IPv6 may require manual NDP configuration"
}

# ======== DNS 保活服务 ========
setup_dns_check() {
    _yellow "Setting up DNS liveness check service..."
    cat > /usr/local/bin/check-dns.sh <<'EOF'
#!/bin/bash
# DNS liveness check for containerd
while true; do
    if ! nslookup github.com >/dev/null 2>&1; then
        if [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
            ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
        fi
        grep -q "8.8.8.8" /etc/resolv.conf || echo "nameserver 8.8.8.8" >> /etc/resolv.conf
        grep -q "1.1.1.1" /etc/resolv.conf || echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    fi
    sleep 60
done
EOF
    chmod +x /usr/local/bin/check-dns.sh

    if [[ "$SYSTEM" != "Alpine" ]]; then
        cat > /etc/systemd/system/check-dns.service <<'EOF'
[Unit]
Description=DNS Liveness Check for Containerd
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/check-dns.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable check-dns 2>/dev/null || true
        systemctl start check-dns 2>/dev/null || true
    fi
    _green "DNS check service configured"
}

# ======== 验证安装 ========
verify_install() {
    _yellow "Verifying installation..."
    local all_ok=true
    for cmd in containerd runc nerdctl; do
        if command -v "$cmd" >/dev/null 2>&1; then
            _green "  ✓ $cmd: $(${cmd} --version 2>/dev/null | head -1)"
        else
            _yellow "  ✗ $cmd not found"
            all_ok=false
        fi
    done
    if command -v buildkitd >/dev/null 2>&1; then
        _green "  ✓ buildkitd available"
    fi
    if $all_ok; then
        _green "All components installed successfully"
    else
        _yellow "Some components missing, please check manually"
    fi
}

# ======== 主流程 ========
main() {
    _blue "======================================================"
    _blue "  Containerd 容器运行时一键安装脚本"
    _blue "  from https://github.com/oneclickvirt/containerd"
    _blue "  2026.03.01"
    _blue "======================================================"
    echo

    # 重新计算 int（系统类型索引）
    for ((int = 0; int < ${#REGEX[@]}; int++)); do
        if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
            break
        fi
    done

    # ======== 询问是否需要硬盘限制支持（支持环境变量 NEED_DISK_LIMIT） ========
    if [[ -n "${NEED_DISK_LIMIT:-}" ]]; then
        need_disk_limit_input="${NEED_DISK_LIMIT}"
        _blue "[non-interactive] NEED_DISK_LIMIT=${NEED_DISK_LIMIT}"
    else
        _green "Do you need containerd with container disk size limitation? (Support btrfs snapshotter)"
        _green "是否需要支持容器硬盘大小限制的 containerd 环境？（使用 btrfs 快照器）"
        _blue "If you choose 'y', you can limit the disk space for each container (requires btrfs)"
        _blue "If you choose 'n', standard installation without disk limits"
        _blue "如果选择 'y'，可以为每个容器限制磁盘空间（需要 btrfs 支持）"
        _blue "如果选择 'n'，则为标准安装，无磁盘限制"
        reading "Do you need container disk size limitation? ([n]/y): " need_disk_limit_input
    fi

    # ======== 安装路径（支持环境变量 CONTAINERD_INSTALL_PATH） ========
    if [[ -n "${CONTAINERD_INSTALL_PATH:-}" ]]; then
        containerd_install_path="${CONTAINERD_INSTALL_PATH}"
        _blue "[non-interactive] CONTAINERD_INSTALL_PATH=${CONTAINERD_INSTALL_PATH}"
    else
        _green "Where do you want to install containerd? (Enter to default: /var/lib/containerd):"
        reading "containerd 安装路径？（回车则默认：/var/lib/containerd）：" containerd_install_path
        if [ -z "$containerd_install_path" ]; then
            containerd_install_path="/var/lib/containerd"
        fi
    fi
    echo "$containerd_install_path" > /usr/local/bin/containerd_install_path

    containerd_pool_size=""
    containerd_loop_file=""
    if [ "$need_disk_limit_input" = "y" ] || [ "$need_disk_limit_input" = "Y" ]; then
        echo "true" > /usr/local/bin/containerd_need_disk_limit
        # 存储池大小（支持环境变量 CONTAINERD_POOL_SIZE）
        if [[ -n "${CONTAINERD_POOL_SIZE:-}" ]]; then
            if [[ "${CONTAINERD_POOL_SIZE}" =~ ^[1-9][0-9]*$ ]]; then
                containerd_pool_size="${CONTAINERD_POOL_SIZE}"
                _blue "[non-interactive] CONTAINERD_POOL_SIZE=${CONTAINERD_POOL_SIZE}"
            else
                _red "Invalid CONTAINERD_POOL_SIZE='${CONTAINERD_POOL_SIZE}', must be a positive integer."
                exit 1
            fi
        else
            while true; do
                _green "How large a containerd storage pool is needed? (unit: GB, e.g., enter 20 for 20G):"
                reading "需要多大的 containerd 存储池？（单位GB，例如输入20表示20G）：" containerd_pool_size
                if [[ "$containerd_pool_size" =~ ^[1-9][0-9]*$ ]]; then
                    break
                else
                    _yellow "Invalid input, please enter a positive integer."
                    _yellow "输入无效，请输入一个正整数。"
                fi
            done
        fi
        # 循环文件路径（支持环境变量 CONTAINERD_LOOP_FILE）
        if [[ -n "${CONTAINERD_LOOP_FILE:-}" ]]; then
            containerd_loop_file="${CONTAINERD_LOOP_FILE}"
            _blue "[non-interactive] CONTAINERD_LOOP_FILE=${CONTAINERD_LOOP_FILE}"
        else
            _green "Where do you want to store the containerd loop file? (Enter to default: /opt/containerd-pool.img):"
            reading "containerd 循环文件存储位置？（回车则默认：/opt/containerd-pool.img）：" containerd_loop_file
            if [ -z "$containerd_loop_file" ]; then
                containerd_loop_file="/opt/containerd-pool.img"
            fi
        fi
    else
        echo "false" > /usr/local/bin/containerd_need_disk_limit
        containerd_pool_size=""
        containerd_loop_file=""
        _green "Will install standard containerd without container disk size limitation"
        _green "将安装标准 containerd，无容器磁盘大小限制功能"
    fi

    detect_interface
    check_ipv6
    install_base_deps

    # 确定存储驱动（含重启后检测，btrfs 安装后需要重启）
    try_storage_drivers

    # 获取最终存储驱动
    local final_driver="overlayfs"
    if [ -f /usr/local/bin/containerd_storage_driver ]; then
        final_driver=$(cat /usr/local/bin/containerd_storage_driver)
    fi

    # 若需要硬盘限制且 btrfs 可用，创建 btrfs loop 文件系统
    local need_disk_limit="false"
    if [ -f /usr/local/bin/containerd_need_disk_limit ]; then
        need_disk_limit=$(cat /usr/local/bin/containerd_need_disk_limit)
    fi
    if [ "$need_disk_limit" = "true" ] && [ "$final_driver" = "btrfs" ] && \
       [ -n "$containerd_pool_size" ] && [ -n "$containerd_loop_file" ]; then
        setup_containerd_btrfs_loop "$containerd_pool_size" "$containerd_loop_file" "$containerd_install_path"
    fi

    install_containerd_stack
    configure_containerd
    configure_cni
    detect_firewall_backend
    setup_firewall_rules
    configure_kernel
    start_services
    setup_dns_check

    if [[ "$IPV6_ENABLED" == true ]]; then
        create_ipv6_network "$IPV6"
        adapt_ipv6
        start_ndpresponder
        echo "true" > /usr/local/bin/containerd_ipv6_enabled
    else
        echo "false" > /usr/local/bin/containerd_ipv6_enabled
    fi

    # 保存架构信息
    echo "$ARCH_TYPE" > /usr/local/bin/containerd_arch

    verify_install

    echo
    _green "======================================================"
    _green "  ✓ Containerd 安装完成！"
    if [ "$need_disk_limit" = "true" ] && [ "$final_driver" = "btrfs" ]; then
        _green "  ✓ 硬盘大小限制：已启用（btrfs 快照器）"
    else
        _yellow "  ✗ 硬盘大小限制：未启用（overlayfs 快照器）"
    fi
    _green "======================================================"
    echo
    _blue "常用命令:"
    _yellow "  查看容器:  nerdctl ps -a"
    _yellow "  拉取镜像:  nerdctl pull ubuntu:22.04"
    _yellow "  开设容器:  bash scripts/onecontainerd.sh <name> <cpu> <mem_mb> <passwd> <sshport> <startport> <endport>"
    _yellow "  批量开设:  bash scripts/create_containerd.sh"
    _yellow "  项目地址:  https://github.com/oneclickvirt/containerd"
    echo
}

main "$@"

