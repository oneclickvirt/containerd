#!/bin/bash
# from
# https://github.com/oneclickvirt/containerd
# 2026.08.27
#
# Supported environment variables (non-interactive mode / 支持的环境变量，可实现无交互安装):
#   noninteractive=true          - Use defaults for prompts / 使用默认值跳过交互提示
#   WITHOUTCDN=TRUE             - Disable CDN acceleration / 禁用 CDN 加速
#   NEED_DISK_LIMIT=y           - Enable container disk size limitation (btrfs) / 启用容器磁盘大小限制 (btrfs)；默认: n
#   CONTAINERD_INSTALL_PATH=    - containerd data root path / containerd 数据根路径；默认: /var/lib/containerd
#   CONTAINERD_POOL_SIZE=20     - Storage pool size in GB / 存储池大小（GB），NEED_DISK_LIMIT=y 时默认: 20
#   CONTAINERD_LOOP_FILE=       - Loop file path / 循环文件路径；默认: /opt/containerd-pool.img
#   CONTAINERD_MAIN_INTERFACE=  - Host outbound interface / 宿主机出口网卡；默认自动检测
#   CONTAINERD_IPV6_SUBNET_PREFIX=80 - IPv6 CNI subnet prefix / IPv6 CNI 子网前缀；默认: 80
#   CONTAINERD_IPV6_SUBNET_INDEX=1   - preferred IPv6 subnet index / 优先选择的 IPv6 子网序号；默认: 1
#
# Example / 示例:
#   export noninteractive=true
#   bash containerdinstall.sh
#   NEED_DISK_LIMIT=y CONTAINERD_POOL_SIZE=20 bash containerdinstall.sh
#   CONTAINERD_INSTALL_PATH=/data/containerd bash containerdinstall.sh

set -uo pipefail

_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$*\033[0m"; }
is_truthy() {
    case "${1:-}" in
        [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Yy]) return 0 ;;
        *) return 1 ;;
    esac
}
is_noninteractive() {
    is_truthy "${noninteractive:-${NONINTERACTIVE:-}}"
}
is_yes() {
    is_truthy "$1"
}
reading() {
    is_noninteractive && return 1
    read -rp "$(_green "$1")" "$2"
}
DEFAULT_CONTAINERD_INSTALL_PATH="/var/lib/containerd"
DEFAULT_CONTAINERD_POOL_SIZE="20"
DEFAULT_CONTAINERD_LOOP_FILE="/opt/containerd-pool.img"
DEFAULT_CONTAINERD_IPV6_SUBNET_PREFIX="80"
DEFAULT_CONTAINERD_IPV6_SUBNET_INDEX="1"
export DEBIAN_FRONTEND=noninteractive
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8" || true)
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
    "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2 || true)"
    "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2 || true)"
    "$(lsb_release -sd 2>/dev/null || true)"
    "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2 || true)"
    "$(grep . /etc/redhat-release 2>/dev/null || true)"
    "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d' || true)"
    "$(grep . /etc/alpine-release 2>/dev/null || true)"
)
SYSTEM=""
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
    local shuffled_cdn_urls=("${cdn_urls[@]}")
    if command -v shuf >/dev/null 2>&1; then
        mapfile -t shuffled_cdn_urls < <(printf '%s\n' "${cdn_urls[@]}" | shuf)
    fi
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
    ! is_public_ipv6 "${1:-}"
}

is_public_ipv6() {
    local addr="${1:-}"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$addr" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.IPv6Address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

global_unicast = ipaddress.IPv6Network("2000::/3")
non_public = (
    ipaddress.IPv6Network("2001::/32"),       # Teredo
    ipaddress.IPv6Network("2001:2::/48"),     # benchmarking
    ipaddress.IPv6Network("2001:10::/28"),    # ORCHID
    ipaddress.IPv6Network("2001:20::/28"),    # ORCHIDv2
    ipaddress.IPv6Network("2001:db8::/32"),   # documentation
    ipaddress.IPv6Network("2002::/16"),       # 6to4
    ipaddress.IPv6Network("3fff::/20"),       # documentation
)
usable = (
    address in global_unicast
    and address.is_global
    and not address.is_private
    and not address.is_multicast
    and not any(address in prefix for prefix in non_public)
)
raise SystemExit(0 if usable else 1)
PY
}

