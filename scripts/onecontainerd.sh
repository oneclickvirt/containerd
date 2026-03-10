#!/bin/bash
# from
# https://github.com/oneclickvirt/containerd
# 2026.03.01

# Usage:
# ./onecontainerd.sh <name> <cpu> <memory_mb> <password> <sshport> <startport> <endport> [independent_ipv6:y/n] [system] [disk_gb]

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi

# ======== 参数 ========
name="${1:-test}"
cpu="${2:-1}"
memory="${3:-512}"
passwd="${4:-123456}"
sshport="${5:-25000}"
startport="${6:-34975}"
endport="${7:-35000}"
independent_ipv6="${8:-N}"
system="${9:-debian}"
disk="${10:-0}"

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

# ======== 架构及 CDN ========
ARCH_UNAME=$(uname -m)
case "$ARCH_UNAME" in
    x86_64)  ARCH_TYPE="amd64" ;;
    aarch64) ARCH_TYPE="arm64" ;;
    *)       ARCH_TYPE="amd64" ;;
esac
# 读取安装时保存的架构
if [[ -f /usr/local/bin/containerd_arch ]]; then
    ARCH_TYPE=$(cat /usr/local/bin/containerd_arch)
fi

# CDN
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

# ======== 检查 btrfs 存储驱动支持 ========
check_storage_driver() {
    btrfs_support="N"
    storage_driver="overlayfs"
    if [ -f /usr/local/bin/containerd_storage_driver ]; then
        storage_driver=$(cat /usr/local/bin/containerd_storage_driver)
    fi
    if [ "$storage_driver" = "btrfs" ]; then
        btrfs_support="Y"
        _green "Detected btrfs snapshotter, disk size limitation is supported"
        _green "检测到 btrfs 快照器，支持硬盘大小限制"
    else
        btrfs_support="N"
        if [ "$disk" != "0" ]; then
            _yellow "Current snapshotter ($storage_driver) does not support disk size limitation, ignoring disk parameter"
            _yellow "当前快照器（$storage_driver）不支持硬盘大小限制，忽略硬盘参数"
            disk="0"
        fi
    fi
}

check_storage_driver

# ======== 公网 IP 检测 ========
IPV4=""
check_ipv4() {
    local API_NET=("ip.sb" "ipget.net" "ip.ping0.cc" "https://ip4.seeip.org" "https://api.my-ip.io/ip" "https://ipv4.icanhazip.com" "api.ipify.org")
    for p in "${API_NET[@]}"; do
        local response
        response=$(curl -s4m8 "$p" 2>/dev/null | tr -d '[:space:]')
        if [[ $? -eq 0 && -n "$response" ]] && ! echo "$response" | grep -q "error"; then
            IPV4="$response"
            return 0
        fi
        sleep 0.5
    done
    # fallback：从路由获取本机 IP
    IPV4=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
}

check_ipv4

# ======== 检查 nerdctl ========
if ! command -v nerdctl >/dev/null 2>&1 && [[ ! -x /usr/local/bin/nerdctl ]]; then
    _red "nerdctl not found. Please run containerdinstall.sh first."
    exit 1
fi

# ======== IPv6 检测 ========
IPV6_ENABLED=false
if [[ -f /usr/local/bin/containerd_ipv6_enabled ]]; then
    if [[ "$(cat /usr/local/bin/containerd_ipv6_enabled)" == "true" ]]; then
        IPV6_ENABLED=true
    fi
fi

# ======== lxcfs 检测（提供 /proc 虚假值） ========
lxcfs_volumes=""
for dir in /var/lib/lxcfs/proc /var/lib/lxcfs; do
    if [[ -d "$dir/proc" ]]; then
        lxcfs_volumes="-v ${dir}/proc/cpuinfo:/proc/cpuinfo:rw \
            -v ${dir}/proc/diskstats:/proc/diskstats:rw \
            -v ${dir}/proc/meminfo:/proc/meminfo:rw \
            -v ${dir}/proc/stat:/proc/stat:rw \
            -v ${dir}/proc/uptime:/proc/uptime:rw"
        break
    fi
done

# ======== 下载并加载镜像 ========
get_arch() {
    echo "$ARCH_TYPE"
}

