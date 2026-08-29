#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/containerd-create-rollback.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

mock_bin="$tmpdir/bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/nerdctl" <<'MOCK'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$MOCK_NERDCTL_LOG"
case "${1:-}" in
image)
    [ "${2:-}" = inspect ] && exit 0
    ;;
ps)
    if [[ "$*" == *'{{.Names}}'* && -e "$MOCK_CONTAINER_MARKER" ]]; then
        printf '%s\n' "$MOCK_CONTAINER_NAME"
    fi
    exit 0
    ;;
run)
    : >"$MOCK_CONTAINER_MARKER"
    if [[ "${MOCK_FAIL_STAGE:-}" == run ]]; then
        exit 41
    fi
    printf '%s\n' fake-container-id
    exit 0
    ;;
cp)
    [[ "${MOCK_FAIL_STAGE:-}" == ssh-copy ]] && exit 42
    exit 0
    ;;
exec)
    if [[ "$*" == *'test -f /ssh_bash.sh'* || "$*" == *'test -f /ssh_sh.sh'* ]]; then
        [[ "${MOCK_FAIL_STAGE:-}" == built-in ]] && exit 1
        exit 0
    fi
    if [[ "${MOCK_FAIL_STAGE:-}" == ssh-script && ( "$*" == *'/ssh_bash.sh'* || "$*" == *'/ssh_sh.sh'* ) ]]; then
        exit 43
    fi
    if [[ "${MOCK_FAIL_STAGE:-}" == chpasswd && "$*" == *chpasswd* ]]; then
        exit 44
    fi
    if [[ "${MOCK_FAIL_STAGE:-}" == sshd && "$*" == *'command -v sshd'* ]]; then
        exit 45
    fi
    exit 0
    ;;
rm)
    rm -f -- "$MOCK_CONTAINER_MARKER"
    exit 0
    ;;
esac
exit 0
MOCK
chmod +x "$mock_bin/nerdctl"

run_case() {
    local stage="$1"
    local case_dir="$tmpdir/$stage"
    local name="ct-${stage}"
    mkdir -p "$case_dir"
    : >"$case_dir/nerdctl.log"

    if (
        cd "$case_dir"
        export ONECLICKVIRT_TESTING=1
        export CONTAINERD_TEST_HOST_SYSTEM=Debian
        export CONTAINERD_TEST_IPV4=192.0.2.1
        export WITHOUTCDN=TRUE
        export MOCK_FAIL_STAGE="$stage"
        export MOCK_CONTAINER_NAME="$name"
        export MOCK_CONTAINER_MARKER="$case_dir/container.exists"
        export MOCK_NERDCTL_LOG="$case_dir/nerdctl.log"
        export PATH="$mock_bin:$PATH"
        bash "$repo_root/scripts/onecontainerd.sh" \
            "$name" 1 64 test-password 25101 35101 35102 n debian 0 \
            >"$case_dir/output" 2>&1
    ); then
        fail "onecontainerd succeeded when ${stage} failed"
    fi

    [ ! -e "$case_dir/container.exists" ] || fail "${stage}: partial container was not removed"
    [ ! -e "$case_dir/$name" ] || fail "${stage}: success record was written"
    grep -Fxq "rm -f $name" "$case_dir/nerdctl.log" || fail "${stage}: nerdctl rm was not called"
}

for stage in run ssh-copy ssh-script chpasswd sshd; do
    run_case "$stage"
done

cat >"$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
exit 22
MOCK
chmod +x "$mock_bin/curl"