# ======== 检测公网 IPv6 ========
detect_global_ipv6_cidr() {
    local dev="${1:-}"
    local candidates="" all_candidates=""
    if command -v ip >/dev/null 2>&1; then
        if [[ -n "$dev" ]]; then
            candidates=$(ip -o -6 addr show dev "$dev" scope global 2>/dev/null | awk '$0 !~ / tentative/ {print $4}' || true)
        fi
        all_candidates=$(ip -o -6 addr show scope global 2>/dev/null | awk '$0 !~ / tentative/ {print $4}' || true)
    fi

    # Keep the selected device first for equal-length prefixes, but consider
    # every locally bound address. A /128 on the default uplink must not hide
    # a delegated /38 on a PVE bridge or a 6in4 tunnel.
    candidates=$(printf '%s\n%s\n' "$candidates" "$all_candidates" | awk 'NF && !seen[$0]++')
    local cidr addr prefix prefix_number best_cidr="" best_prefix=129
    while IFS= read -r cidr; do
        [[ -n "$cidr" ]] || continue
        addr="${cidr%%/*}"
        prefix="${cidr##*/}"
        [[ "$prefix" =~ ^[0-9]+$ ]] || continue
        prefix_number=$((10#$prefix))
        (( prefix_number <= 128 )) || continue
        if is_public_ipv6 "$addr" && (( prefix_number < best_prefix )); then
            best_cidr="$cidr"
            best_prefix=$prefix_number
        fi
    done <<< "$candidates"
    [[ -n "$best_cidr" ]] || return 1
    printf '%s\n' "$best_cidr"
}

# Use the IPv6 default route rather than the IPv4 primary NIC for NDP. When a
# host has no default route entry yet, match the complete selected CIDR so a
# delegated PVE bridge or tunnel remains distinguishable from a /128 uplink.
containerd_ipv6_uplink_interface() {
    local uplink selected
    uplink=$(ip -6 route show default 2>/dev/null | awk '
        /^default / {
            for (i = 1; i < NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }
    ')
    if [[ -n "$uplink" ]] && ip link show dev "$uplink" >/dev/null 2>&1; then
        printf '%s\n' "$uplink"
        return 0
    fi

    selected="${IPV6_CIDR:-}"
    if [[ "$selected" != */* ]]; then
        selected=$(detect_global_ipv6_cidr "${interface:-}" 2>/dev/null || true)
    fi
    [[ "$selected" == */* ]] || return 1
    uplink=$(ip -6 -o addr show scope global 2>/dev/null | awk -v cidr="$selected" '$4 == cidr {print $2; exit}')
    [[ -n "$uplink" ]] || return 1
    printf '%s\n' "$uplink"
}

containerd_ipv6_uplink_supports_ndp() {
    local uplink="$1" link_info
    [[ -n "$uplink" ]] || return 1
    link_info=$(ip -d link show dev "$uplink" 2>/dev/null || ip link show dev "$uplink" 2>/dev/null || true)
    grep -q 'link/ether' <<<"$link_info"
}

configure_containerd_ipv6_ndp_state() {
    local network_mode uplink ndp_required=false state_dir
    state_dir="${CONTAINERD_IPV6_STATE_DIR:-/usr/local/bin}"
    network_mode=""
    if [[ -f "${state_dir}/containerd_ipv6_network_mode" ]]; then
        network_mode=$(tr -d '[:space:]' <"${state_dir}/containerd_ipv6_network_mode" 2>/dev/null || true)
    fi
    uplink=$(containerd_ipv6_uplink_interface 2>/dev/null || true)
    if [[ -z "$uplink" ]]; then
        _yellow "Could not determine the IPv6 uplink; independent IPv6 will remain disabled"
        return 1
    fi
    if [[ "$network_mode" != "nat" ]] && containerd_ipv6_uplink_supports_ndp "$uplink"; then
        ndp_required=true
    fi
    printf '%s\n' "$uplink" > "${state_dir}/containerd_ipv6_uplink"
    printf '%s\n' "$ndp_required" > "${state_dir}/containerd_ipv6_ndp_required"
    return 0
}

check_ipv6() {
    IPV6_CIDR=$(detect_global_ipv6_cidr "${interface:-}" || true)
    IPV6="${IPV6_CIDR%%/*}"
    if [[ -n "$IPV6_CIDR" ]] && is_public_ipv6 "$IPV6"; then
        _green "Locally bound public IPv6 detected: $IPV6 ($IPV6_CIDR)"
        printf '%s\n' "$IPV6" > /usr/local/bin/containerd_check_ipv6
        printf '%s\n' "$IPV6_CIDR" > /usr/local/bin/containerd_check_ipv6_cidr
        IPV6_ENABLED=true
    else
        IPV6_CIDR=""
        IPV6=""
        printf '%s\n' "" > /usr/local/bin/containerd_check_ipv6
        printf '%s\n' "" > /usr/local/bin/containerd_check_ipv6_cidr
        _yellow "No locally bound public IPv6 prefix found; independent IPv6 setup is disabled"
        IPV6_ENABLED=false
    fi
}

# ======== 检测主网络接口 ========
detect_interface() {
    if [[ -n "${CONTAINERD_MAIN_INTERFACE:-}" ]]; then
        if command -v ip >/dev/null 2>&1 && ip link show "$CONTAINERD_MAIN_INTERFACE" >/dev/null 2>&1; then
            interface="$CONTAINERD_MAIN_INTERFACE"
            _blue "[non-interactive] CONTAINERD_MAIN_INTERFACE=${CONTAINERD_MAIN_INTERFACE}"
        else
            _red "CONTAINERD_MAIN_INTERFACE='${CONTAINERD_MAIN_INTERFACE}' was not found on this host."
            exit 1
        fi
    else
        interface=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' || true)
        if [[ -z "$interface" ]]; then
            interface=$(ip link show 2>/dev/null | awk '/^[0-9]+: /{gsub(":", "", $2); if($2!="lo") {print $2; exit}}' || true)
        fi
    fi
    if [[ -z "$interface" ]]; then
        _red "Failed to detect host outbound network interface."
        exit 1
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
        loop_device=$(losetup -j "$loop_file" | cut -d: -f1 || true)
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
                socat unzip tar jq python3 git 2>/dev/null || true
            ;;
        CentOS|Fedora)
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates nftables iptables iproute \
                socat unzip tar jq python3 git 2>/dev/null || true
            ;;
        Alpine)
            ${PACKAGE_UPDATE[int]} 2>/dev/null || true
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates nftables iptables iproute2 \
                socat unzip tar jq python3 git 2>/dev/null || true
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
        | grep tag_name | cut -d'"' -f4 | sed 's/v//' || true)
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
        # shellcheck disable=SC2016
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
        if [[ -f /etc/containerd/config.toml ]]; then
            sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
        fi
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
      "ipMasq": false,
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
    nft add table ip containerd 2>/dev/null || true
    nft add chain ip containerd postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true
    nft add rule ip containerd postrouting ip saddr 172.20.0.0/16 ip daddr != 172.20.0.0/16 masquerade 2>/dev/null || true
    nft add chain ip containerd forward '{ type filter hook forward priority filter; policy accept; }' 2>/dev/null || true
    nft add rule ip containerd forward ip saddr 172.20.0.0/16 accept 2>/dev/null || true
    nft add rule ip containerd forward ip daddr 172.20.0.0/16 accept 2>/dev/null || true
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
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable containerd 2>/dev/null || true
        systemctl restart containerd 2>/dev/null || true
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
    local uplink
    _yellow "Configuring IPv6 kernel parameters..."
    uplink=$(containerd_ipv6_uplink_interface 2>/dev/null || true)
    if [[ -z "$uplink" ]]; then
        _yellow "Could not determine the IPv6 uplink; leaving host IPv6 settings unchanged"
        return 1
    fi
    update_sysctl "net.ipv6.conf.all.forwarding=1"
    # Forwarding otherwise disables ordinary RA processing on Linux. Keep the
    # actual IPv6 uplink's SLAAC route alive without changing global proxy_ndp.
    update_sysctl "net.ipv6.conf.${uplink}.accept_ra=2"
    sysctl --system >/dev/null 2>&1 || true

    local ipv6_subnet="" ipv4_subnet="172.21.0.0/16" ipv6_mode=""
    if [[ -f /usr/local/bin/containerd_ipv6_subnet ]]; then
        ipv6_subnet=$(cat /usr/local/bin/containerd_ipv6_subnet)
    fi
    ipv6_mode=$(cat /usr/local/bin/containerd_ipv6_network_mode 2>/dev/null || true)

    if [[ "$FIREWALL_BACKEND" == "nftables" ]]; then
        # ipMasq is disabled in the CNI config so both the IPv4 side of this
        # dual-stack bridge and ULA NAT66 are owned by one persistent rule set.
        setup_nftables_ipv4
        nft list chain ip containerd postrouting >/dev/null 2>&1 || return 1
        nft list chain ip containerd forward >/dev/null 2>&1 || return 1
        nft add rule ip containerd postrouting ip saddr "$ipv4_subnet" ip daddr != "$ipv4_subnet" masquerade 2>/dev/null || return 1
        nft add rule ip containerd forward ip saddr "$ipv4_subnet" accept 2>/dev/null || return 1
        nft add rule ip containerd forward ip daddr "$ipv4_subnet" accept 2>/dev/null || return 1
        nft delete table ip6 containerd 2>/dev/null || true
        nft add table ip6 containerd 2>/dev/null || return 1
        nft add chain ip6 containerd forward '{ type filter hook forward priority filter; policy accept; }' 2>/dev/null || return 1
        nft add rule ip6 containerd forward iifname "ctn-br1" accept 2>/dev/null || return 1
        nft add rule ip6 containerd forward oifname "ctn-br1" accept 2>/dev/null || return 1
        if [[ -n "$ipv6_subnet" ]]; then
            nft add rule ip6 containerd forward ip6 saddr "$ipv6_subnet" accept 2>/dev/null || return 1
            nft add rule ip6 containerd forward ip6 daddr "$ipv6_subnet" accept 2>/dev/null || return 1
        fi
        if [[ "$ipv6_mode" == "nat" && -n "$ipv6_subnet" ]]; then
            nft add chain ip6 containerd postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || return 1
            nft add rule ip6 containerd postrouting ip6 saddr "$ipv6_subnet" ip6 daddr != "$ipv6_subnet" masquerade 2>/dev/null || return 1
            nft list chain ip6 containerd postrouting 2>/dev/null | grep -Fq "ip6 saddr ${ipv6_subnet}" || return 1
        fi
        _green "nftables IPv4/IPv6 forwarding rules configured"
    elif [[ "$FIREWALL_BACKEND" == "iptables" ]] && command -v ip6tables >/dev/null 2>&1; then
        command -v iptables >/dev/null 2>&1 || return 1
        iptables -t nat -C POSTROUTING -s "$ipv4_subnet" ! -d "$ipv4_subnet" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s "$ipv4_subnet" ! -d "$ipv4_subnet" -j MASQUERADE 2>/dev/null || return 1
        iptables -C FORWARD -s "$ipv4_subnet" -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -s "$ipv4_subnet" -j ACCEPT 2>/dev/null || return 1
        iptables -C FORWARD -d "$ipv4_subnet" -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -d "$ipv4_subnet" -j ACCEPT 2>/dev/null || return 1
        if [[ -n "$ipv6_subnet" ]]; then
            ip6tables -C FORWARD -s "${ipv6_subnet}" -j ACCEPT 2>/dev/null || \
                ip6tables -A FORWARD -s "${ipv6_subnet}" -j ACCEPT 2>/dev/null || return 1
            ip6tables -C FORWARD -d "${ipv6_subnet}" -j ACCEPT 2>/dev/null || \
                ip6tables -A FORWARD -d "${ipv6_subnet}" -j ACCEPT 2>/dev/null || return 1
        fi
        ip6tables -C FORWARD -i ctn-br1 -j ACCEPT 2>/dev/null || \
            ip6tables -A FORWARD -i ctn-br1 -j ACCEPT 2>/dev/null || return 1
        ip6tables -C FORWARD -o ctn-br1 -j ACCEPT 2>/dev/null || \
            ip6tables -A FORWARD -o ctn-br1 -j ACCEPT 2>/dev/null || return 1
        if [[ "$ipv6_mode" == "nat" && -n "$ipv6_subnet" ]]; then
            ip6tables -t nat -C POSTROUTING -s "${ipv6_subnet}" ! -d "${ipv6_subnet}" -j MASQUERADE 2>/dev/null || \
                ip6tables -t nat -A POSTROUTING -s "${ipv6_subnet}" ! -d "${ipv6_subnet}" -j MASQUERADE 2>/dev/null || return 1
            ip6tables -t nat -C POSTROUTING -s "${ipv6_subnet}" ! -d "${ipv6_subnet}" -j MASQUERADE 2>/dev/null || return 1
        fi
        _green "iptables IPv4/IPv6 forwarding rules configured"
    else
        _red "No usable firewall backend is available for Containerd IPv6"
        return 1
    fi
    persist_firewall_rules 2>/dev/null || true
}

# ======== 创建 IPv6 CNI 网络 ========
cni_ipv6_subnet_overlaps_existing() {
    local subnet="$1"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$subnet" /etc/cni/net.d 2>/dev/null <<'PY'
import ipaddress
import os
import re
import sys

candidate = ipaddress.ip_network(sys.argv[1], strict=False)
config_dir = sys.argv[2]
for root, _, files in os.walk(config_dir):
    for name in files:
        if name == "11-containerd-ipv6.conflist":
            continue
        path = os.path.join(root, name)
        try:
            content = open(path, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        for raw in re.findall(r'"subnet"\s*:\s*"([^"]+)"', content):
            try:
                existing = ipaddress.ip_network(raw, strict=False)
            except ValueError:
                continue
            if existing.version == 6 and candidate.overlaps(existing):
                raise SystemExit(0)
raise SystemExit(1)
PY
}

# This strict overlap check is used when selecting an isolated ULA NAT66
# subnet. Public CNI children use cni_ipv6_subnet_conflicts_with_host_route:
# a child of the selected parent route is intentional and becomes a more
# specific bridge route, while an equal or more-specific existing route is not.
cni_ipv6_subnet_overlaps_host() {
    local subnet="$1"
    command -v python3 >/dev/null 2>&1 || return 2
    {
        ip -6 -o addr show 2>/dev/null | awk '$0 !~ / tentative/ {print $4}'
        ip -6 route show table all 2>/dev/null | awk '$1 ~ /^[0-9A-Fa-f:]+\/[0-9]+$/ {print $1}'
    } | python3 -c '
import ipaddress
import sys

try:
    candidate = ipaddress.IPv6Network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(2)
for raw in sys.stdin:
    try:
        existing = ipaddress.IPv6Network(raw.strip(), strict=False)
    except ValueError:
        continue
    if candidate.overlaps(existing):
        raise SystemExit(0)
raise SystemExit(1)
' "$subnet"
}

containerd_ipv6_ula_candidate() {
    local index="$1"
    python3 - "$index" <<'PY'
import ipaddress
import sys

base = ipaddress.IPv6Network("fd42:5339:296f:1e00::/56")
index = int(sys.argv[1])
print(ipaddress.IPv6Network((int(base.network_address) + (index << 64), 64)))
PY
}

# A connected or routed parent prefix is not itself a conflict for a CNI
# child. The bridge plugin installs the child as a more-specific route, which
# is how PVE delegated prefixes and normal NDP-backed /64s remain usable.
# Do not overwrite a route already equal to, or more specific than, that child.
cni_ipv6_subnet_conflicts_with_host_route() {
    local subnet="$1"
    command -v python3 >/dev/null 2>&1 || return 2
    ip -6 route show table all 2>/dev/null | awk '$1 ~ /^[0-9A-Fa-f:]+\/[0-9]+$/ {print $1}' | python3 -c '
import ipaddress
import sys

try:
    candidate = ipaddress.IPv6Network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(2)

for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        route = ipaddress.IPv6Network(raw, strict=False)
    except ValueError:
        continue
    if route.version == 6 and (route == candidate or route.subnet_of(candidate)):
        raise SystemExit(0)
raise SystemExit(1)
' "$subnet"
}

containerd_ipv6_ula_gateway() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

network = ipaddress.IPv6Network(sys.argv[1], strict=False)
print(ipaddress.IPv6Address(int(network.network_address) + 1))
PY
}

containerd_ipv6_ula_is_safe() {
    local subnet="$1"
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$subnet" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.IPv6Network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if network.prefixlen == 64 and network.subnet_of(ipaddress.IPv6Network("fc00::/7")) else 1)
PY
}

# Return the sole IPv6 subnet from the installer-owned CNI conflist. A
# malformed or multi-subnet file is deliberately not safe to overwrite.
containerd_cni_ipv6_subnet() {
    local config="${1:-/etc/cni/net.d/11-containerd-ipv6.conflist}"
    [[ -f "$config" ]] || return 1
    command -v python3 >/dev/null 2>&1 || return 2
    python3 - "$config" <<'PY'
import ipaddress
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        config = json.load(handle)
except (OSError, json.JSONDecodeError):
    raise SystemExit(2)

subnets = []
invalid_subnet = False

def walk(value):
    global invalid_subnet
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "subnet" and isinstance(child, str):
                try:
                    network = ipaddress.ip_network(child, strict=False)
                except ValueError:
                    invalid_subnet = True
                    continue
                if network.version == 6:
                    subnets.append(str(network))
            else:
                walk(child)
    elif isinstance(value, list):
        for child in value:
            walk(child)

walk(config)
if invalid_subnet:
    raise SystemExit(2)
subnets = sorted(set(subnets))
if not subnets:
    raise SystemExit(1)
if len(subnets) != 1:
    raise SystemExit(2)
print(subnets[0])
PY
}

# A connected bridge route for a previously created ULA is expected. Reuse it
# only when both on-disk state values prove that the bridge belongs to us.
containerd_ipv6_ula_state_matches_cni() {
    local recorded_mode="$1" recorded_subnet="$2" cni_subnet="$3"
    [[ "$recorded_mode" == "nat" && "$recorded_subnet" == "$cni_subnet" ]] || return 1
    containerd_ipv6_ula_is_safe "$cni_subnet"
}

# A managed public CNI network may be reused only when both state files agree
# with its single IPv6 subnet. Do not mistake a ULA NAT66 network for a public
# allocation merely because a stale mode file says "managed".
containerd_ipv6_managed_state_matches_cni() {
    local recorded_mode="$1" recorded_subnet="$2" cni_subnet="$3"
    [[ "$recorded_mode" == "managed" && "$recorded_subnet" == "$cni_subnet" ]] || return 1
    is_public_ipv6 "${cni_subnet%%/*}"
}

containerd_ipv6_state_matches_cni() {
    local recorded_mode="$1" recorded_subnet="$2" cni_subnet="$3"
    case "$recorded_mode" in
        nat) containerd_ipv6_ula_state_matches_cni "$recorded_mode" "$recorded_subnet" "$cni_subnet" ;;
        managed) containerd_ipv6_managed_state_matches_cni "$recorded_mode" "$recorded_subnet" "$cni_subnet" ;;
        *) return 1 ;;
    esac
}

