#!/bin/bash
# from
# https://github.com/oneclickvirt/containerd
# 2026.03.01

# Usage:
# ./onecontainerd.sh <name> <cpu> <memory_mb> <password> <sshport> <startport> <endport> [independent_ipv6:y/n] [system] [disk_gb]

set -euo pipefail

_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$*\033[0m"; }
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
SCRIPT_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi

# ======== 参数 ========
name="${1:-test}"
cpu="${2:-1}"
memory="${3:-512}"
passwd="${4:-}"
sshport="${5:-25000}"
startport="${6:-34975}"
endport="${7:-35000}"
independent_ipv6="${8:-N}"
system="${9:-debian}"
disk="${10:-0}"

generate_password() {
    local password=""
    if command -v openssl >/dev/null 2>&1; then
        password=$(openssl rand -hex 16 2>/dev/null || true)
    fi
    if [[ -z "$password" ]] && [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
        password=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    fi
    if [[ -z "$password" ]]; then
        password=$(printf '%s%s' "$(date +%s%N)" "$RANDOM" | md5sum 2>/dev/null | awk '{print substr($1,1,32)}')
    fi
    if [[ -z "$password" ]]; then
        password="${RANDOM}${RANDOM}${RANDOM}${RANDOM}"
    fi
    printf '%s\n' "${password:0:32}"
}

valid_nonnegative_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }
valid_positive_integer() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
valid_cpu_value() {
    [[ "$1" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || return 1
    [[ "$1" =~ ^0*([.]0*)?$ ]] && return 1
    return 0
}
print_supported_container_systems() {
    _yellow "Supported system values: ubuntu / debian / alpine / almalinux / rockylinux / openeuler"
    _yellow "Supported version aliases: ubuntu22, ubuntu22.04, ubuntu/22.04, debian12, debian/12, alpine/latest, almalinux9, alma9, rockylinux9, rocky9, openeuler22.03, openeuler/22.03"
}
normalize_container_system() {
    local raw="${1:-}"
    local compact
    compact=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]' | sed -E 's#[/:._-]##g')
    case "$compact" in
        ubuntu|ubuntu22|ubuntu2204)
            printf 'ubuntu\n'
            ;;
        debian|debian12)
            printf 'debian\n'
            ;;
        alpine|alpinelatest)
            printf 'alpine\n'
            ;;
        almalinux|almalinux9|alma|alma9)
            printf 'almalinux\n'
            ;;
        rockylinux|rockylinux9|rocky|rocky9)
            printf 'rockylinux\n'
            ;;
        openeuler|openeuler22|openeuler2203)
            printf 'openeuler\n'
            ;;
        *)
            return 1
            ;;
    esac
}
valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    local port_num=$((10#$1))
    (( port_num >= 1 && port_num <= 65535 ))
}

validate_inputs() {
    if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_.-]*$ ]]; then
        _red "Invalid container name '${name}'. Use letters, numbers, dots, underscores, or hyphens; start with a letter."
        exit 1
    fi
    if [[ -z "$passwd" ]]; then
        passwd=$(generate_password)
        _yellow "No password provided, generated a random root password."
    fi
    if [[ "$passwd" == *$'\n'* || "$passwd" == *$'\r'* ]]; then
        _red "Invalid password: newline characters are not supported."
        exit 1
    fi
    if ! valid_cpu_value "$cpu"; then
        _red "Invalid CPU value '${cpu}'. Expected a positive number, e.g. 1 or 0.5."
        exit 1
    fi
    if ! valid_positive_integer "$memory"; then
        _red "Invalid memory '${memory}'. Expected a positive integer in MB."
        exit 1
    fi
    if ! valid_port "$sshport" || ! valid_port "$startport" || ! valid_port "$endport"; then
        _red "Invalid port. sshport/startport/endport must be in 1-65535."
        exit 1
    fi
    sshport=$((10#$sshport))
    startport=$((10#$startport))
    endport=$((10#$endport))
    if (( startport > endport )); then
        _red "Invalid port range: startport (${startport}) must be <= endport (${endport})."
        exit 1
    fi
    if (( sshport >= startport && sshport <= endport )); then
        _red "Invalid port mapping: sshport (${sshport}) overlaps the public port range (${startport}-${endport})."
        exit 1
    fi
    local requested_system="$system"
    local normalized_system
    if ! normalized_system=$(normalize_container_system "$requested_system"); then
        _red "Unsupported container system '${requested_system}'."
        print_supported_container_systems
        exit 1
    fi
    if [[ "$(printf '%s' "$requested_system" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" != "$normalized_system" ]]; then
        _blue "Normalized container system '${requested_system}' to '${normalized_system}'"
    fi
    system="$normalized_system"
    if ! valid_nonnegative_integer "$disk"; then
        _red "Invalid disk limit '${disk}'. Expected a non-negative integer in GB."
        exit 1
    fi
    case "${independent_ipv6,,}" in
        y|yes|true|1) independent_ipv6="y" ;;
        *) independent_ipv6="n" ;;
    esac
}

validate_inputs

# ======== 系统检测 ========
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch" "Alpine")
# shellcheck disable=SC2034
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
if [[ -z "$SYSTEM" ]]; then
    _red "ERROR: The script does not support the current system!"
    exit 1
fi

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
    local API_NET=("https://ip.sb" "https://ipget.net" "https://ip.ping0.cc" "https://ip4.seeip.org" "https://api.my-ip.io/ip" "https://ipv4.icanhazip.com" "https://api.ipify.org")
    for p in "${API_NET[@]}"; do
        local response
        response=$(curl -s4m8 "$p" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ -n "$response" ]] && echo "$response" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            IPV4="$response"
            return 0
        fi
        sleep 0.5
    done
    # fallback：从路由获取本机 IP
    IPV4=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || true)
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
lxcfs_volume_args=()
for dir in /var/lib/lxcfs/proc /var/lib/lxcfs; do
    if [[ -d "$dir/proc" ]]; then
        lxcfs_volume_args=(
            -v "${dir}/proc/cpuinfo:/proc/cpuinfo:rw"
            -v "${dir}/proc/diskstats:/proc/diskstats:rw"
            -v "${dir}/proc/meminfo:/proc/meminfo:rw"
            -v "${dir}/proc/stat:/proc/stat:rw"
            -v "${dir}/proc/uptime:/proc/uptime:rw"
        )
        break
    fi
done

# ======== 下载并加载镜像 ========
get_arch() {
    echo "$ARCH_TYPE"
}

get_platform() {
    case "$(get_arch)" in
        amd64) echo "linux/amd64" ;;
        arm64) echo "linux/arm64" ;;
        arm)   echo "linux/arm/v7" ;;
        *)     echo "linux/amd64" ;;
    esac
}