success_dir="$tmpdir/success"
success_name=ct-success
mkdir -p "$success_dir"
: >"$success_dir/nerdctl.log"
(
    cd "$success_dir"
    export ONECLICKVIRT_TESTING=1
    export CONTAINERD_TEST_HOST_SYSTEM=Debian
    export CONTAINERD_TEST_IPV4=192.0.2.1
    export WITHOUTCDN=TRUE
    export MOCK_FAIL_STAGE=""
    export MOCK_CONTAINER_NAME="$success_name"
    export MOCK_CONTAINER_MARKER="$success_dir/container.exists"
    export MOCK_NERDCTL_LOG="$success_dir/nerdctl.log"
    export PATH="$mock_bin:$PATH"
    bash "$repo_root/scripts/onecontainerd.sh" \
        "$success_name" 1 64 test-password 25102 35103 35104 n debian 0 \
        >"$success_dir/output" 2>&1
)
[ -e "$success_dir/container.exists" ] || fail "successful container was removed"
[ -s "$success_dir/$success_name" ] || fail "successful creation did not write a record"
if grep -Fxq "rm -f $success_name" "$success_dir/nerdctl.log"; then
    fail "successful container was rolled back"
fi

builtin_dir="$tmpdir/built-in"
builtin_name=ct-built-in
mkdir -p "$builtin_dir/empty-scripts"
: >"$builtin_dir/nerdctl.log"
(
    cd "$builtin_dir"
    export ONECLICKVIRT_TESTING=1
    export CONTAINERD_TEST_HOST_SYSTEM=Debian
    export CONTAINERD_TEST_IPV4=192.0.2.1
    export CONTAINERD_SSH_SCRIPT_DIR="$builtin_dir/empty-scripts"
    export WITHOUTCDN=TRUE
    export MOCK_FAIL_STAGE=built-in
    export MOCK_CONTAINER_NAME="$builtin_name"
    export MOCK_CONTAINER_MARKER="$builtin_dir/container.exists"
    export MOCK_NERDCTL_LOG="$builtin_dir/nerdctl.log"
    export PATH="$mock_bin:$PATH"
    bash "$repo_root/scripts/onecontainerd.sh" \
        "$builtin_name" 1 64 test-password 25104 35107 35108 n debian 1 \
        >"$builtin_dir/output" 2>&1
)
[ -e "$builtin_dir/container.exists" ] || fail 'built-in SSH fallback removed a working container'
[ -s "$builtin_dir/$builtin_name" ] || fail 'built-in SSH fallback did not write a success record'
if grep -Fxq "rm -f $builtin_name" "$builtin_dir/nerdctl.log"; then
    fail 'built-in SSH fallback rolled back a working container'
fi

preexisting_dir="$tmpdir/preexisting"
preexisting_name=ct-existing
mkdir -p "$preexisting_dir"
: >"$preexisting_dir/container.exists"
printf '%s\n' 'existing record must survive' >"$preexisting_dir/$preexisting_name"
: >"$preexisting_dir/nerdctl.log"
if (
    cd "$preexisting_dir"
    export ONECLICKVIRT_TESTING=1
    export CONTAINERD_TEST_HOST_SYSTEM=Debian
    export CONTAINERD_TEST_IPV4=192.0.2.1
    export WITHOUTCDN=TRUE
    export MOCK_FAIL_STAGE=""
    export MOCK_CONTAINER_NAME="$preexisting_name"
    export MOCK_CONTAINER_MARKER="$preexisting_dir/container.exists"
    export MOCK_NERDCTL_LOG="$preexisting_dir/nerdctl.log"
    export PATH="$mock_bin:$PATH"
    bash "$repo_root/scripts/onecontainerd.sh" \
        "$preexisting_name" 1 64 test-password 25103 35105 35106 n debian 0 \
        >"$preexisting_dir/output" 2>&1
); then
    fail "pre-existing container name was accepted"
fi
grep -Fxq 'existing record must survive' "$preexisting_dir/$preexisting_name" ||
    fail "pre-existing record was modified"
if grep -Fxq "rm -f $preexisting_name" "$preexisting_dir/nerdctl.log"; then
    fail "pre-existing container was removed"
fi

printf 'Containerd creation rollback tests passed\n'