create_containerd_ula_ipv6_network() {
    local public_parent="$1" subnet gateway index existing_subnet recorded_mode recorded_subnet
    local cni_config="${CONTAINERD_CNI_IPV6_CONFIG:-/etc/cni/net.d/11-containerd-ipv6.conflist}"
    local state_dir="${CONTAINERD_IPV6_STATE_DIR:-/usr/local/bin}"
    if [[ -e "$cni_config" || -L "$cni_config" ]]; then
        existing_subnet=$(containerd_cni_ipv6_subnet "$cni_config" 2>/dev/null || true)
        recorded_mode=$(tr -d '[:space:]' <"${state_dir}/containerd_ipv6_network_mode" 2>/dev/null || true)
        recorded_subnet=$(tr -d '[:space:]' <"${state_dir}/containerd_ipv6_subnet" 2>/dev/null || true)
        if ! containerd_ipv6_ula_state_matches_cni "$recorded_mode" "$recorded_subnet" "$existing_subnet"; then
            _yellow "Existing Containerd IPv6 CNI network is not the installer-managed ULA NAT66 network; preserving its current configuration"
            _yellow "现有 Containerd IPv6 CNI 网络不是安装器托管的 ULA NAT66 网络，保留其当前配置"
            return 1
        fi
        gateway=$(containerd_ipv6_ula_gateway "$existing_subnet" 2>/dev/null || true)
        [[ -n "$gateway" ]] || return 1
        printf '%s\n' "$public_parent" > "${state_dir}/containerd_ipv6_parent"
        printf '%s\n' "$gateway" > "${state_dir}/containerd_ipv6_gateway"
        _green "Reusing installer-managed Containerd ULA IPv6 network: ${existing_subnet}"
        _green "复用安装器托管的 Containerd ULA IPv6 网络：${existing_subnet}"
        return 0
    fi
    for index in $(seq 0 255); do
        subnet=$(containerd_ipv6_ula_candidate "$index" 2>/dev/null || true)
        gateway=$(containerd_ipv6_ula_gateway "$subnet" 2>/dev/null || true)
        [[ -n "$subnet" && -n "$gateway" ]] || continue
        cni_ipv6_subnet_overlaps_host "$subnet" && continue
        cni_ipv6_subnet_overlaps_existing "$subnet" && continue
        cat > "$cni_config" <<EOF
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
          [{"subnet": "172.21.0.0/16", "gateway": "172.21.0.1"}],
          [{"subnet": "${subnet}", "gateway": "${gateway}"}]
        ],
        "routes": [{"dst": "0.0.0.0/0"}, {"dst": "::/0"}]
      }
    },
    {"type": "portmap", "capabilities": {"portMappings": true}},
    {"type": "firewall"},
    {"type": "tuning"}
  ]
}
EOF
        printf '%s\n' "$public_parent" > "${state_dir}/containerd_ipv6_parent"
        printf '%s\n' "$subnet" > "${state_dir}/containerd_ipv6_subnet"
        printf '%s\n' "$gateway" > "${state_dir}/containerd_ipv6_gateway"
        printf '%s\n' nat > "${state_dir}/containerd_ipv6_network_mode"
        _yellow "Host IPv6 route overlaps the requested public CNI child; using isolated ULA ${subnet} with NAT66"
        _yellow "宿主机 IPv6 路由覆盖了请求的公网 CNI 子网，改用隔离 ULA ${subnet} 并启用 NAT66"
        return 0
    done
    return 1
}