image_ref_exists() {
    local img="$1"
    nerdctl image inspect "$img" >/dev/null 2>&1 || \
        nerdctl image inspect "docker.io/$img" >/dev/null 2>&1
}

repair_oci_archive_platform() {
    local tar_gz_path="$1"
    local platform="$2"
    local arch
    arch="${platform##*/}"  # "linux/amd64" -> "amd64"

    _yellow "Checking and repairing OCI archive platform field (arch: ${arch})..."

    # Validate the gzip file first
    if ! gzip -t "$tar_gz_path" 2>/dev/null; then
        _yellow "gzip integrity check failed, skipping repair"
        return 1
    fi
    if ! tar -tzf "$tar_gz_path" >/dev/null 2>&1; then
        _yellow "tar listing failed, skipping repair"
        return 1
    fi

    # Check if python3 is available
    if ! command -v python3 >/dev/null 2>&1; then
        _yellow "python3 not available, skipping OCI repair"
        return 1
    fi

    # Inline Python: patch index.json (OCI) or manifest.json (Docker) inside the gzipped tar.
    python3 - "$tar_gz_path" "$arch" <<'PYREPAIR' 2>/dev/null || return 1
import json, tarfile, io, sys, os, gzip, tempfile, shutil

tar_gz_path, arch = sys.argv[1], sys.argv[2]
platform_obj = {"architecture": arch, "os": "linux"}

# Decompress to a temp tar
with gzip.open(tar_gz_path, "rb") as f_in:
    raw_tar = f_in.read()

with tarfile.open(fileobj=io.BytesIO(raw_tar)) as tf:
    names = tf.getnames()

needs_repair = False

if "index.json" in names:
    with tarfile.open(fileobj=io.BytesIO(raw_tar)) as tf:
        idx_data = json.loads(tf.extractfile("index.json").read())
    for m in idx_data.get("manifests", []):
        if "platform" not in m:
            m["platform"] = platform_obj
            needs_repair = True
    if not needs_repair:
        sys.exit(0)  # Already has platform, nothing to do
    fixed_idx = json.dumps(idx_data, separators=(",", ":")).encode() + b"\n"

    out_bio = io.BytesIO()
    with tarfile.open(fileobj=out_bio, mode="w") as out:
        with tarfile.open(fileobj=io.BytesIO(raw_tar)) as tf:
            for member in tf.getmembers():
                if member.name == "index.json":
                    member.size = len(fixed_idx)
                    out.addfile(member, io.BytesIO(fixed_idx))
                else:
                    out.addfile(member, tf.extractfile(member))
    out_bio.seek(0)
    new_raw_tar = out_bio.read()

elif "manifest.json" in names:
    with tarfile.open(fileobj=io.BytesIO(raw_tar)) as tf:
        mf_data = json.loads(tf.extractfile("manifest.json").read())
    for entry in mf_data:
        if "platform" not in entry:
            entry["platform"] = {"os": "linux", "architecture": arch}
            needs_repair = True
    if not needs_repair:
        sys.exit(0)
    fixed_mf = json.dumps(mf_data, separators=(",", ":")).encode() + b"\n"

    out_bio = io.BytesIO()
    with tarfile.open(fileobj=out_bio, mode="w") as out:
        with tarfile.open(fileobj=io.BytesIO(raw_tar)) as tf:
            for member in tf.getmembers():
                if member.name == "manifest.json":
                    member.size = len(fixed_mf)
                    out.addfile(member, io.BytesIO(fixed_mf))
                else:
                    out.addfile(member, tf.extractfile(member))
    out_bio.seek(0)
    new_raw_tar = out_bio.read()
else:
    sys.exit(1)  # Unknown format

# Recompress
with gzip.open(tar_gz_path, "wb") as f_out:
    f_out.write(new_raw_tar)

print(f"[OK] Platform field injected: {platform_obj}")
PYREPAIR
    local ret=$?
    if [[ $ret -eq 0 ]]; then
        _green "OCI archive platform field repaired (${platform})"
        return 0
    fi
    return 1
}