download_and_load_image() {
    local system_type="$1"
    local arch
    arch=$(get_arch)
    local tar_filename="spiritlhl_${system_type}_${arch}.tar.gz"
    # 本仓库 tar 包加载后的标准镜像名（docker.io/spiritlhl/<sys>:latest）
    local canonical_image="spiritlhl/${system_type}:latest"

    # 检查镜像是否已存在
    if nerdctl images 2>/dev/null | grep -qE "^spiritlhl/${system_type}\s"; then
        _green "Image ${canonical_image} already exists, skipping download"
        export image_name="${canonical_image}"
        return 0
    fi

    # 优先通过 CDN/GitHub Releases 下载离线 tar 包
    local github_url="https://github.com/oneclickvirt/containerd/releases/download/${system_type}/${tar_filename}"
    local download_url="${cdn_success_url}${github_url}"
    _yellow "Downloading image: $download_url"

    if curl -L --connect-timeout 15 --max-time 600 -o "/tmp/${tar_filename}" "$download_url" && \
       [[ -f "/tmp/${tar_filename}" ]] && [[ -s "/tmp/${tar_filename}" ]]; then
        _yellow "Loading image from tar..."
        if nerdctl load < "/tmp/${tar_filename}"; then
            rm -f "/tmp/${tar_filename}"
            export image_name="${canonical_image}"
            _green "Image loaded: ${image_name}"
            return 0
        else
            _yellow "Failed to load tar, removing..."
            rm -f "/tmp/${tar_filename}"
        fi
    else
        _yellow "CDN/direct download failed for ${download_url}"
        rm -f "/tmp/${tar_filename}" 2>/dev/null
    fi

    # 回退：从 ghcr.io 拉取镜像
    local ghcr_image="ghcr.io/oneclickvirt/containerd:${system_type}-${arch}"
    _yellow "Trying to pull from ghcr.io: $ghcr_image"
    if nerdctl pull "$ghcr_image"; then
        nerdctl tag "$ghcr_image" "${canonical_image}" 2>/dev/null || true
        export image_name="${canonical_image}"
        _green "Image pulled from ghcr.io: ${ghcr_image}"
        return 0
    fi

    _red "Failed to obtain image for ${system_type}"
    exit 1
}

# ======== 下载 SSH 初始化脚本 ========
download_ssh_scripts() {
    local cname="$1"
    local sys_type="$2"

    local base_url="${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/containerd/main/scripts"

    if [[ "$sys_type" == "alpine" ]]; then
        curl -sL --connect-timeout 10 --max-time 30 \
            "${base_url}/ssh_sh.sh" -o /tmp/ssh_sh.sh 2>/dev/null || true
        if [[ -f /tmp/ssh_sh.sh ]]; then
            nerdctl cp /tmp/ssh_sh.sh "${cname}:/ssh_sh.sh" 2>/dev/null || true
        fi
    else
        curl -sL --connect-timeout 10 --max-time 30 \
            "${base_url}/ssh_bash.sh" -o /tmp/ssh_bash.sh 2>/dev/null || true
        if [[ -f /tmp/ssh_bash.sh ]]; then
            nerdctl cp /tmp/ssh_bash.sh "${cname}:/ssh_bash.sh" 2>/dev/null || true
        fi
    fi
}