derive_containerd_ipv6_subnet() {
    local parent="$1" subnet_prefix="$2" subnet_index="$3" index_explicit="$4"
    command -v python3 >/dev/null 2>&1 || return 1
    CONTAINERD_IPV6_PARENT="$parent" \
        CONTAINERD_IPV6_PREFIX="$subnet_prefix" \
        CONTAINERD_IPV6_INDEX="$subnet_index" \
        CONTAINERD_IPV6_INDEX_EXPLICIT="$index_explicit" \
        python3 - 2>/dev/null <<'PY'
import ipaddress
import os
import subprocess
import sys

try:
    parent = ipaddress.ip_network(os.environ["CONTAINERD_IPV6_PARENT"], strict=False)
    requested_prefix = int(os.environ["CONTAINERD_IPV6_PREFIX"])
    requested_index = int(os.environ["CONTAINERD_IPV6_INDEX"])
    explicit_index = os.environ.get("CONTAINERD_IPV6_INDEX_EXPLICIT") == "true"
    if parent.version != 6:
        raise ValueError("not an IPv6 prefix")
    target_prefix = max(requested_prefix, parent.prefixlen + 8)
    if target_prefix > 124:
        raise ValueError("need a parent prefix shorter than /124 to allocate a CNI subnet")
    subnet_count = 1 << (target_prefix - parent.prefixlen)
    if requested_index >= subnet_count:
        raise ValueError("IPv6 subnet index is outside the parent prefix")

    host_children = set()
    try:
        output = subprocess.check_output(["ip", "-6", "-o", "addr", "show"], text=True, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        output = ""
    child_size = 1 << (128 - target_prefix)
    for line in output.splitlines():
        if " tentative " in f" {line} ":
            continue
        fields = line.split()
        if len(fields) < 4:
            continue
        try:
            address = ipaddress.ip_interface(fields[3]).ip
        except ValueError:
            continue
        if address.version == 6 and address in parent:
            host_children.add((int(address) - int(parent.network_address)) // child_size)

    candidates = [requested_index]
    if not explicit_index:
        for offset in range(1, min(subnet_count, 4096)):
            candidates.append((requested_index + offset) % subnet_count)
    for index in candidates:
        if index in host_children:
            continue
        address = int(parent.network_address) + index * child_size
        print(ipaddress.IPv6Network((address, target_prefix)))
        raise SystemExit(0)
    raise ValueError("all candidate CNI subnets include a live host address")
except Exception:
    raise SystemExit(1)
PY
}

create_ipv6_network() {
    local ipv6_cidr="$1"
    _yellow "Creating IPv6 CNI network..."

    local subnet_prefix="${CONTAINERD_IPV6_SUBNET_PREFIX:-$DEFAULT_CONTAINERD_IPV6_SUBNET_PREFIX}"
    local subnet_index="${CONTAINERD_IPV6_SUBNET_INDEX:-$DEFAULT_CONTAINERD_IPV6_SUBNET_INDEX}"
    local cni_config="${CONTAINERD_CNI_IPV6_CONFIG:-/etc/cni/net.d/11-containerd-ipv6.conflist}"
    local state_dir="${CONTAINERD_IPV6_STATE_DIR:-/usr/local/bin}"
    local existing_subnet="" recorded_mode="" recorded_subnet=""
    local index_explicit=false
    [[ -n "${CONTAINERD_IPV6_SUBNET_INDEX+x}" ]] && index_explicit=true
    if [[ ! "$subnet_prefix" =~ ^[0-9]+$ ]] || (( subnet_prefix < 64 || subnet_prefix > 124 )); then
        _red "Invalid CONTAINERD_IPV6_SUBNET_PREFIX='${subnet_prefix}', expected an integer from 64 to 124."
        return 1
    fi
    if [[ ! "$subnet_index" =~ ^[0-9]+$ ]]; then
        _red "Invalid CONTAINERD_IPV6_SUBNET_INDEX='${subnet_index}', expected a non-negative integer."
        return 1
    fi

    # The filename is conventional rather than exclusive ownership. A
    # re-install must not replace a CNI network unless the matching state files
    # prove it was created by this installer. Reuse either managed public IPv6
    # or ULA NAT66 so a working installation remains stable across reruns.
    if [[ -e "$cni_config" || -L "$cni_config" ]]; then
        existing_subnet=$(containerd_cni_ipv6_subnet "$cni_config" 2>/dev/null || true)
        recorded_mode=$(tr -d '[:space:]' <"${state_dir}/containerd_ipv6_network_mode" 2>/dev/null || true)
        recorded_subnet=$(tr -d '[:space:]' <"${state_dir}/containerd_ipv6_subnet" 2>/dev/null || true)
        if containerd_ipv6_state_matches_cni "$recorded_mode" "$recorded_subnet" "$existing_subnet"; then
            _green "Reusing installer-managed Containerd IPv6 CNI network: ${existing_subnet} (${recorded_mode})"
            _green "复用安装器托管的 Containerd IPv6 CNI 网络：${existing_subnet}（${recorded_mode}）"
            return 0
        fi
        _yellow "Existing Containerd IPv6 CNI network is not proven installer-managed; preserving its current configuration"
        _yellow "现有 Containerd IPv6 CNI 网络无法确认由安装器管理，保留其当前配置"
        return 1
    fi

    local prefix=""
    prefix=$(derive_containerd_ipv6_subnet "$ipv6_cidr" "$subnet_prefix" "$subnet_index" "$index_explicit" || true)
    if [[ -z "$prefix" ]]; then
        # A host-only /128 is valid IPv6 connectivity but cannot supply a CNI
        # child subnet. Keep outbound IPv6 available through an installer-owned
        # ULA bridge and NAT66 rather than disabling IPv6 entirely.
        if create_containerd_ula_ipv6_network "$ipv6_cidr"; then
            return 0
        fi
        _red "Failed to derive a dedicated IPv6 CNI subnet from locally bound ${ipv6_cidr}, and ULA NAT66 fallback was unavailable."
        return 1
    fi
    # A host route covering the parent is expected and safe: CNI installs the
    # host-disjoint child as a more-specific route. Fall back only when another
    # route already owns this exact child or a still more-specific portion.
    if cni_ipv6_subnet_conflicts_with_host_route "$prefix"; then
        if create_containerd_ula_ipv6_network "$ipv6_cidr"; then
            return 0
        fi
        _red "Could not find a safe ULA subnet after an existing route conflicted with Containerd IPv6"
        return 1
    fi
    if cni_ipv6_subnet_overlaps_existing "$prefix"; then
        _red "IPv6 CNI subnet ${prefix} overlaps an existing CNI network."
        return 1
    fi

    mkdir -p "$state_dir" || return 1
    printf '%s\n' "$ipv6_cidr" > "${state_dir}/containerd_ipv6_parent"
    printf '%s\n' "$prefix" > "${state_dir}/containerd_ipv6_subnet"
    printf '%s\n' managed > "${state_dir}/containerd_ipv6_network_mode"

    cat > "$cni_config" <<EOF
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
    return 0
}

# ======== 启动 NDP Responder ========
ndpresponder_image_matches_architecture() {
    local expected="$1"
    local actual="$2"
    case "$expected:$actual" in
        amd64:amd64|amd64:x86_64|arm64:arm64|arm64:aarch64|arm:arm|arm:armhf|arm:armv7) return 0 ;;
    esac
    return 1
}

# Resolve a responder image before touching the existing container. Published
# tags cover amd64 and arm64; ARMv7 falls back to a native source build.
resolve_ndpresponder_image() {
    local arch_tag="" registry_image="" image_arch source_image source_url source_dir
    NDPRESPONDER_IMAGE=""

    case "$ARCH_TYPE" in
        amd64) arch_tag="x86" ;;
        arm64) arch_tag="aarch64" ;;
        arm)   ;;
        *)
            _yellow "Unsupported responder architecture: ${ARCH_TYPE}"
            return 1
            ;;
    esac

    if [[ -n "$arch_tag" ]]; then
        registry_image="spiritlhl/ndpresponder_${arch_tag}"
        _yellow "Pulling ndpresponder image: ${registry_image}"
        if nerdctl pull "${registry_image}" 2>/dev/null; then
            image_arch=$(nerdctl image inspect --format '{{.Architecture}}' "${registry_image}" 2>/dev/null || true)
            if ndpresponder_image_matches_architecture "$ARCH_TYPE" "$image_arch"; then
                NDPRESPONDER_IMAGE="$registry_image"
                return 0
            fi
            _yellow "Responder image ${registry_image} is ${image_arch:-unknown}, expected ${ARCH_TYPE}; building a local responder image instead"
        else
            _yellow "Could not pull a responder image for ${ARCH_TYPE}; building a local responder image instead"
        fi
    else
        _yellow "No published responder image is configured for ${ARCH_TYPE}; building a local responder image instead"
    fi

    source_image="localhost/oneclickvirt-ndpresponder:${ARCH_TYPE}"
    source_url="${NDPRESPONDER_SOURCE_URL:-https://github.com/oneclickvirt/ndpresponder.git}"
    source_dir=$(mktemp -d /tmp/ndpresponder-build.XXXXXX) || {
        _yellow "Could not create a temporary responder source directory; preserving any existing responder"
        return 1
    }
    _yellow "Cloning ndpresponder source: ${source_url}"
    if ! GIT_TERMINAL_PROMPT=0 git clone --depth 1 -- "$source_url" "$source_dir" >/dev/null 2>&1; then
        rm -rf -- "$source_dir"
        _yellow "Could not fetch responder source; preserving any existing responder"
        return 1
    fi
    _yellow "Building ndpresponder from source: ${source_url}"
    if ! nerdctl build --tag "$source_image" "$source_dir"; then
        rm -rf -- "$source_dir"
        _yellow "Could not build a responder image from source; preserving any existing responder"
        return 1
    fi
    image_arch=$(nerdctl image inspect --format '{{.Architecture}}' "$source_image" 2>/dev/null || true)
    rm -rf -- "$source_dir"
    if ! ndpresponder_image_matches_architecture "$ARCH_TYPE" "$image_arch"; then
        _yellow "Locally built responder image ${source_image} is ${image_arch:-unknown}, expected ${ARCH_TYPE}; preserving any existing responder"
        return 1
    fi
    NDPRESPONDER_IMAGE="$source_image"
    return 0
}