load_image_archive() {
    local tar_path="$1"
    local platform="$2"

    # Step 0: Validate the archive
    if ! gzip -t "$tar_path" 2>/dev/null; then
        _yellow "gzip integrity check failed for ${tar_path}"
    fi

    # Step 1: Attempt to repair platform info in index.json / manifest.json.
    # This fixes the "no unpack platforms defined" error in containerd/nerdctl v2.3.1+
    # caused by docker save omitting the platform field from OCI index.json.
    repair_oci_archive_platform "$tar_path" "$platform" || true

    # Step 2: Try nerdctl load with explicit --platform
    if nerdctl load --platform="$platform" --input="$tar_path"; then
        return 0
    fi

    # Step 3: Try nerdctl load with --all-platforms (may pick the only one available)
    _yellow "nerdctl load --platform failed, trying --all-platforms..."
    if nerdctl load --all-platforms --input="$tar_path"; then
        return 0
    fi

    # Step 4: Fall back to ctr import with explicit --platform
    _yellow "nerdctl load --all-platforms also failed, trying ctr import with --local and explicit platform..."
    if command -v ctr >/dev/null 2>&1; then
        # ctr images import doesn't handle .tar.gz directly; decompress first
        local tmp_tar="${tar_path%.gz}"
        if [[ "$tar_path" == *.gz ]]; then
            gzip -dc "$tar_path" > "$tmp_tar"
            if ctr images import --local --platform "$platform" "$tmp_tar"; then
                rm -f "$tmp_tar"
                return 0
            fi
            rm -f "$tmp_tar"
        elif ctr images import --local --platform "$platform" "$tar_path"; then
            return 0
        fi
    fi

    return 1
}

