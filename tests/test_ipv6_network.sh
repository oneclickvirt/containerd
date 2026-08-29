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
eval "$(extract_function derive_containerd_ipv6_subnet)"
# shellcheck disable=SC1090 # The test intentionally loads the host overlap helper.
eval "$(extract_function cni_ipv6_subnet_overlaps_host)"
# shellcheck disable=SC1090 # The test intentionally loads the precise route conflict helper.
eval "$(extract_function cni_ipv6_subnet_conflicts_with_host_route)"
# shellcheck disable=SC1090 # The test intentionally loads CNI conflict detection.
eval "$(extract_function cni_ipv6_subnet_overlaps_existing)"
# shellcheck disable=SC1090 # The test intentionally loads the ULA candidate helper.
eval "$(extract_function containerd_ipv6_ula_candidate)"
# shellcheck disable=SC1090 # The test intentionally loads ULA validation helpers.
eval "$(extract_function containerd_ipv6_ula_is_safe)"
# shellcheck disable=SC1090 # The test intentionally loads the CNI state guard.
eval "$(extract_function containerd_ipv6_ula_state_matches_cni)"
# shellcheck disable=SC1090 # The test intentionally loads the public CNI state guard.
eval "$(extract_function containerd_ipv6_managed_state_matches_cni)"
# shellcheck disable=SC1090 # The test intentionally loads the combined CNI state guard.
eval "$(extract_function containerd_ipv6_state_matches_cni)"
# shellcheck disable=SC1090 # The test intentionally loads the CNI subnet reader.
eval "$(extract_function containerd_cni_ipv6_subnet)"
# shellcheck disable=SC1090 # The test intentionally loads the ULA gateway helper.
eval "$(extract_function containerd_ipv6_ula_gateway)"
# shellcheck disable=SC1090 # The test intentionally loads the CNI reuse implementation.
eval "$(extract_function create_containerd_ula_ipv6_network)"
# shellcheck disable=SC1090 # The test intentionally loads the IPv6 CNI creator.
eval "$(extract_function create_ipv6_network)"
# shellcheck disable=SC1090 # The test intentionally loads installer helpers.
eval "$(extract_function is_public_ipv6)"
# shellcheck disable=SC1090 # The test intentionally loads one installer function.
eval "$(extract_function detect_global_ipv6_cidr)"
# shellcheck disable=SC1090 # The test intentionally loads IPv6 uplink helpers.
eval "$(extract_function containerd_ipv6_uplink_interface)"
# shellcheck disable=SC1090 # The test intentionally loads IPv6 uplink helpers.
eval "$(extract_function containerd_ipv6_uplink_supports_ndp)"
# shellcheck disable=SC1090 # The test intentionally loads IPv6 responder state setup.
eval "$(extract_function configure_containerd_ipv6_ndp_state)"
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
eval "$(extract_function ndpresponder_image_matches_architecture)"
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
eval "$(extract_function ndpresponder_supports_ready_file)"
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
eval "$(extract_function ndpresponder_image_supports_required_features)"
# shellcheck disable=SC1090 # The test intentionally loads one installer helper.
eval "$(extract_function resolve_ndpresponder_image)"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/containerd-ipv6-test.XXXXXX")
trap 'rm -rf -- "$tmpdir"' EXIT
cat > "$tmpdir/ip" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-d" ] && [ "${2:-}" = "link" ]; then
    case "${5:-}" in
        he-ipv6) printf '%s\n' '5: he-ipv6: <POINTOPOINT,UP> mtu 1480 link/sit' ;;
        *) printf '%s\n' '4: vmbr2: <BROADCAST,UP> mtu 1500 link/ether 02:00:00:00:00:01' ;;
    esac
    exit 0
fi
if [ "${1:-}" = "link" ] && [ "${2:-}" = "show" ]; then
    printf '%s\n' '4: vmbr2: <BROADCAST,UP> mtu 1500 link/ether 02:00:00:00:00:01'
    exit 0
fi
if [ "${1:-}" = "-6" ] && [ "${2:-}" = "route" ]; then
    if [ "${3:-}" = "show" ] && [ "${4:-}" = "default" ] && [ "${IPV6_TEST_SCENARIO:-}" = delegated ]; then
        # The management /128 uses the default route, while the delegated
        # /38 is carried by a separate PVE bridge.
        printf '%s\n' 'default via fe80::1 dev eth0 proto ra metric 1024'
        exit 0
    fi
    route_scenario=$IPV6_ROUTE_SCENARIO
    case "$route_scenario" in
        conflict) printf '%s\n' '2a14:6781:a::1:0:0/96 dev eth0 proto static metric 256' ;;
        *) printf '%s\n' '2a14:6781:a::/64 dev eth0 proto kernel metric 256' ;;
    esac
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
    narrow120)
        printf '%s\n' '2: eth0    inet6 2a14:6781:a::9/120 scope global'
        ;;
    narrow127)
        printf '%s\n' '2: eth0    inet6 2a14:6781:a::8/127 scope global'
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
uplink=$(containerd_ipv6_uplink_interface)
if [[ "$uplink" != eth0 ]]; then
    printf 'normal /64 uplink detection returned %q\n' "$uplink" >&2
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
uplink=$(containerd_ipv6_uplink_interface)
if [[ "$uplink" != he-ipv6 ]] || containerd_ipv6_uplink_supports_ndp "$uplink"; then
    printf 'tunnel IPv6 uplink was not recognized as non-Ethernet: %q\n' "$uplink" >&2
    exit 1
