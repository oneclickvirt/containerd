#!/bin/bash
# from
# https://github.com/oneclickvirt/containerd
# 2026.08.30

# 批量开设 containerd 容器脚本
# 交互式或无交互创建多个 Linux 容器，记录到 ctlog 日志文件
#
# Supported environment variables (non-interactive mode / 支持的无交互变量):
#   noninteractive=true              - Use defaults for prompts / 使用默认值跳过交互提示
#   CONTAINERD_CREATE_COUNT=1        - Number of containers to create / 新增容器数量
#   CONTAINERD_CONTAINER_MEMORY=512  - Memory per container in MB / 单容器内存 MB
#   CONTAINERD_CONTAINER_CPU=1       - CPU cores per container / 单容器 CPU
#   CONTAINERD_CONTAINER_DISK=0      - Disk limit in GB, btrfs only / 单容器磁盘限制 GB
#   CONTAINERD_CONTAINER_SYSTEM=debian - Container system / 容器系统
#   CONTAINERD_CONTAINER_IPV6=n      - Assign independent IPv6 if available / 可用时分配独立 IPv6

set -uo pipefail

_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }
is_truthy() {
    case "${1:-}" in
        [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Yy]) return 0 ;;
        *) return 1 ;;
    esac
}
is_noninteractive() {
    is_truthy "${noninteractive:-${NONINTERACTIVE:-}}"
}
reading() {
    is_noninteractive && return 1
    read -rp "$(_green "$1")" "$2"
}
is_yes() {
    is_truthy "$1"
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
export DEBIAN_FRONTEND=noninteractive
if [[ "${ONECLICKVIRT_TESTING:-}" != "1" ]]; then
    export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
fi
SCRIPT_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_CREATE_COUNT=1
DEFAULT_CONTAINER_MEMORY=512
DEFAULT_CONTAINER_CPU=1
DEFAULT_CONTAINER_DISK=0
DEFAULT_CONTAINER_SYSTEM="debian"
DEFAULT_CONTAINER_IPV6="n"

usage() {
    cat <<'EOF'
Usage:
  ./create_containerd.sh [options]

Options:
  --noninteractive             Use defaults for omitted options
  -n, --count NUM              Number of containers to create
  --memory MB                  Memory per container in MB
  --cpu CPU                    CPU cores per container, e.g. 1 or 0.5
  --disk GB                    Disk limit in GB, btrfs only, 0=unlimited
  --system NAME                ubuntu/debian/alpine/almalinux/rockylinux/openeuler or supported version alias
  --ipv6 y|n                   Assign independent IPv6 if available
  -h, --help                   Show this help
EOF
}

require_option_value() {
    local opt="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == -* ]]; then
        _red "Missing value for ${opt}"
        usage
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --noninteractive)
                export noninteractive=true
                shift
                ;;
            -n|--count)
                require_option_value "$1" "${2:-}"
                CONTAINERD_CREATE_COUNT="$2"
                shift 2
                ;;
            --memory)
                require_option_value "$1" "${2:-}"
                CONTAINERD_CONTAINER_MEMORY="$2"
                shift 2
                ;;
            --cpu)
                require_option_value "$1" "${2:-}"
                CONTAINERD_CONTAINER_CPU="$2"
                shift 2
                ;;
            --disk)
                require_option_value "$1" "${2:-}"
                CONTAINERD_CONTAINER_DISK="$2"
                shift 2
                ;;
            --system)
                require_option_value "$1" "${2:-}"
                CONTAINERD_CONTAINER_SYSTEM="$2"
                shift 2
                ;;
            --ipv6)
                require_option_value "$1" "${2:-}"
                CONTAINERD_CONTAINER_IPV6="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                _red "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