download_and_load_image() {
    local system_type="$1"
    local arch
    arch=$(get_arch)
    local platform
    platform=$(get_platform)
    local tar_filename="spiritlhl_${system_type}_${arch}.tar.gz"
    # 本仓库 tar 包加载后的标准镜像名（docker.io/spiritlhl/<sys>:latest）
    local canonical_image="spiritlhl/${system_type}:latest"
    # 默认优先使用 GitHub Releases 离线包。公开仓库当前没有 GHCR Packages，
    # 只有显式设置 CONTAINERD_IMAGE_REGISTRY 时才先尝试 registry。
    local image_registry="${CONTAINERD_IMAGE_REGISTRY:-}"
    local release_base="${CONTAINERD_IMAGE_RELEASE_BASE:-https://github.com/oneclickvirt/containerd/releases/download}"

    # 检查镜像是否已存在
    if image_ref_exists "${canonical_image}"; then
        _green "Image ${canonical_image} already exists, skipping download"
        export image_name="${canonical_image}"
        return 0
    fi

    local release_url="${release_base%/}/${system_type}/${tar_filename}"
    local download_url="$release_url"
    if [[ -n "$cdn_success_url" && "$release_url" == https://github.com/* ]]; then
        download_url="${cdn_success_url}${release_url}"
    fi
    _yellow "Downloading image tarball: $download_url"

    if curl -L --connect-timeout 15 --max-time 600 -o "/tmp/${tar_filename}" "$download_url" && \
       [[ -f "/tmp/${tar_filename}" ]] && [[ -s "/tmp/${tar_filename}" ]]; then
        _yellow "Loading image from tar..."
        if load_image_archive "/tmp/${tar_filename}" "$platform"; then
            rm -f "/tmp/${tar_filename}"
            # 确保最终使用统一镜像名。不同 nerdctl 版本可能保存为 docker.io/spiritlhl/...
            if image_ref_exists "${canonical_image}"; then
                :
            elif image_ref_exists "docker.io/${canonical_image}"; then
                nerdctl tag "docker.io/${canonical_image}" "${canonical_image}" 2>/dev/null || true
            fi
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

    # Registry 回退只在显式指定 CONTAINERD_IMAGE_REGISTRY 时启用，避免默认 GHCR 403/404 拖慢并误导。
    if [[ -n "$image_registry" ]]; then
        local primary_image="${image_registry}:${system_type}"
        local arch_image="${image_registry}:${system_type}-${arch}"
        local pull_candidates=("$primary_image" "$arch_image")
        local remote_image
        for remote_image in "${pull_candidates[@]}"; do
            _yellow "Trying to pull image: $remote_image"
            if nerdctl pull --platform="$platform" "$remote_image"; then
                nerdctl tag "$remote_image" "${canonical_image}" 2>/dev/null || true
                export image_name="${canonical_image}"
                _green "Image pulled: ${remote_image}"
                return 0
            fi
        done
    fi

    _red "Failed to obtain image for ${system_type}"
    exit 1
}

# ======== 持久化 iptables/ip6tables 规则 ========
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
            systemctl restart netfilter-persistent 2>/dev/null || true
        fi
    elif [[ "$SYSTEM" == "CentOS" || "$SYSTEM" == "Fedora" ]]; then
        service iptables save 2>/dev/null || \
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
    fi
    _green "iptables/ip6tables rules persisted"
}

# ======== 下载 SSH 初始化脚本 ========
download_ssh_scripts() {
    local cname="$1"
    local sys_type="$2"

    local base_url="${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/containerd/main/scripts"
    local local_script=""
    local target_script=""

    if [[ "$sys_type" == "alpine" ]]; then
        local_script="${SCRIPT_SOURCE_DIR}/ssh_sh.sh"
        target_script="/tmp/ssh_sh.sh"
    else
        local_script="${SCRIPT_SOURCE_DIR}/ssh_bash.sh"
        target_script="/tmp/ssh_bash.sh"
    fi

    if [[ -s "$local_script" ]]; then
        cp "$local_script" "$target_script"
    else
        curl -sL --connect-timeout 10 --max-time 30 \
            "${base_url}/$(basename "$target_script")" -o "$target_script" 2>/dev/null || true
    fi

    if [[ -s "$target_script" ]]; then
        nerdctl cp "$target_script" "${cname}:/$(basename "$target_script")" 2>/dev/null || true
    fi
}

list_used_host_ports() {
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn 2>/dev/null | awk '{
            addr=$4
            sub(/.*:/, "", addr)
            if (addr ~ /^[0-9]+$/) print addr
        }' || true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk 'NR > 2 {
            addr=$4
            sub(/.*:/, "", addr)
            if (addr ~ /^[0-9]+$/) print addr
        }' || true
    fi

    nerdctl ps -a --format '{{.Ports}}' 2>/dev/null \
        | tr ',' '\n' \
        | sed -nE 's/.*:([0-9]+)->.*/\1/p' || true
}

