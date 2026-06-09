#!/bin/bash
# from
# https://github.com/oneclickvirt/containerd
# 2026.06.03

set -euo pipefail

_red() { echo -e "\033[31m\033[01m$*\033[0m"; }
_green() { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$*\033[0m"; }

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

usage() {
    cat <<'EOF'
Usage:
  ./containerd_manage.sh stats [container]
  ./containerd_manage.sh snapshot <container> [image]
  ./containerd_manage.sh backup <container> [output.tar]
  ./containerd_manage.sh version-check [system]

Commands:
  stats          Show one-shot CPU/memory/network/block I/O usage via nerdctl stats
  snapshot       Commit a container to an image
  backup         Export a container filesystem to a tar archive
  version-check  Show local image ID and remote release asset availability
EOF
}

require_nerdctl() {
    if ! command -v nerdctl >/dev/null 2>&1 && [[ ! -x /usr/local/bin/nerdctl ]]; then
        _red "nerdctl not found. Please run containerdinstall.sh first."
        exit 1
    fi
}

valid_container_name() {
    [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_.-]*$ ]]
}

valid_system() {
    [[ "$1" =~ ^(ubuntu|debian|alpine|almalinux|rockylinux|openeuler)$ ]]
}

detect_arch() {
    if [[ -f /usr/local/bin/containerd_arch ]]; then
        cat /usr/local/bin/containerd_arch
        return
    fi
    case "$(uname -m)" in
        x86_64)  printf 'amd64\n' ;;
        aarch64) printf 'arm64\n' ;;
        armv7l)  printf 'arm\n' ;;
        *)       printf 'amd64\n' ;;
    esac
}

default_snapshot_image() {
    local container="$1"
    printf 'containerd-backup/%s:%s\n' "$container" "$(date +%Y%m%d%H%M%S)"
}

default_backup_path() {
    local container="$1"
    printf './%s-backup-%s.tar\n' "$container" "$(date +%Y%m%d%H%M%S)"
}

cmd_stats() {
    local container="${1:-}"
    if [[ -n "$container" ]] && ! valid_container_name "$container"; then
        _red "Invalid container name '${container}'."
        exit 1
    fi
    if [[ -n "$container" ]]; then
        nerdctl stats --no-stream "$container"
    else
        nerdctl stats --no-stream
    fi
}

cmd_snapshot() {
    local container="${1:-}"
    local image="${2:-}"
    if [[ -z "$container" ]] || ! valid_container_name "$container"; then
        _red "Usage: ./containerd_manage.sh snapshot <container> [image]"
        exit 1
    fi
    if [[ -z "$image" ]]; then
        image=$(default_snapshot_image "$container")
    fi
    _yellow "Creating image snapshot: ${image}"
    nerdctl commit "$container" "$image"
    _green "Snapshot created: ${image}"
}

cmd_backup() {
    local container="${1:-}"
    local output="${2:-}"
    if [[ -z "$container" ]] || ! valid_container_name "$container"; then
        _red "Usage: ./containerd_manage.sh backup <container> [output.tar]"
        exit 1
    fi
    if [[ -z "$output" ]]; then
        output=$(default_backup_path "$container")
    fi
    mkdir -p "$(dirname "$output")"
    _yellow "Exporting container filesystem: ${output}"
    nerdctl export -o "$output" "$container"
    _green "Backup exported: ${output}"
}

local_image_lines() {
    local canonical_image="$1"
    local remote_image="$2"
    local lines=""
    lines=$(nerdctl images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.CreatedSince}}' 2>/dev/null \
        | awk -v canonical="$canonical_image" -v remote="$remote_image" '$1 == canonical || $1 == remote {print}' || true)
    if [[ -z "$lines" ]]; then
        lines=$(nerdctl images 2>/dev/null \
            | awk -v canonical_repo="${canonical_image%:*}" -v remote_repo="${remote_image%:*}" '
                $1 == canonical_repo || $1 == remote_repo {print}
            ' || true)
    fi
    printf '%s\n' "$lines"
}