generate_password() {
    local password=""
    if command -v openssl >/dev/null 2>&1; then
        password=$(openssl rand -hex 16 2>/dev/null || true)
    fi
    if [[ -z "$password" ]] && [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
        password=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    fi
    if [[ -z "$password" ]]; then
        password=$(printf '%s%s%s' "$(date +%s%N)" "$RANDOM" "$container_num" | md5sum 2>/dev/null | awk '{print substr($1,1,32)}')
    fi
    if [[ -z "$password" ]]; then
        password="${RANDOM}${RANDOM}${RANDOM}${RANDOM}"
    fi
    printf '%s\n' "${password:0:32}"
}

if [[ "${ONECLICKVIRT_TESTING:-}" != "1" ]]; then
    parse_args "$@"

    if [ "$(id -u)" != "0" ]; then
        _red "This script must be run as root" 1>&2
        exit 1
    fi

    # ======== 切换到 /root ========
    cd /root || exit 1
fi

# ======== 检查依赖 ========
pre_check() {
    if [[ "${ONECLICKVIRT_TESTING:-}" == "1" ]]; then
        command -v nerdctl >/dev/null 2>&1 || return 1
        [[ -s "${SCRIPT_SOURCE_DIR}/onecontainerd.sh" ]] || return 1
        [[ -s "${SCRIPT_SOURCE_DIR}/validate_image_archive.py" ]] || return 1
        return 0
    fi
    if ! command -v nerdctl >/dev/null 2>&1 && [[ ! -x /usr/local/bin/nerdctl ]]; then
        _yellow "nerdctl not found, running containerdinstall.sh..."
        if [[ -f /root/containerdinstall.sh ]]; then
            bash /root/containerdinstall.sh || return 1
        else
            bash <(curl -fsSL --connect-timeout 10 --max-time 60 "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/containerd/main/containerdinstall.sh") || return 1
        fi
    fi

    # 优先使用当前仓库中的脚本，避免本地改动调试时落回远端旧版本。
    if [[ -f "${SCRIPT_SOURCE_DIR}/onecontainerd.sh" ]]; then
        mkdir -p /root/scripts || return 1
        cp "${SCRIPT_SOURCE_DIR}/onecontainerd.sh" /root/scripts/onecontainerd.sh || return 1
        for helper_script in ssh_bash.sh ssh_sh.sh validate_image_archive.py; do
            if [[ -f "${SCRIPT_SOURCE_DIR}/${helper_script}" ]]; then
                cp "${SCRIPT_SOURCE_DIR}/${helper_script}" "/root/scripts/${helper_script}" || return 1
                chmod +x "/root/scripts/${helper_script}" || return 1
            fi
        done
        chmod +x /root/scripts/onecontainerd.sh || return 1
    elif [[ ! -f /root/scripts/onecontainerd.sh ]]; then
        curl -fsSL --connect-timeout 10 --max-time 60 \
            "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/containerd/main/scripts/onecontainerd.sh" \
            -o /root/scripts/onecontainerd.sh || return 1
        if [[ ! -s /root/scripts/onecontainerd.sh ]]; then
            _red "Failed to download onecontainerd.sh"
            exit 1
        fi
        chmod +x /root/scripts/onecontainerd.sh || return 1
    fi
    # onecontainerd validates downloaded image archives before loading them.
    # Keep the validator beside the installed launcher so an old working
    # launcher can never silently fall back to the unsafe inline implementation.
    if [[ ! -s /root/scripts/validate_image_archive.py ]]; then
        curl -fsSL --connect-timeout 10 --max-time 60 \
            "${cdn_success_url}https://raw.githubusercontent.com/oneclickvirt/containerd/main/scripts/validate_image_archive.py" \
            -o /root/scripts/validate_image_archive.py || return 1
        if [[ ! -s /root/scripts/validate_image_archive.py ]]; then
            _red "Failed to install validate_image_archive.py"
            exit 1
        fi
        chmod +x /root/scripts/validate_image_archive.py || return 1
    fi
}

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

if [[ "${ONECLICKVIRT_TESTING:-}" != "1" ]]; then
    check_cdn_file
fi

# ======== 读取日志，恢复编号状态 ========
log_file="ctlog"
container_prefix="ct"
container_num=0
ssh_port=25000
public_port_end=34975

check_log() {
    if [[ -f "$log_file" ]]; then
        local last_line
        last_line=$(tail -n 1 "$log_file" 2>/dev/null || true)
        if [[ -n "$last_line" ]]; then
            # 格式: <name> <sshport> <password> <cpu> <memory> <startport> <endport> <disk>
            local last_name last_ssh last_endport
            read -r last_name last_ssh _ _ _ _ last_endport _ <<< "$last_line"

            # 解析容器名前缀和编号（如 ct1 → prefix=ct, num=1）
            if [[ "$last_name" =~ ^([a-zA-Z]+)([0-9]+)$ ]]; then
                container_prefix="${BASH_REMATCH[1]}"
                container_num="${BASH_REMATCH[2]}"
            fi
            [[ "$last_ssh" =~ ^[0-9]+$ && "$last_ssh" -gt 0 ]] && ssh_port="$last_ssh"
            [[ "$last_endport" =~ ^[0-9]+$ && "$last_endport" -gt 0 ]] && public_port_end="$last_endport"

            _blue "Resuming from: prefix=${container_prefix}, num=${container_num}, last_ssh=${ssh_port}, last_endport=${public_port_end}"
        fi
    fi
}

# ======== 交互式创建 ========
build_new_containers() {
    # 询问容器数量
    if [[ -n "${CONTAINERD_CREATE_COUNT:-}" ]]; then
        new_nums="${CONTAINERD_CREATE_COUNT}"
        _blue "[non-interactive] CONTAINERD_CREATE_COUNT=${CONTAINERD_CREATE_COUNT}"
    elif is_noninteractive; then
        new_nums="$DEFAULT_CREATE_COUNT"
        _blue "[non-interactive] noninteractive=true, CONTAINERD_CREATE_COUNT defaulting to ${new_nums}"
    else
        reading "需要新增几个容器？ (How many containers to create?) [default: ${DEFAULT_CREATE_COUNT}]: " new_nums
    fi
    if [[ -z "$new_nums" ]] || ! valid_positive_integer "$new_nums"; then
        _yellow "Invalid container count '${new_nums}', using ${DEFAULT_CREATE_COUNT}"
        new_nums="$DEFAULT_CREATE_COUNT"
    fi

    # 询问内存大小
    if [[ -n "${CONTAINERD_CONTAINER_MEMORY:-}" ]]; then
        memory_nums="${CONTAINERD_CONTAINER_MEMORY}"
        _blue "[non-interactive] CONTAINERD_CONTAINER_MEMORY=${CONTAINERD_CONTAINER_MEMORY}"
    elif is_noninteractive; then
        memory_nums="$DEFAULT_CONTAINER_MEMORY"
        _blue "[non-interactive] noninteractive=true, CONTAINERD_CONTAINER_MEMORY defaulting to ${memory_nums}"
    else
        reading "每个容器内存大小(MB) (Memory per container in MB) [default: ${DEFAULT_CONTAINER_MEMORY}]: " memory_nums
    fi
    if [[ -z "$memory_nums" ]] || ! valid_positive_integer "$memory_nums"; then
        _yellow "Invalid memory '${memory_nums}', using ${DEFAULT_CONTAINER_MEMORY}MB"
        memory_nums="$DEFAULT_CONTAINER_MEMORY"
    fi

    # 询问 CPU
    if [[ -n "${CONTAINERD_CONTAINER_CPU:-}" ]]; then
        cpu_nums="${CONTAINERD_CONTAINER_CPU}"
        _blue "[non-interactive] CONTAINERD_CONTAINER_CPU=${CONTAINERD_CONTAINER_CPU}"
    elif is_noninteractive; then
        cpu_nums="$DEFAULT_CONTAINER_CPU"
        _blue "[non-interactive] noninteractive=true, CONTAINERD_CONTAINER_CPU defaulting to ${cpu_nums}"
    else
        reading "每个容器 CPU 核数 (CPU cores per container, e.g. 1 or 0.5) [default: ${DEFAULT_CONTAINER_CPU}]: " cpu_nums
    fi
    if [[ -z "$cpu_nums" ]] || ! valid_cpu_value "$cpu_nums"; then
        _yellow "Invalid CPU value '${cpu_nums}', using ${DEFAULT_CONTAINER_CPU}"
        cpu_nums="$DEFAULT_CONTAINER_CPU"
    fi

    # 检查存储驱动是否支持硬盘限制（仅 btrfs 支持）
    disk_size=0
    storage_driver="overlayfs"
    if [ -f /usr/local/bin/containerd_storage_driver ]; then
        storage_driver=$(cat /usr/local/bin/containerd_storage_driver)
    fi
    if [ "$storage_driver" = "btrfs" ]; then
        if [[ -n "${CONTAINERD_CONTAINER_DISK:-}" ]]; then
            disk_size="${CONTAINERD_CONTAINER_DISK}"
            _blue "[non-interactive] CONTAINERD_CONTAINER_DISK=${CONTAINERD_CONTAINER_DISK}"
        elif is_noninteractive; then
            disk_size="$DEFAULT_CONTAINER_DISK"
            _blue "[non-interactive] noninteractive=true, CONTAINERD_CONTAINER_DISK defaulting to ${disk_size}"
        else
            reading "磁盘限制(GB) (Disk limit in GB, 0=unlimited) [default: ${DEFAULT_CONTAINER_DISK}]: " disk_size
        fi
        if [[ -z "$disk_size" ]] || ! valid_nonnegative_integer "$disk_size"; then
            _yellow "Invalid disk limit '${disk_size}', using ${DEFAULT_CONTAINER_DISK}"
            disk_size="$DEFAULT_CONTAINER_DISK"
        fi
    else
        _yellow "当前快照器（${storage_driver}）不支持硬盘大小限制，磁盘参数设为0"
        _yellow "Current snapshotter ($storage_driver) does not support disk size limitation, setting disk to 0"
        disk_size=0
    fi

    # 询问系统
    _blue "可选系统: ubuntu / debian / alpine / almalinux / rockylinux / openeuler"
    _blue "可选版本别名: ubuntu22.04 / debian12 / alpine/latest / almalinux9 / rockylinux9 / openeuler22.03"
    if [[ -n "${CONTAINERD_CONTAINER_SYSTEM:-}" ]]; then
        system_type="${CONTAINERD_CONTAINER_SYSTEM}"
        _blue "[non-interactive] CONTAINERD_CONTAINER_SYSTEM=${CONTAINERD_CONTAINER_SYSTEM}"
    elif is_noninteractive; then
        system_type="$DEFAULT_CONTAINER_SYSTEM"
        _blue "[non-interactive] noninteractive=true, CONTAINERD_CONTAINER_SYSTEM defaulting to ${system_type}"
    else
        reading "选择系统 (Choose system) [default: ${DEFAULT_CONTAINER_SYSTEM}]: " system_type
    fi
    [[ -z "$system_type" ]] && system_type="$DEFAULT_CONTAINER_SYSTEM"
    local requested_system_type="$system_type"
    local normalized_system_type
    if ! normalized_system_type=$(normalize_container_system "$requested_system_type"); then
        _red "Unsupported container system '${requested_system_type}'."
        print_supported_container_systems
        return 1
    fi
    if [[ "$(printf '%s' "$requested_system_type" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" != "$normalized_system_type" ]]; then
        _blue "Normalized container system '${requested_system_type}' to '${normalized_system_type}'"
    fi
    system_type="$normalized_system_type"

    # 询问是否附加独立 IPv6
    IPV6_AVAILABLE=false
    if [[ -f /usr/local/bin/containerd_ipv6_enabled ]]; then
        if [[ "$(cat /usr/local/bin/containerd_ipv6_enabled)" == "true" ]]; then
            IPV6_AVAILABLE=true
        fi
    fi
    independent_ipv6="n"
    if [[ "$IPV6_AVAILABLE" == "true" ]]; then
        if [[ -n "${CONTAINERD_CONTAINER_IPV6:-}" ]]; then
            ipv6_choice="${CONTAINERD_CONTAINER_IPV6}"
            _blue "[non-interactive] CONTAINERD_CONTAINER_IPV6=${CONTAINERD_CONTAINER_IPV6}"
        elif is_noninteractive; then
            ipv6_choice="$DEFAULT_CONTAINER_IPV6"
            _blue "[non-interactive] noninteractive=true, CONTAINERD_CONTAINER_IPV6 defaulting to ${ipv6_choice}"
        else
            reading "是否为每个容器分配独立 IPv6？ (Assign independent IPv6 to each container?) [y/N]: " ipv6_choice
        fi
        is_yes "$ipv6_choice" && independent_ipv6="y"
    elif [[ -n "${CONTAINERD_CONTAINER_IPV6:-}" ]] && is_yes "${CONTAINERD_CONTAINER_IPV6}"; then
        _yellow "CONTAINERD_CONTAINER_IPV6 requested, but containerd IPv6 network is unavailable; using n"
    fi

    local disk_limit_info="无限制 (overlayfs)"
    if [ "$storage_driver" = "btrfs" ] && [ "$disk_size" -gt 0 ] 2>/dev/null; then
        disk_limit_info="${disk_size}GB (btrfs)"
    fi

    _blue "======================================================"
    _blue "  即将创建 $new_nums 个容器"
    _blue "  系统: $system_type  内存: ${memory_nums}MB  CPU: ${cpu_nums}  磁盘: ${disk_limit_info}"
    _blue "  IPv6: $independent_ipv6"
    _blue "======================================================"

    local scripts_dir
    if [[ "${ONECLICKVIRT_TESTING:-}" == "1" ]]; then
        scripts_dir="$SCRIPT_SOURCE_DIR"
    elif [[ -f /root/scripts/onecontainerd.sh ]]; then
        scripts_dir="/root/scripts"
    elif [[ -f "$(dirname "$0")/onecontainerd.sh" ]]; then
        scripts_dir="$(dirname "$0")"
    else
        scripts_dir="/root"
    fi

    local pending_log
    pending_log=$(mktemp "${log_file}.pending.XXXXXX") || {
        _red "Unable to create a temporary container log"
        return 1
    }
    local commit_log=""
    local created_names=()
    local batch_active=true
    cleanup_batch() {
        local index cname
        for ((index = ${#created_names[@]} - 1; index >= 0; index--)); do
            cname="${created_names[index]}"
            nerdctl rm -f "$cname" >/dev/null 2>&1 || true
        done
        rm -f -- "$pending_log"
        [[ -z "$commit_log" ]] || rm -f -- "$commit_log"
        batch_active=false
    }
    cleanup_batch_on_exit() {
        local status=$?
        if [[ "$batch_active" == true ]]; then
            cleanup_batch
        fi
        return "$status"
    }
    abort_batch() {
        cleanup_batch
        if [[ "${ONECLICKVIRT_TESTING:-}" != "1" ]]; then
            trap - EXIT INT TERM
        fi
        return 1
    }
    if [[ "${ONECLICKVIRT_TESTING:-}" != "1" ]]; then
        trap cleanup_batch_on_exit EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
    fi

    for ((i = 1; i <= new_nums; i++)); do
        container_num=$((container_num + 1))
        container_name="${container_prefix}${container_num}"
        ssh_port=$((ssh_port + 1))
        public_port_start=$((public_port_end + 1))
        public_port_end=$((public_port_start + 24))

        # 生成高熵随机密码，保持十六进制字符以便安全传参和记录。
        passwd=$(generate_password)

        _yellow "[${i}/${new_nums}] Creating container: ${container_name}  ssh:${ssh_port}  ports:${public_port_start}-${public_port_end}"

        if nerdctl ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$container_name"; then
            _red "Container ${container_name} already exists; the existing container and record were not changed"
            abort_batch
            return 1
        fi
        created_names+=("$container_name")
        rm -f -- "/root/${container_name}" "${container_name}"
        if ! bash "${scripts_dir}/onecontainerd.sh" \
            "$container_name" \
            "$cpu_nums" \
            "$memory_nums" \
            "$passwd" \
            "$ssh_port" \
            "$public_port_start" \
            "$public_port_end" \
            "$independent_ipv6" \
            "$system_type" \
            "$disk_size"; then
            _red "Container ${container_name} creation failed; stopping the batch"
            abort_batch
            return 1
        fi

        # onecontainerd must produce the record only after every required
        # setup step succeeds. Never synthesize a success record after a
        # failed or partial invocation.
        local record_path=""
        if [[ -f "/root/${container_name}" ]]; then
            record_path="/root/${container_name}"
        elif [[ -f "${container_name}" ]]; then
            record_path="${container_name}"
        fi
        if [[ -z "$record_path" ]] || [[ ! -s "$record_path" ]] || \
           ! awk -v expected="$container_name" 'NF >= 8 && $1 == expected { found = 1 } END { exit(found ? 0 : 1) }' "$record_path"; then
            _red "Container ${container_name} did not produce a valid success record"
            abort_batch
            return 1
        fi
        if ! cat "$record_path" >> "$pending_log"; then
            _red "Unable to stage the record for ${container_name}"
            abort_batch
            return 1
        fi
        rm -f -- "$record_path"

        _green "Container ${container_name} created and logged"
    done

    commit_log=$(mktemp "${log_file}.commit.XXXXXX") || {
        _red "Unable to create the container log commit file"
        abort_batch
        return 1
    }
    if [[ -f "$log_file" ]] && ! cat "$log_file" >"$commit_log"; then
        _red "Unable to read the existing container log; rolling back this batch"
        abort_batch
        return 1
    fi
    if [[ ! -s "$pending_log" ]] || ! cat "$pending_log" >>"$commit_log" || \
       ! mv -f -- "$commit_log" "$log_file"; then
        _red "Unable to commit the container log; rolling back this batch"
        abort_batch
        return 1
    fi
    commit_log=""
    rm -f -- "$pending_log"
    batch_active=false
    if [[ "${ONECLICKVIRT_TESTING:-}" != "1" ]]; then
        trap - EXIT INT TERM
    fi

    echo
    _green "======================================================"
    _green "  批量创建完成！所有容器信息已保存到: ${log_file}"
    _green "======================================================"
    echo
    _blue "查看所有容器: nerdctl ps -a"
    _blue "查看日志文件: cat ${log_file}"
}

# ======== 显示已有日志 ========
show_log() {
    if [[ -f "$log_file" ]]; then
        _blue "======================================================"
        _blue "  已有容器记录 / Existing container log:"
        _blue "======================================================"
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            local n sshp pw cp mem sp ep dk
            read -r n sshp pw cp mem sp ep dk _ <<< "$line"
            _blue "  名称:${n}  SSH端口:${sshp}  密码:${pw}  CPU:${cp}  内存:${mem}MB  端口:${sp}-${ep}  磁盘:${dk}GB"
        done < "$log_file"
        echo
    fi
}

# ======== 主流程 ========
main() {
    pre_check || return 1
    check_log
    show_log
    build_new_containers || return 1
    check_log
}

if [[ "${ONECLICKVIRT_TESTING:-}" != "1" ]]; then
    main "$@"
fi
