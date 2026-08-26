#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/containerdinstall.sh"

extract_function() {
    local name="$1"
    awk -v name="$name" '
        $0 == name "() {" { printing = 1 }
        printing {
            print
            if ($0 ~ /<<EOF$/) {
                in_heredoc = 1
                next
            }
            if (in_heredoc) {
                if ($0 == "EOF") {
                    in_heredoc = 0
                }
                next
            }
            if ($0 == "}") {
                exit
            }
        }
    ' "$installer"
}

# shellcheck disable=SC1090 # The test intentionally loads one installer function.
source <(extract_function derive_containerd_ipv6_subnet)
# shellcheck disable=SC1090 # The test intentionally loads the host overlap helper.
source <(extract_function cni_ipv6_subnet_overlaps_host)
# shellcheck disable=SC1090 # The test intentionally loads the ULA candidate helper.
source <(extract_function containerd_ipv6_ula_candidate)
# shellcheck disable=SC1090 # The test intentionally loads ULA validation helpers.
source <(extract_function containerd_ipv6_ula_is_safe)
# shellcheck disable=SC1090 # The test intentionally loads the CNI state guard.
source <(extract_function containerd_ipv6_ula_state_matches_cni)
# shellcheck disable=SC1090 # The test intentionally loads the CNI subnet reader.
source <(extract_function containerd_cni_ipv6_subnet)
# shellcheck disable=SC1090 # The test intentionally loads the ULA gateway helper.
source <(extract_function containerd_ipv6_ula_gateway)
# shellcheck disable=SC1090 # The test intentionally loads the CNI reuse implementation.
source <(extract_function create_containerd_ula_ipv6_network)
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
source <(extract_function is_public_ipv6)
# shellcheck disable=SC1090 # The test intentionally loads one installer function.
source <(extract_function detect_global_ipv6_cidr)
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
source <(extract_function ndpresponder_image_matches_architecture)
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
source <(extract_function resolve_ndpresponder_image)

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/containerd-ipv6-test.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT
cat > "$tmpdir/ip" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-6" ] && [ "${2:-}" = "route" ]; then
    printf '%s\n' '2a14:6781:a::/64 dev eth0 proto kernel metric 256'
    exit 0
fi
case "${IPV6_TEST_SCENARIO:-default}" in
    delegated)
        case " $* " in
            *" dev eth0 "*)
                printf '%s\n' '2: vmbr0    inet6 2a14:7c0:1002:10f8::1/128 scope global'
                ;;
            *)
                printf '%s\n' '2: vmbr0    inet6 2a14:7c0:1002:10f8::1/128 scope global'
                printf '%s\n' '4: vmbr2    inet6 2a14:7c0:1002:10f8::1/38 scope global'
                ;;
        esac
        ;;
    tunnel)
        printf '%s\n' '5: he-ipv6    inet6 2001:470:1f14:9::2/64 scope global'
        ;;
    *)
        printf '%s\n' '2: eth0    inet6 fd42::1/64 scope global'
        printf '%s\n' '2: eth0    inet6 2a14:6781:000a:0000::9/64 scope global tentative'
        printf '%s\n' '2: eth0    inet6 2a14:6781:000a:0000::10/64 scope global'
        ;;
esac
EOF
chmod 700 "$tmpdir/ip"

host_cidr="2a14:6781:000a:0000::9/64"
old_path="$PATH"
export PATH="$tmpdir:$PATH"
detected=$(detect_global_ipv6_cidr eth0)
if [[ "$detected" != "2a14:6781:000a:0000::10/64" ]]; then
    printf 'local public CIDR detection returned %q\n' "$detected" >&2
    exit 1
fi
export IPV6_TEST_SCENARIO=delegated
detected=$(detect_global_ipv6_cidr eth0)
if [[ "$detected" != '2a14:7c0:1002:10f8::1/38' ]]; then
    printf 'delegated /38 was hidden by an uplink /128: %q\n' "$detected" >&2
    exit 1
fi
export IPV6_TEST_SCENARIO=tunnel
detected=$(detect_global_ipv6_cidr eth0)
if [[ "$detected" != '2001:470:1f14:9::2/64' ]]; then
    printf 'tunnel /64 detection returned %q\n' "$detected" >&2
    exit 1
fi
unset IPV6_TEST_SCENARIO
candidate=$(derive_containerd_ipv6_subnet "$host_cidr" 96 0 false)
if derive_containerd_ipv6_subnet "$host_cidr" 96 0 true >/dev/null; then
    printf 'explicit host-containing CNI subnet was accepted\n' >&2
    exit 1
fi
if ! cni_ipv6_subnet_overlaps_host "2a14:6781:a::1:0:0/96"; then
    printf 'connected host IPv6 route was not detected as a CNI overlap\n' >&2
    exit 1
fi
ula_candidate=$(containerd_ipv6_ula_candidate 0)
if cni_ipv6_subnet_overlaps_host "$ula_candidate"; then
    printf 'isolated Containerd ULA unexpectedly overlaps the host route\n' >&2
    exit 1