release_asset_updated_at() {
    local api_body="$1"
    local asset_name="$2"
    printf '%s\n' "$api_body" | awk -v asset="$asset_name" '
        $0 ~ "\"name\": \"" asset "\"" {found=1}
        found && /"updated_at":/ {
            gsub(/[",]/, "", $2)
            print $2
            exit
        }
    '
}

cmd_version_check() {
    local system="${1:-debian}"
    system=$(printf '%s' "$system" | tr '[:upper:]' '[:lower:]')
    if ! valid_system "$system"; then
        _red "Unsupported system '${system}'."
        exit 1
    fi

    local arch
    arch=$(detect_arch)
    local canonical_image="spiritlhl/${system}:latest"
    local image_registry="${CONTAINERD_IMAGE_REGISTRY:-ghcr.io/oneclickvirt/containerd}"
    local remote_image="${image_registry}:${system}"
    local arch_image="${image_registry}:${system}-${arch}"
    local legacy_image="ghcr.io/oneclickvirt/${system}:latest"
    local release_base="${CONTAINERD_IMAGE_RELEASE_BASE:-https://github.com/oneclickvirt/containerd/releases/download}"
    local tar_filename="spiritlhl_${system}_${arch}.tar.gz"
    local release_url="${release_base%/}/${system}/${tar_filename}"

    _blue "System: ${system}  arch: ${arch}"
    _blue "Preferred image: ${remote_image}"
    _blue "Compatible image tags: ${arch_image}, ${legacy_image}"
    _blue "Canonical local image: ${canonical_image}"

    if command -v nerdctl >/dev/null 2>&1 || [[ -x /usr/local/bin/nerdctl ]]; then
        local local_lines
        local_lines=$(local_image_lines "$canonical_image" "$remote_image")
        if [[ -z "$local_lines" ]]; then
            local_lines=$(local_image_lines "$arch_image" "$legacy_image")
        fi
        if [[ -n "$local_lines" ]]; then
            _green "Local image found:"
            printf '%s\n' "$local_lines"
        else
            _yellow "Local image not found."
        fi
    else
        _yellow "nerdctl not found; skipped local image check."
    fi

    if ! command -v curl >/dev/null 2>&1; then
        _yellow "curl not found; skipped remote release check."
        return 0
    fi

    local api_url="https://api.github.com/repos/oneclickvirt/containerd/releases/tags/${system}"
    local api_body=""
    api_body=$(curl -fsSL --connect-timeout 10 --max-time 30 "$api_url" 2>/dev/null || true)
    if [[ -n "$api_body" ]] && printf '%s\n' "$api_body" | grep -q "\"name\": \"${tar_filename}\""; then
        local updated_at
        updated_at=$(release_asset_updated_at "$api_body" "$tar_filename")
        if [[ -n "$updated_at" ]]; then
            _green "Remote release asset exists: ${tar_filename} (updated_at: ${updated_at})"
        else
            _green "Remote release asset exists: ${tar_filename}"
        fi
    elif curl -fsIL --connect-timeout 10 --max-time 30 "$release_url" >/dev/null 2>&1; then
        _green "Remote release asset exists: ${release_url}"
    else
        _yellow "Remote release asset was not reachable: ${release_url}"
    fi
}

main() {
    local command="${1:-}"
    shift || true
    case "$command" in
        stats)
            require_nerdctl
            cmd_stats "$@"
            ;;
        snapshot)
            require_nerdctl
            cmd_snapshot "$@"
            ;;
        backup)
            require_nerdctl
            cmd_backup "$@"
            ;;
        version-check)
            cmd_version_check "$@"
            ;;
        -h|--help|"") usage ;;
        *)
            _red "Unknown command: ${command}"
            usage
            exit 1
            ;;
    esac
}

main "$@"