fi
export CONTAINERD_IPV6_STATE_DIR="$tmpdir/state"
# shellcheck disable=SC2218 # A later test mock must not intercept this real setup command.
command mkdir -p "$CONTAINERD_IPV6_STATE_DIR"
printf '%s\n' manual > "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_network_mode"
if ! configure_containerd_ipv6_ndp_state || \
   [[ "$(tr -d '[:space:]' < "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_ndp_required")" != false ]]; then
    printf 'tunnel IPv6 incorrectly required a Containerd NDP responder\n' >&2
    exit 1
fi
export IPV6_TEST_SCENARIO=delegated
uplink=$(containerd_ipv6_uplink_interface)
if [[ "$uplink" != vmbr2 ]] || ! containerd_ipv6_uplink_supports_ndp "$uplink"; then
    printf 'PVE delegated IPv6 uplink was not recognized as Ethernet: %q\n' "$uplink" >&2
    exit 1
fi
if ! configure_containerd_ipv6_ndp_state || \
   [[ "$(tr -d '[:space:]' < "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_ndp_required")" != true ]]; then
    printf 'PVE Ethernet IPv6 did not require a Containerd NDP responder\n' >&2
    exit 1
fi
export IPV6_TEST_SCENARIO=narrow120
detected=$(detect_global_ipv6_cidr eth0)
if [[ "$detected" != '2a14:6781:a::9/120' ]]; then
    printf 'routed /120 detection returned %q\n' "$detected" >&2
    exit 1
fi
export IPV6_TEST_SCENARIO=narrow127
detected=$(detect_global_ipv6_cidr eth0)
if [[ "$detected" != '2a14:6781:a::8/127' ]]; then
    printf 'routed /127 detection returned %q\n' "$detected" >&2
    exit 1
fi
unset IPV6_TEST_SCENARIO
candidate=$(derive_containerd_ipv6_subnet "$host_cidr" 96 0 false)
if derive_containerd_ipv6_subnet "$host_cidr" 96 0 true >/dev/null; then
    printf 'explicit host-containing CNI subnet was accepted\n' >&2
    exit 1
fi

