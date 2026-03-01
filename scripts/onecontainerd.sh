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
cdn_success_url=""
if [[ -f /usr/local/bin/containerd_cdn ]]; then
    cdn_success_url=$(cat /usr/local/bin/containerd_cdn)
else
    ip_info=$(curl -sLk --connect-timeout 5 --max-time 10 "https://ipapi.co/json/" 2>/dev/null || true)
    if echo "$ip_info" | grep -q '"country": "CN"'; then
        cdn_success_url="https://cdn.spiritlhl.net/"
        echo "$cdn_success_url" > /usr/local/bin/containerd_cdn
    fi
fi

# ======== 检查 nerdctl ========
if ! command -v nerdctl >/dev/null 2>&1; then
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

    # 优先从本仓库 GitHub Releases 下载离线 tar 包
    local download_url="${cdn_success_url}https://github.com/oneclickvirt/containerd/releases/download/${system_type}/${tar_filename}"
    _yellow "Downloading image: $download_url"

    if curl -L --connect-timeout 15 --max-time 600 -o "/tmp/${tar_filename}" "$download_url"; then
        _yellow "Loading image from tar..."
        if nerdctl load < "/tmp/${tar_filename}"; then
            rm -f "/tmp/${tar_filename}"
            # tar 包内镜像即为 spiritlhl/<sys>:latest，直接使用，无需 re-tag
            export image_name="${canonical_image}"
            _green "Image loaded: ${image_name}"
            return 0
        else
            rm -f "/tmp/${tar_filename}"
            _yellow "Failed to load tar, falling back to registry pull..."
        fi
    else
        _yellow "Failed to download tar, falling back to registry pull..."
    fi

    # 回退：从 Docker Hub 拉取官方镜像，并打标签为 spiritlhl/<sys>:latest 保持一致
    case "$system_type" in
        ubuntu)       fallback_image="ubuntu:22.04" ;;
        debian)       fallback_image="debian:12" ;;
        alpine)       fallback_image="alpine:latest" ;;
        almalinux)    fallback_image="almalinux:9" ;;
        rockylinux)   fallback_image="rockylinux:9" ;;
        openeuler)    fallback_image="openeuler/openeuler:22.03" ;;
        *)            fallback_image="${system_type}:latest" ;;
    esac
    _yellow "Pulling fallback image: $fallback_image"
    if nerdctl pull "$fallback_image"; then
        nerdctl tag "$fallback_image" "${canonical_image}" 2>/dev/null || true
        export image_name="${canonical_image}"
        _green "Fallback image ready: ${image_name}"
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

    # 存储限制选项 (nerdctl 支持 --device 来限制，但不支持 btrfs quota 方式)
    # 若需要磁盘限制，需要 overlay2 + xfs quota 或 btrfs
    local storage_opts=""
    # nerdctl 支持 --storage-opt size=Xg（需要xfs/btrfs snapshotter）
    if [[ "$disk" -gt 0 ]]; then
        storage_opts="--storage-opt size=${disk}g"
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

    # 获取宿主机 IP
    host_ip=$(curl -sL4m8 ip.sb 2>/dev/null || curl -sL4m8 ifconfig.me 2>/dev/null || ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')

    # 输出容器信息并保存到日志文件
    {
        echo "Container name:  $name"
        echo "System:          $system"
        echo "CPU:             $cpu core(s)"
        echo "Memory:          ${memory} MB"
        echo "Disk limit:      ${disk} GB (0=unlimited)"
        echo "SSH:             ${host_ip}  port ${sshport}"
        echo "Password:        $passwd"
        echo "Port range:      ${startport}-${endport}"
        echo "IPv6 standalone: ${independent_ipv6}"
    } | tee "${name}"

    _green "Container info saved to file: ${name}"
    _blue "Connect: ssh root@${host_ip} -p ${sshport}  (password: ${passwd})"
}

main "$@"
