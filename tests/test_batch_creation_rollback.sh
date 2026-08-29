#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/containerd-batch-rollback.XXXXXX")
cleanup_test() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        find "$tmpdir" -type f -name output -exec sh -c 'for file do printf "%s\n" "--- $file ---" >&2; sed -n "1,240p" "$file" >&2; done' sh {} + || true
    fi
    rm -rf -- "$tmpdir"
    return "$status"
}
trap cleanup_test EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

export ONECLICKVIRT_TESTING=1
# shellcheck disable=SC1090
source "$repo_root/scripts/create_containerd.sh"

mock_state_dir=""
mock_fail_on=0
mock_calls=0

nerdctl() {
    local command_name="${1:-}"
    shift || true
    case "$command_name" in
    ps)
        local marker
        for marker in "$mock_state_dir"/*.exists; do
            [ -e "$marker" ] || continue
            basename "$marker" .exists
        done
        ;;
    rm)
        local container_name="${*: -1}"
        rm -f -- "$mock_state_dir/${container_name}.exists"
        ;;
    *)
        return 0
        ;;
    esac
}

bash() {
    local container_name="${2:-}"
    local cpu="${3:-}"
    local memory="${4:-}"
    local password="${5:-}"
    local ssh_port_arg="${6:-}"
    local start_port="${7:-}"
    local end_port="${8:-}"
    local disk="${11:-0}"
    mock_calls=$((mock_calls + 1))
    : >"$mock_state_dir/${container_name}.exists"
    if [ "$mock_calls" -eq "$mock_fail_on" ]; then
        return 42
    fi
    printf '%s\n' "$container_name $ssh_port_arg $password $cpu $memory $start_port $end_port $disk" >"$container_name"
}

generate_password() {
    printf 'test-password\n'
}

reset_case() {
    local case_name="$1"
    mkdir -p "$tmpdir/$case_name/state"
    cd "$tmpdir/$case_name"
    mock_state_dir="$PWD/state"
    mock_fail_on=0
    mock_calls=0
    log_file="ctlog"
    container_prefix="ct"
    container_num=0
    ssh_port=25000
    public_port_end=34975
    noninteractive=true
    CONTAINERD_CREATE_COUNT=2
    CONTAINERD_CONTAINER_MEMORY=64
    CONTAINERD_CONTAINER_CPU=1
    CONTAINERD_CONTAINER_DISK=0
    CONTAINERD_CONTAINER_SYSTEM=debian
    CONTAINERD_CONTAINER_IPV6=n
}

reset_case second-item-failure
old_log='legacy0 24999 old-password 1 64 34951 34975 0'
printf '%s\n' "$old_log" >ctlog
mock_fail_on=2
set +e
build_new_containers >output 2>&1
batch_status=$?
set -e
if [ "$batch_status" -eq 0 ]; then
    fail 'batch succeeded after the second child creator failed'
fi
[ "$mock_calls" -eq 2 ] || fail "unexpected child invocation count after failure: $mock_calls"
[ "$(cat ctlog)" = "$old_log" ] || fail 'failed batch changed the existing log'
[ ! -e state/ct1.exists ] || fail 'failed batch left the first new container behind'
[ ! -e state/ct2.exists ] || fail 'failed batch left the partial second container behind'
[ ! -e ct1 ] && [ ! -e ct2 ] || fail 'failed batch left per-container records behind'

reset_case success
printf '%s\n' "$old_log" >ctlog
build_new_containers >output 2>&1 || fail 'successful batch was reported as failed'
[ "$(sed -n '1p' ctlog)" = "$old_log" ] || fail 'successful batch did not preserve the existing log'
[ "$(wc -l <ctlog | tr -d ' ')" -eq 3 ] || fail 'successful batch did not atomically append both records'
[ -e state/ct1.exists ] && [ -e state/ct2.exists ] || fail 'successful batch removed a new container'

reset_case preexisting
CONTAINERD_CREATE_COUNT=1
printf '%s\n' "$old_log" >ctlog
printf '%s\n' 'ct1 25001 existing-password 1 64 34976 35000 0' >ct1
: >state/ct1.exists
set +e
build_new_containers >output 2>&1
batch_status=$?
set -e
if [ "$batch_status" -eq 0 ]; then
    fail 'batch accepted a pre-existing container name'
fi
[ "$mock_calls" -eq 0 ] || fail 'child creator ran for a pre-existing container'
[ -e state/ct1.exists ] || fail 'pre-existing container was deleted'
grep -Fxq 'ct1 25001 existing-password 1 64 34976 35000 0' ct1 || fail 'pre-existing record was changed'
[ "$(cat ctlog)" = "$old_log" ] || fail 'pre-existing-name failure changed the log'

printf 'Containerd batch creation rollback tests passed\n'