# A routed host /128 proves IPv6 connectivity but cannot provide a CNI child
# subnet. The installer must use its private ULA NAT66 fallback instead.
containerd_nat66_parent=''
# shellcheck disable=SC2329 # Invoked by the dynamically sourced CNI creator.
create_containerd_ula_ipv6_network() {
    containerd_nat66_parent="$1"
    return 0
}
# shellcheck disable=SC2329 # Invoked by the dynamically sourced CNI creator.
_yellow() { :; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced CNI creator.
_red() { :; }
# shellcheck disable=SC2034 # Read by the dynamically sourced IPv6 CNI creator.
CONTAINERD_IPV6_SUBNET_PREFIX=80
# shellcheck disable=SC2034 # Read by the dynamically sourced IPv6 CNI creator.
CONTAINERD_IPV6_SUBNET_INDEX=1
if ! create_ipv6_network '2a14:6781:000a:0000::9/128'; then
    printf 'host-only /128 did not fall back to Containerd ULA NAT66\n' >&2
    exit 1
fi
if [[ "$containerd_nat66_parent" != '2a14:6781:000a:0000::9/128' ]]; then
    printf 'Containerd NAT66 fallback used unexpected parent %q\n' "$containerd_nat66_parent" >&2
    exit 1
fi
for short_parent in '2a14:6781:a::9/120' '2a14:6781:a::8/127'; do
    containerd_nat66_parent=''
    if ! create_ipv6_network "$short_parent"; then
        printf 'short IPv6 prefix did not fall back to Containerd ULA NAT66: %q\n' "$short_parent" >&2
        exit 1
    fi
    if [[ "$containerd_nat66_parent" != "$short_parent" ]]; then
        printf 'Containerd NAT66 fallback used unexpected short parent %q for %q\n' "$containerd_nat66_parent" "$short_parent" >&2
        exit 1
    fi
done
# shellcheck disable=SC1090 # Restore the real helper for the reuse checks below.
eval "$(extract_function create_containerd_ula_ipv6_network)"
if ! cni_ipv6_subnet_overlaps_host "2a14:6781:a::1:0:0/96"; then
    printf 'connected host IPv6 route was not detected as a CNI overlap\n' >&2
    exit 1
fi
if cni_ipv6_subnet_conflicts_with_host_route "2a14:6781:a::1:0:0/96"; then
    printf 'parent IPv6 route incorrectly blocked a host-disjoint CNI child\n' >&2
    exit 1
fi
export IPV6_ROUTE_SCENARIO=conflict
if ! cni_ipv6_subnet_conflicts_with_host_route "2a14:6781:a::1:0:0/96"; then
    printf 'equal IPv6 route was not detected as a CNI conflict\n' >&2
    exit 1
fi
unset IPV6_ROUTE_SCENARIO
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
# shellcheck disable=SC2218 # A later test mock must not intercept this real setup command.
command mkdir -p "$tmpdir/state"
# shellcheck disable=SC2329 # Invoked by the dynamically sourced CNI creator.
_green() { :; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced CNI creator.
_yellow() { :; }
export CONTAINERD_CNI_IPV6_CONFIG="$tmpdir/onlink-cni.conflist"
export CONTAINERD_IPV6_STATE_DIR="$tmpdir/state"
if ! create_ipv6_network '2a14:6781:a::9/64'; then
    printf 'host-disjoint child of an on-link IPv6 /64 was not accepted by Containerd CNI\n' >&2
    exit 1
fi
if [[ "$(tr -d '[:space:]' <"$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_network_mode")" != managed ]] || \
   [[ "$(containerd_cni_ipv6_subnet "$CONTAINERD_CNI_IPV6_CONFIG")" != 2a14:6781:a:0:1::/80 ]]; then
    printf 'Containerd on-link IPv6 /64 did not retain a managed public CNI child\n' >&2
    exit 1
fi
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

# A public CNI network is safe to reuse only when its recorded subnet and
# managed mode match. An untracked or stale state must never overwrite it.
managed_public_subnet='2a14:6781:beef:200::/64'
cat > "$CONTAINERD_CNI_IPV6_CONFIG" <<EOF
{
  "plugins": [{"ipam": {"ranges": [[{"subnet": "172.21.0.0/16"}], [{"subnet": "${managed_public_subnet}"}]]}}]
}
EOF
printf 'managed\n' > "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_network_mode"
printf '%s\n' "$managed_public_subnet" > "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_subnet"
cp "$CONTAINERD_CNI_IPV6_CONFIG" "$tmpdir/original-public-cni.conflist"
if ! create_ipv6_network '2a14:6781:a::9/48'; then
    printf 'installer-managed public Containerd CNI network was not reused\n' >&2
    exit 1
fi
if ! cmp -s "$CONTAINERD_CNI_IPV6_CONFIG" "$tmpdir/original-public-cni.conflist"; then
    printf 'reusing Containerd public CNI unexpectedly rewrote its configuration\n' >&2
    exit 1
fi
printf 'unknown\n' > "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_network_mode"
if create_ipv6_network '2a14:6781:a::9/48'; then
    printf 'untracked Containerd public CNI was incorrectly reused\n' >&2
    exit 1
fi
if ! cmp -s "$CONTAINERD_CNI_IPV6_CONFIG" "$tmpdir/original-public-cni.conflist"; then
    printf 'untracked Containerd public CNI configuration was overwritten\n' >&2
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
if ! extract_function adapt_ipv6 | grep -Fq "net.ipv6.conf.\${uplink}.accept_ra=2"; then
    printf 'Containerd IPv6 forwarding must preserve router advertisements on the uplink\n' >&2
    exit 1
fi
if extract_function adapt_ipv6 | grep -Eq 'update_sysctl[[:space:]].*proxy_ndp'; then
    printf 'Containerd IPv6 setup must not change global proxy_ndp state\n' >&2
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
if grep -Fq 'buildkit buildkitd containerd check-dns nftables' "$repo_root/containerduninstall.sh" ||
   grep -Fq 'rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6' "$repo_root/containerduninstall.sh"; then
    printf 'Containerd uninstall must not disable global firewall services or remove global snapshots\n' >&2
    exit 1
fi
if ! grep -Fq 'refresh_firewall_snapshot iptables-save /etc/iptables/rules.v4' "$repo_root/containerduninstall.sh" ||
   ! grep -Fq 'refresh_firewall_snapshot ip6tables-save /etc/iptables/rules.v6' "$repo_root/containerduninstall.sh"; then
    printf 'Containerd uninstall must refresh existing firewall snapshots after removing its rules\n' >&2
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
if ! grep -Fq 'containerd_ipv6_ndp_required' "$repo_root/scripts/onecontainerd.sh" || \
   ! grep -Fq 'ndp_required" != "false"' "$repo_root/scripts/onecontainerd.sh"; then
    printf 'Containerd creation must not require ndpresponder for NAT66 or non-Ethernet IPv6\n' >&2
    exit 1
fi
if [[ "$(grep -Fc 'nerdctl rm -f ndpresponder' <<<"$start_ndpresponder_source")" -lt 2 ]]; then
    printf 'Containerd must remove a failed ndpresponder after health verification\n' >&2
    exit 1
fi
if ! grep -Fq -- '--ready-file /run/ndpresponder-ready' <<<"$start_ndpresponder_source" || \
   ! grep -Fq 'containerd_ipv6_ndp_ready' "$repo_root/scripts/onecontainerd.sh"; then
    printf 'Containerd must wait for the NDP responder readiness marker before allocating public IPv6\n' >&2
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
        run:--rm)
            printf '%s\n' '      --ready-file value  responder readiness marker'
            return 0
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
# shellcheck disable=SC2034 # Consumed by the dynamically sourced resolver.
NDPRESPONDER_READY_FILE_REQUIRED=true
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
eval "$(extract_function start_ndpresponder)"
export CONTAINERD_IPV6_STATE_DIR="$tmpdir/ndp-state"
# shellcheck disable=SC2218 # A later test mock must not intercept this real setup command.
command mkdir -p "$CONTAINERD_IPV6_STATE_DIR"
# shellcheck disable=SC2329 # Invoked by the dynamically sourced responder starter.
_green() { :; }
printf '%s\n' nat > "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_network_mode"
if ! start_ndpresponder; then
    printf 'Containerd NAT66 unnecessarily required ndpresponder\n' >&2
    exit 1
fi
printf '%s\n' manual > "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_network_mode"
printf '%s\n' false > "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_ndp_required"
if ! start_ndpresponder; then
    printf 'Containerd tunnel IPv6 unnecessarily required ndpresponder\n' >&2
    exit 1
fi
printf '%s\n' managed > "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_network_mode"
printf '%s\n' true > "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_ndp_required"
printf '%s\n' eth0 > "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_uplink"
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

# A process in the running state can still be probing the uplink. New
# installations must wait for ndpresponder to confirm that it can answer NDP.
# shellcheck disable=SC2329 # Invoked by the dynamically sourced responder starter.
mkdir() { :; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced responder starter.
sleep() { :; }
# shellcheck disable=SC2329 # Invoked by the dynamically sourced responder starter.
nerdctl() {
    case "$1:$2" in
        pull:*)
            return 0
            ;;
        image:inspect)
            printf '%s\n' arm64
            return 0
            ;;
        run:--rm)
            printf '%s\n' '      --ready-file value  responder readiness marker'
            return 0
            ;;
        run:-d)
            printf '%s\n' eth0 >"$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_ndp_ready"
            return 0
            ;;
        inspect:-f)
            printf '%s\n' running
            return 0
            ;;
        rm:*)
            return 0
            ;;
        *)
            printf 'unexpected nerdctl invocation during readiness test: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