fi
if ! containerd_ipv6_ula_state_matches_cni nat "$ula_candidate" "$ula_candidate"; then
    printf 'installer-managed Containerd ULA was not accepted for reuse\n' >&2
    exit 1
fi
if containerd_ipv6_ula_state_matches_cni managed "$ula_candidate" "$ula_candidate" ||
   containerd_ipv6_ula_state_matches_cni nat "fd42:5339:296f:1e01::/64" "$ula_candidate" ||
   containerd_ipv6_ula_state_matches_cni nat "2a14:6781:a::/64" "2a14:6781:a::/64"; then
    printf 'unmanaged or mismatched Containerd IPv6 CNI network was accepted for reuse\n' >&2
    exit 1
fi
cat > "$tmpdir/known-cni.conflist" <<EOF
{
  "plugins": [{"ipam": {"ranges": [[{"subnet": "172.21.0.0/16"}], [{"subnet": "${ula_candidate}"}]]}}]
}
EOF
if [[ "$(containerd_cni_ipv6_subnet "$tmpdir/known-cni.conflist")" != "$ula_candidate" ]]; then
    printf 'Containerd CNI subnet reader did not return its sole IPv6 subnet\n' >&2
    exit 1
fi
ula_gateway=$(containerd_ipv6_ula_gateway "$ula_candidate")
mkdir -p "$tmpdir/state"
export CONTAINERD_CNI_IPV6_CONFIG="$tmpdir/managed-cni.conflist"
export CONTAINERD_IPV6_STATE_DIR="$tmpdir/state"
cat > "$CONTAINERD_CNI_IPV6_CONFIG" <<EOF
{
  "plugins": [{"ipam": {"ranges": [[{"subnet": "172.21.0.0/16"}], [{"subnet": "${ula_candidate}", "gateway": "${ula_gateway}"}]]}}]
}
EOF
printf 'nat\n' > "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_network_mode"
printf '%s\n' "$ula_candidate" > "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_subnet"
cp "$CONTAINERD_CNI_IPV6_CONFIG" "$tmpdir/original-managed-cni.conflist"
# shellcheck disable=SC2329 # Invoked by the dynamically sourced CNI helper.
_green() { :; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced CNI helper.
_yellow() { :; }
if ! create_containerd_ula_ipv6_network '2a14:6781:a::9/64'; then
    printf 'installer-managed Containerd ULA CNI network was not reused\n' >&2
    exit 1
fi
if ! cmp -s "$CONTAINERD_CNI_IPV6_CONFIG" "$tmpdir/original-managed-cni.conflist"; then
    printf 'reusing Containerd ULA CNI unexpectedly rewrote its configuration\n' >&2
    exit 1
fi
printf 'managed\n' > "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_network_mode"
if create_containerd_ula_ipv6_network '2a14:6781:a::9/64'; then
    printf 'unmanaged Containerd CNI network was incorrectly reused\n' >&2
    exit 1
fi
if ! cmp -s "$CONTAINERD_CNI_IPV6_CONFIG" "$tmpdir/original-managed-cni.conflist"; then
    printf 'unmanaged Containerd CNI configuration was overwritten\n' >&2
    exit 1
fi
unset CONTAINERD_CNI_IPV6_CONFIG CONTAINERD_IPV6_STATE_DIR
export PATH="$old_path"

if ! is_public_ipv6 "2a14:6781:a::9"; then
    printf 'expected a global unicast IPv6 to be accepted\n' >&2
    exit 1
fi
for non_public in "fec0::1" "ff02::1" "64:ff9b::1" "2001:0000::1" "2001:0002::1" "2001:0010::1" "2001:0020::1" "2001:0db8::1" "2002::1" "3fff:000f::1"; do
    if is_public_ipv6 "$non_public"; then
        printf 'non-public IPv6 was accepted as a Containerd source: %s\n' "$non_public" >&2
        exit 1
    fi
done

python3 - "$host_cidr" "$candidate" <<'PY'
import ipaddress
import sys

host = ipaddress.IPv6Interface(sys.argv[1])
candidate = ipaddress.IPv6Network(sys.argv[2])
if candidate.prefixlen != 96:
    raise SystemExit(f"unexpected prefix length: {candidate}")
if candidate.network_address not in host.network or candidate.broadcast_address not in host.network:
    raise SystemExit(f"candidate outside parent: {candidate}")
if host.ip in candidate:
    raise SystemExit(f"candidate contains host address: {candidate}")
PY

if extract_function check_ipv6 | grep -Eq 'API_NET|curl[[:space:]]'; then
    printf 'check_ipv6 must not use an external address as a CNI subnet source\n' >&2
    exit 1
fi
if ! extract_function adapt_ipv6 | grep -Fq "net.ipv6.conf.\${interface}.accept_ra=2"; then
    printf 'Containerd IPv6 forwarding must preserve router advertisements on the uplink\n' >&2
    exit 1
fi
if ! extract_function create_containerd_ula_ipv6_network | grep -Fq '"ipMasq": false'; then
    printf 'Containerd ULA NAT66 must use the installer-owned firewall rule set exactly once\n' >&2
    exit 1
fi
if ! extract_function create_containerd_ula_ipv6_network | grep -Fq 'containerd_ipv6_ula_state_matches_cni'; then
    printf 'Containerd ULA reuse must be guarded by matching installer state\n' >&2
    exit 1
fi
if ! ndpresponder_image_matches_architecture arm64 arm64 ||
   ! ndpresponder_image_matches_architecture arm arm ||
   ndpresponder_image_matches_architecture arm64 amd64 ||
   ndpresponder_image_matches_architecture arm amd64; then
    printf 'Containerd responder image architecture validation is incorrect\n' >&2
    exit 1
fi
if ! grep -Fq 'arm64) arch_tag="aarch64"' "$installer" ||
   ! grep -Fq 'NDPRESPONDER_SOURCE_URL' "$installer"; then
    printf 'Containerd must select the published aarch64 responder tag on ARM64\n' >&2
    exit 1
fi
start_ndpresponder_source=$(extract_function start_ndpresponder)
if grep -Fq -- '--restart always' <<<"$start_ndpresponder_source"; then
    printf 'Containerd ndpresponder must not retain an unconditional restart policy\n' >&2
    exit 1
fi
if ! grep -Fq -- '--restart on-failure:3' <<<"$start_ndpresponder_source"; then
    printf 'Containerd ndpresponder must use a bounded failure restart policy\n' >&2
    exit 1
fi
if [[ "$(grep -Fc 'nerdctl rm -f ndpresponder' <<<"$start_ndpresponder_source")" -lt 2 ]]; then
    printf 'Containerd must remove a failed ndpresponder after health verification\n' >&2
    exit 1
fi
# shellcheck disable=SC2329 # Invoked by the dynamically sourced resolver.
_yellow() { :; }
ARCH_TYPE=arm64
mock_build_succeeds=true
mock_build_called=false
mock_remove_called=false
mock_git_clone_called=false
git() {
    case "$1:$2" in
        clone:--depth)
            mock_git_clone_called=true
            return 0
            ;;
        *)
            printf 'unexpected git invocation during resolver test: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