# ======== 主逻辑 ========
main() {
    _blue "Creating container: name=${name} cpu=${cpu} memory=${memory}MB system=${system}"
    _blue "SSH port: ${sshport}  port range: ${startport}-${endport}  IPv6: ${independent_ipv6}"

    # 下载/加载镜像
    download_and_load_image "$system"

    # 网络选项
    local net_opts=""
    if [[ "${independent_ipv6,,}" == "y" ]] && [[ "$IPV6_ENABLED" == "true" ]]; then
        net_opts="--network containerd-ipv6"
        ipv6_env="-e IPV6_ENABLED=true"
    else
        net_opts="--network containerd-net"
        ipv6_env=""
    fi

    # 存储限制选项
    # nerdctl + containerd btrfs 快照器支持 --storage-opt size=Xg
    local storage_opts=""
    local snapshotter_opts=""
    if [[ "$disk" -gt 0 ]]; then
        if [ "$btrfs_support" = "Y" ]; then
            snapshotter_opts="--snapshotter btrfs"
            storage_opts="--storage-opt size=${disk}g"
            _green "Disk size limitation enabled: ${disk}GB (btrfs snapshotter)"
            _green "已启用硬盘大小限制：${disk}GB（使用 btrfs 快照器）"
        else
            _yellow "Disk size limitation requires btrfs snapshotter, but current snapshotter is: $storage_driver"
            _yellow "硬盘大小限制需要 btrfs 快照器，当前快照器为: $storage_driver"
            _yellow "Please reinstall with disk limitation support enabled (choose 'y' for disk limit in the installer)"
            _yellow "请重新安装时选择启用硬盘限制支持（安装脚本中选择 'y'）"
            disk="0"
        fi
    fi

    # 运行容器（--pull=never 确保使用本地已加载的镜像，不尝试远程拉取）
    nerdctl run -d \
        --pull=never \
        --cpus="${cpu}" \
        --memory="${memory}m" \
        --name "${name}" \
        ${net_opts} \
        -p "${sshport}:22" \
        -p "${startport}-${endport}:${startport}-${endport}" \
        --cap-add=MKNOD \
        --restart always \
        ${snapshotter_opts} \
        ${storage_opts} \
        ${lxcfs_volumes} \
        ${ipv6_env} \
        -e ROOT_PASSWORD="${passwd}" \
        "${image_name}"

    if [[ $? -ne 0 ]]; then
        _red "Failed to create container ${name}"
        exit 1
    fi

    _green "Container ${name} created successfully"
    sleep 3

    # ======== 补充 iptables NAT/FORWARD 规则（防止系统未自动添加） ========
    if command -v iptables >/dev/null 2>&1; then
        # IPv4 MASQUERADE
        iptables -t nat -C POSTROUTING -s 172.20.0.0/16 ! -d 172.20.0.0/16 -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s 172.20.0.0/16 ! -d 172.20.0.0/16 -j MASQUERADE 2>/dev/null || true
        # IPv4 FORWARD
        iptables -C FORWARD -s 172.20.0.0/16 -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -s 172.20.0.0/16 -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -d 172.20.0.0/16 -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -d 172.20.0.0/16 -j ACCEPT 2>/dev/null || true
    fi
    # IPv6 FORWARD（仅当使用 IPv6 网络时）
    if [[ "${independent_ipv6,,}" == "y" ]] && command -v ip6tables >/dev/null 2>&1; then
        ip6tables -C FORWARD -i ctn-br1 -j ACCEPT 2>/dev/null || \
            ip6tables -A FORWARD -i ctn-br1 -j ACCEPT 2>/dev/null || true
        ip6tables -C FORWARD -o ctn-br1 -j ACCEPT 2>/dev/null || \
            ip6tables -A FORWARD -o ctn-br1 -j ACCEPT 2>/dev/null || true
        if [[ -f /usr/local/bin/containerd_ipv6_subnet ]]; then
            local ipv6_subnet
            ipv6_subnet=$(cat /usr/local/bin/containerd_ipv6_subnet)
            ip6tables -C FORWARD -s "${ipv6_subnet}" -j ACCEPT 2>/dev/null || \
                ip6tables -A FORWARD -s "${ipv6_subnet}" -j ACCEPT 2>/dev/null || true
            ip6tables -C FORWARD -d "${ipv6_subnet}" -j ACCEPT 2>/dev/null || \
                ip6tables -A FORWARD -d "${ipv6_subnet}" -j ACCEPT 2>/dev/null || true
        fi
    fi

    # 下载并执行 SSH 初始化脚本
    download_ssh_scripts "$name" "$system"

    if [[ "$system" == "alpine" ]]; then
        if nerdctl exec "${name}" test -f /ssh_sh.sh 2>/dev/null; then
            nerdctl exec "${name}" sh -c "sh /ssh_sh.sh '${passwd}'" 2>/dev/null || true
        else
            # 镜像内置 entrypoint 处理 SSH，无需外部脚本
            _yellow "ssh_sh.sh not found in container, relying on built-in entrypoint"
        fi
        nerdctl exec "${name}" sh -c "echo 'root:${passwd}' | chpasswd" 2>/dev/null || true
    else
        if nerdctl exec "${name}" test -f /ssh_bash.sh 2>/dev/null; then
            nerdctl exec "${name}" bash -c "bash /ssh_bash.sh '${passwd}'" 2>/dev/null || true
        else
            _yellow "ssh_bash.sh not found in container, relying on built-in entrypoint"
        fi
        nerdctl exec "${name}" bash -c "echo 'root:${passwd}' | chpasswd" 2>/dev/null || true
    fi

    # 尝试启动 sshd（防止某些镜像 entrypoint 未自动启动）
    if [[ "$system" == "alpine" ]]; then
        nerdctl exec "${name}" sh -c "command -v sshd && sshd" 2>/dev/null || true
    else
        nerdctl exec "${name}" bash -c "command -v sshd && (service ssh start 2>/dev/null || service sshd start 2>/dev/null || /usr/sbin/sshd 2>/dev/null)" 2>/dev/null || true
    fi

    sleep 2

    echo "$name $sshport $passwd $cpu $memory $startport $endport $disk" >>"$name"
    cat "$name"

    # ======== 显示连接信息 ========
    echo
    _green "======================================================"
    _green "  Container Info:"
    _green "  Name:    ${name}"
    _green "  System:  ${system}"
    _green "  CPU:     ${cpu}   Memory: ${memory}MB   Disk: ${disk}GB"
    if [[ -n "$IPV4" ]]; then
        _green "  SSH:     ssh root@${IPV4} -p ${sshport}"
    else
        _green "  SSH port: ${sshport}  (connect via host public IP)"
    fi
    _green "  Password: ${passwd}"
    _green "  Ports:   ${startport}-${endport} → ${startport}-${endport} (NAT)"
    if [[ "${independent_ipv6,,}" == "y" ]] && [[ "$IPV6_ENABLED" == "true" ]]; then
        _green "  IPv6:    Independent public IPv6 address assigned"
    fi
    _green "======================================================"
}

main "$@"