if ! start_ndpresponder; then
    printf 'Containerd did not accept a responder after its readiness marker was written\n' >&2
    exit 1
fi
if [[ ! -s "$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_ndp_ready" || \
      "$(tr -d '[:space:]' <"$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_ndp_ready_required")" != true ]]; then
    printf 'Containerd did not persist successful NDP readiness\n' >&2
    exit 1
fi

extract_onecontainerd_function() {
    local name="$1"
    awk -v name="$name" '
        $0 == name "() {" { printing = 1 }
        printing {
            print
            if ($0 == "}") {
                exit
            }
        }
    ' "$repo_root/scripts/onecontainerd.sh"
}
# shellcheck disable=SC1090 # The test intentionally loads the creation readiness helper.
eval "$(extract_onecontainerd_function containerd_ipv6_ready)"
export CONTAINERD_CNI_IPV6_CONFIG="$tmpdir/containerd-ready.conflist"
: >"$CONTAINERD_CNI_IPV6_CONFIG"
printf '%s\n' true >"$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_enabled"
printf '%s\n' 'fd42:5339:296f:1d00::/64' >"$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_subnet"
if ! containerd_ipv6_ready; then
    printf 'Containerd creation rejected a ready responder\n' >&2
    exit 1
fi
: >"$CONTAINERD_IPV6_STATE_DIR/containerd_ipv6_ndp_ready"
if containerd_ipv6_ready; then
    printf 'Containerd creation accepted a responder before its readiness marker was present\n' >&2
    exit 1
fi

printf 'containerd IPv6 network candidate tests passed\n'