check_container_name_available() {
    if nerdctl ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$name"; then
        _red "Container name '${name}' already exists."
        exit 1
    fi
}

check_port_conflicts() {
    local used_ports
    used_ports=" $(list_used_host_ports | sort -n | uniq | tr '\n' ' ') "
    local conflicts=()
    local port

    for ((port = startport; port <= endport; port++)); do
        if [[ "$used_ports" == *" ${port} "* ]]; then
            conflicts+=("$port")
        fi
    done
    if [[ "$used_ports" == *" ${sshport} "* ]]; then
        conflicts+=("$sshport")
    fi

    if [[ "${#conflicts[@]}" -gt 0 ]]; then
        _red "Host port conflict detected: ${conflicts[*]}"
        _yellow "Please choose another sshport or public port range."
        exit 1
    fi
}

# ======== 主逻辑 ========
main() {
    _blue "Creating container: name=${name} cpu=${cpu} memory=${memory}MB system=${system}"
    _blue "SSH port: ${sshport}  port range: ${startport}-${endport}  IPv6: ${independent_ipv6}"

    check_container_name_available
    check_port_conflicts

    # 下载/加载镜像
    download_and_load_image "$system"

    # 网络选项
    local net_args=(--network containerd-net)
    local ipv6_env_args=()
    if [[ "${independent_ipv6,,}" == "y" ]] && [[ "$IPV6_ENABLED" == "true" ]]; then
        net_args=(--network containerd-ipv6)
        ipv6_env_args=(-e IPV6_ENABLED=true)
    fi

    # 存储限制选项
    # nerdctl + containerd btrfs 快照器支持 --storage-opt size=Xg
    local storage_args=()
    local snapshotter_args=()
    if [[ "$disk" -gt 0 ]]; then
        if [ "$btrfs_support" = "Y" ]; then
            snapshotter_args=(--snapshotter btrfs)
            storage_args=(--storage-opt "size=${disk}g")
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
    if ! nerdctl run -d \
        --pull=never \
        --cpus="${cpu}" \
        --memory="${memory}m" \
        --name "${name}" \
        "${net_args[@]}" \
        -p "${sshport}:22" \
        -p "${startport}-${endport}:${startport}-${endport}" \
        --cap-add=MKNOD \
        --restart always \
        "${snapshotter_args[@]}" \
        "${storage_args[@]}" \
        "${lxcfs_volume_args[@]}" \
        "${ipv6_env_args[@]}" \
        -e ROOT_PASSWORD="${passwd}" \
        "${image_name}"; then
        _red "Failed to create container ${name}"
        exit 1
    fi

    _green "Container ${name} created successfully"
    sleep 3

    # ======== 补充防火墙 NAT/FORWARD 规则（防止系统未自动添加） ========
    local fw_backend="iptables"
    if [[ -f /usr/local/bin/containerd_firewall_backend ]]; then
        fw_backend=$(cat /usr/local/bin/containerd_firewall_backend)
    fi

    if [[ "$fw_backend" == "nftables" ]] && command -v nft >/dev/null 2>&1; then
        # 确保 nftables IPv4 表存在
        if ! nft list table ip containerd >/dev/null 2>&1; then
            nft add table ip containerd 2>/dev/null || true
            nft add chain ip containerd postrouting '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null || true
            nft add rule ip containerd postrouting ip saddr 172.20.0.0/16 ip daddr != 172.20.0.0/16 masquerade 2>/dev/null || true
            nft add chain ip containerd forward '{ type filter hook forward priority filter; policy accept; }' 2>/dev/null || true
            nft add rule ip containerd forward ip saddr 172.20.0.0/16 accept 2>/dev/null || true
            nft add rule ip containerd forward ip daddr 172.20.0.0/16 accept 2>/dev/null || true
        fi
        # IPv6 规则（仅当使用 IPv6 网络时）
        if [[ "${independent_ipv6,,}" == "y" ]]; then
            if ! nft list table ip6 containerd >/dev/null 2>&1; then
                nft add table ip6 containerd 2>/dev/null || true
                nft add chain ip6 containerd forward '{ type filter hook forward priority filter; policy accept; }' 2>/dev/null || true
                nft add rule ip6 containerd forward iifname "ctn-br1" accept 2>/dev/null || true
                nft add rule ip6 containerd forward oifname "ctn-br1" accept 2>/dev/null || true
            fi
            if [[ -f /usr/local/bin/containerd_ipv6_subnet ]]; then
                local ipv6_subnet
                ipv6_subnet=$(cat /usr/local/bin/containerd_ipv6_subnet)
                if ! nft list chain ip6 containerd forward 2>/dev/null | grep -q "$ipv6_subnet"; then
                    nft add rule ip6 containerd forward ip6 saddr "$ipv6_subnet" accept 2>/dev/null || true
                    nft add rule ip6 containerd forward ip6 daddr "$ipv6_subnet" accept 2>/dev/null || true
                fi
            fi
        fi
    elif command -v iptables >/dev/null 2>&1; then
        # 回退使用 iptables
        iptables -t nat -C POSTROUTING -s 172.20.0.0/16 ! -d 172.20.0.0/16 -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s 172.20.0.0/16 ! -d 172.20.0.0/16 -j MASQUERADE 2>/dev/null || true
        iptables -C FORWARD -s 172.20.0.0/16 -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -s 172.20.0.0/16 -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -d 172.20.0.0/16 -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -d 172.20.0.0/16 -j ACCEPT 2>/dev/null || true
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
        # 持久化 iptables/ip6tables 规则
        persist_iptables_rules
    fi

    # 下载并执行 SSH 初始化脚本
    download_ssh_scripts "$name" "$system"

    if [[ "$system" == "alpine" ]]; then
        if nerdctl exec "${name}" test -f /ssh_sh.sh 2>/dev/null; then
            nerdctl exec "${name}" sh /ssh_sh.sh "$passwd" 2>/dev/null || true
        else
            # 镜像内置 entrypoint 处理 SSH，无需外部脚本
            _yellow "ssh_sh.sh not found in container, relying on built-in entrypoint"
        fi
        # shellcheck disable=SC2016
        nerdctl exec "${name}" sh -c 'printf "%s:%s\n" root "$1" | chpasswd' _ "$passwd" 2>/dev/null || true
    else
        if nerdctl exec "${name}" test -f /ssh_bash.sh 2>/dev/null; then
            nerdctl exec "${name}" bash /ssh_bash.sh "$passwd" 2>/dev/null || true
        else
            _yellow "ssh_bash.sh not found in container, relying on built-in entrypoint"
        fi
        # shellcheck disable=SC2016
        nerdctl exec "${name}" bash -c 'printf "%s:%s\n" root "$1" | chpasswd' _ "$passwd" 2>/dev/null || true
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