start_ndpresponder() {
    local network_mode ndp_required uplink state_dir
    state_dir="${CONTAINERD_IPV6_STATE_DIR:-/usr/local/bin}"
    network_mode=""
    ndp_required=""
    if [[ -f "${state_dir}/containerd_ipv6_network_mode" ]]; then
        network_mode=$(tr -d '[:space:]' <"${state_dir}/containerd_ipv6_network_mode" 2>/dev/null || true)
    fi
    if [[ -f "${state_dir}/containerd_ipv6_ndp_required" ]]; then
        ndp_required=$(tr -d '[:space:]' <"${state_dir}/containerd_ipv6_ndp_required" 2>/dev/null || true)
    fi
    if [[ "$network_mode" == "nat" || "$ndp_required" == "false" ]]; then
        if [[ "$network_mode" != "nat" ]]; then
            _green "Containerd routed IPv6 uses a non-Ethernet uplink; NDP responder is not required"
            return 0
        fi
        _green "Containerd IPv6 uses ULA NAT66; NDP responder is not required"
        return 0
    fi
    if [[ "$ndp_required" != "true" ]]; then
        _yellow "Containerd IPv6 NDP state is incomplete; refusing to guess an IPv4 uplink"
        return 1
    fi
    uplink=""
    if [[ -f "${state_dir}/containerd_ipv6_uplink" ]]; then
        uplink=$(tr -d '[:space:]' <"${state_dir}/containerd_ipv6_uplink" 2>/dev/null || true)
    fi
    if [[ -z "$uplink" ]]; then
        _yellow "Containerd IPv6 NDP state is missing its IPv6 uplink"
        return 1
    fi
    _yellow "Starting NDP responder for IPv6..."
    local ndp_status ndp_logs ndp_image

    mkdir -p /var/lib/cni/networks
    if ! resolve_ndpresponder_image; then
        return 1
    fi
    ndp_image="$NDPRESPONDER_IMAGE"
    nerdctl rm -f ndpresponder 2>/dev/null || true

    if nerdctl run -d \
        --restart on-failure:3 \
        --cpus 0.02 \
        --memory 64m \
        --cap-drop=ALL \
        --cap-add=NET_RAW \
        --cap-add=NET_ADMIN \
        --network host \
        --volume /var/lib/cni/networks:/var/lib/cni/networks:ro \
        --name ndpresponder \
        "${ndp_image}" \
        -i "${uplink}" -C containerd-ipv6 2>/dev/null; then
        for _ndp_attempt in 1 2 3; do
            sleep 1
            ndp_status=$(nerdctl inspect -f '{{.State.Status}}' ndpresponder 2>/dev/null || true)
            if [[ "$ndp_status" == "running" ]]; then
                _green "NDP responder started and is reading CNI IPv6 leases"
                return 0
            fi
        done
        ndp_logs=$(nerdctl logs --tail 20 ndpresponder 2>&1 || true)
        _yellow "ndpresponder exited immediately: ${ndp_logs}"
    else
        _yellow "ndpresponder start failed; IPv6 may require manual NDP configuration"
    fi
    nerdctl rm -f ndpresponder 2>/dev/null || true
    return 1
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
        systemctl daemon-reload 2>/dev/null || true
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
    _blue "  2026.08.26"
    _blue "======================================================"
    echo

    # 重新计算 int（系统类型索引）
    for ((int = 0; int < ${#REGEX[@]}; int++)); do
        if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
            break
        fi
    done

    # ======== 询问是否需要硬盘限制支持（支持环境变量 NEED_DISK_LIMIT） ========
    # 支持以下环境变量实现一键安装（跳过所有交互提示）：
    #   noninteractive=true            使用默认值跳过所有交互提示
    #   NEED_DISK_LIMIT=y/yes/true/1   是否启用 btrfs 容器磁盘大小限制
    #   CONTAINERD_INSTALL_PATH=<path> containerd 存储路径（默认 /var/lib/containerd）
    #   CONTAINERD_POOL_SIZE=<整数>    存储池大小，单位 GB（仅 NEED_DISK_LIMIT 启用时有效）
    #   CONTAINERD_LOOP_FILE=<path>    loop 镜像文件路径（默认 /opt/containerd-pool.img）

    # --- 是否启用磁盘大小限制 ---
    if [[ -n "${NEED_DISK_LIMIT:-}" ]]; then
        if is_truthy "${NEED_DISK_LIMIT}"; then
            need_disk_limit_input="y"
            _yellow "环境变量 NEED_DISK_LIMIT=${NEED_DISK_LIMIT}：启用容器磁盘大小限制"
        else
            need_disk_limit_input="n"
            _yellow "环境变量 NEED_DISK_LIMIT=${NEED_DISK_LIMIT}：不启用容器磁盘大小限制"
        fi
    elif is_noninteractive; then
        need_disk_limit_input="n"
        _yellow "noninteractive=true：使用默认标准 containerd 安装，不启用容器磁盘大小限制"
    else
        _green "是否需要支持容器硬盘大小限制的 containerd 环境？（支持 btrfs 存储驱动）"
        _green "Do you need containerd with container disk size limitation? (Support btrfs storage driver)"
        _blue "如果选择 'y'，可以为每个容器限制磁盘空间 / If 'y', you can limit the disk space for each container"
        _blue "如果选择 'n'，则为标准 containerd 安装，无磁盘限制 / If 'n', standard containerd installation without disk limits"
        reading "Do you need container disk size limitation? ([n]/y): " need_disk_limit_input
    fi

    # --- containerd 存储路径 ---
    if [[ -n "${CONTAINERD_INSTALL_PATH:-}" ]]; then
        containerd_install_path="${CONTAINERD_INSTALL_PATH}"
        _yellow "环境变量 CONTAINERD_INSTALL_PATH：${containerd_install_path}"
    elif is_noninteractive; then
        containerd_install_path="$DEFAULT_CONTAINERD_INSTALL_PATH"
        _yellow "noninteractive=true：使用默认 containerd 存储路径 ${containerd_install_path}"
    else
        _green "Where do you want to install containerd storage? (Enter to default: ${DEFAULT_CONTAINERD_INSTALL_PATH}):"
        reading "containerd 存储路径？（回车则默认：${DEFAULT_CONTAINERD_INSTALL_PATH}）：" containerd_install_path
        if [ -z "$containerd_install_path" ]; then
            containerd_install_path="$DEFAULT_CONTAINERD_INSTALL_PATH"
        fi
    fi
    echo "$containerd_install_path" > /usr/local/bin/containerd_install_path

    if is_yes "$need_disk_limit_input"; then
        echo "true" > /usr/local/bin/containerd_need_disk_limit

        # --- 存储池大小 ---
        if [[ -n "${CONTAINERD_POOL_SIZE:-}" ]] && [[ "${CONTAINERD_POOL_SIZE}" =~ ^[1-9][0-9]*$ ]]; then
            containerd_pool_size="${CONTAINERD_POOL_SIZE}"
            _yellow "环境变量 CONTAINERD_POOL_SIZE：${containerd_pool_size}GB"
        elif is_noninteractive; then
            containerd_pool_size="$DEFAULT_CONTAINERD_POOL_SIZE"
            _yellow "noninteractive=true：CONTAINERD_POOL_SIZE 未提供或无效，使用默认 ${containerd_pool_size}GB"
        else
            while true; do
                _green "How large a containerd storage pool is needed? (unit: GB, e.g., enter 20 for 20G):"
                reading "需要多大的 containerd 存储池？（单位GB，例如输入20表示20G）：" containerd_pool_size
                if [[ "$containerd_pool_size" =~ ^[1-9][0-9]*$ ]]; then
                    break
                else
                    _yellow "Invalid input, please enter a positive integer. / 输入无效，请输入一个正整数。"
                fi
            done
        fi

        # --- loop 文件路径 ---
        if [[ -n "${CONTAINERD_LOOP_FILE:-}" ]]; then
            containerd_loop_file="${CONTAINERD_LOOP_FILE}"
            _yellow "环境变量 CONTAINERD_LOOP_FILE：${containerd_loop_file}"
        elif is_noninteractive; then
            containerd_loop_file="$DEFAULT_CONTAINERD_LOOP_FILE"
            _yellow "noninteractive=true：使用默认 containerd loop 文件 ${containerd_loop_file}"
        else
            _green "Where do you want to store the containerd loop file? (Enter to default: ${DEFAULT_CONTAINERD_LOOP_FILE}):"
            reading "containerd 循环文件存储位置？（回车则默认：${DEFAULT_CONTAINERD_LOOP_FILE}）：" containerd_loop_file
            if [ -z "$containerd_loop_file" ]; then
                containerd_loop_file="$DEFAULT_CONTAINERD_LOOP_FILE"
            fi
        fi

        _green "将安装支持容器磁盘大小限制的 containerd 环境（btrfs 存储驱动）"
        _green "Will install containerd with container disk size limitation support (btrfs storage driver)"
    else
        echo "false" > /usr/local/bin/containerd_need_disk_limit
        containerd_pool_size=""
        containerd_loop_file=""
        _green "将安装标准 containerd，无容器磁盘大小限制功能"
        _green "Will install standard containerd without container disk size limitation"
    fi

    install_base_deps
    detect_interface
    check_ipv6

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

    if [[ "$IPV6_ENABLED" == true ]] && \
       create_ipv6_network "$IPV6_CIDR" && \
       adapt_ipv6 && \
       configure_containerd_ipv6_ndp_state && \
       start_ndpresponder; then
        echo "true" > /usr/local/bin/containerd_ipv6_enabled
    else
        _yellow "Independent IPv6 was not enabled; IPv4 container networking remains available"
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