# shellcheck disable=SC2329 # Invoked by the dynamically sourced resolver.
nerdctl() {
    case "$1:$2" in
        pull:*)
            return 0
            ;;
        image:inspect)
            case "$*" in
                *localhost/oneclickvirt-ndpresponder:arm64*) printf '%s\n' arm64 ;;
                *) printf '%s\n' amd64 ;;
            esac
            return 0
            ;;
        build:--tag)
            local build_context=""
            for build_context in "$@"; do :; done
            [[ "$build_context" != *"://"* ]] || return 1
            mock_build_called=true
            "$mock_build_succeeds"
            return
            ;;
        rm:*)
            mock_remove_called=true
            return 0
            ;;
        *)
            printf 'unexpected nerdctl invocation during resolver test: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
# shellcheck disable=SC2034 # Consumed by the dynamically sourced resolver.
NDPRESPONDER_SOURCE_URL=https://example.invalid/ndpresponder.git
if ! resolve_ndpresponder_image; then
    printf 'Containerd did not build a validated local responder after a bad registry architecture\n' >&2
    exit 1
fi
[[ "$NDPRESPONDER_IMAGE" == 'localhost/oneclickvirt-ndpresponder:arm64' ]] || {
    printf 'Containerd resolver selected %q instead of the validated local responder\n' "$NDPRESPONDER_IMAGE" >&2
    exit 1
}
[[ "$mock_git_clone_called" == true && "$mock_build_called" == true && "$mock_remove_called" == false ]] || {
    printf 'Containerd resolver mutated a responder container before the caller could validate the fallback\n' >&2
    exit 1
}

# A broken remote ARM tag must not tear down a known-good responder before the
# new image has passed architecture validation.
# shellcheck disable=SC1090 # The test intentionally loads the installer function.
source <(extract_function start_ndpresponder)
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer function.
_yellow() { :; }
# shellcheck disable=SC2034 # Read by the dynamically sourced installer function.
ARCH_TYPE=arm64
nerdctl_rm_called=false
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer function.
mkdir() { :; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced installer function.
nerdctl() {
    case "$1:$2" in
        pull:*)
            return 0
            ;;
        image:inspect)
            printf '%s\n' amd64
            return 0
            ;;
        build:--tag)
            return 1
            ;;
        rm:*)
            nerdctl_rm_called=true
            return 0
            ;;
        *)
            printf 'unexpected nerdctl invocation during architecture guard: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
if start_ndpresponder; then
    printf 'Containerd accepted an amd64 responder image on ARM64\n' >&2
    exit 1
fi
[[ "$nerdctl_rm_called" == false ]] || {
    printf 'Containerd removed the existing responder before rejecting the wrong architecture\n' >&2
    exit 1
}

printf 'containerd IPv6 network candidate tests passed\n'
