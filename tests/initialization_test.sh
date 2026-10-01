#!/usr/bin/env bash
# Fault injection only: selected functions run against mock commands.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer="$repo_root/containerdinstall.sh"
load_function() {
    source <(awk -v name="$1" '$0 == name "() {" { printing=1 } printing { print } printing && /^}$/ { exit }' "$installer")
}
_green() { :; }
_yellow() { :; }
_red() { :; }
_blue() { :; }
_info() { :; }
_warn() { :; }
_step() { :; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for name in setup_nftables_ipv4 ensure_nftables_ipv4_rule setup_iptables_ipv4 setup_firewall_rules start_services; do load_function "$name"; done
mock_nft_fail=true mock_adds=0
mock_existing='ip saddr 172.20.0.0/16 ip daddr != 172.20.0.0/16 masquerade
ip saddr 172.20.0.0/16 accept
ip daddr 172.20.0.0/16 accept
tcp dport 2200 dnat to 172.20.0.2:22'
nft() {
    [[ "$1" != delete && "$1" != flush ]] || fail 'must never remove active port rules'
    $mock_nft_fail && return 1
    if [[ "$1" == list ]]; then printf '%s\n' "$mock_existing"; else mock_adds=$((mock_adds + 1)); fi
}
if setup_nftables_ipv4; then fail 'nft errors must propagate'; fi
mock_nft_fail=false
setup_nftables_ipv4 || fail 'existing NAT rules should succeed'
[[ "$mock_adds" == 0 ]] || fail 'existing NAT rules must not be duplicated'
mock_existing=""
setup_nftables_ipv4 || fail 'missing rules should be added'
[[ "$mock_adds" == 3 ]] || fail 'must add three base rules'
iptables() { return 1; }
if setup_iptables_ipv4; then fail 'iptables errors must propagate'; fi
FIREWALL_BACKEND=none
if setup_firewall_rules; then fail 'IPv4 requires a firewall backend'; fi
SYSTEM=Alpine
rc-update() { :; }
rc-service() { :; }
sleep() { :; }
ctr() { return 1; }
if start_services; then fail 'service command success cannot replace daemon readiness'; fi
containerd_source=$(<"$installer")
grep -Fq 'if ! fallocate -l "${pool_size_gb}G" "$loop_file"' <<<"$containerd_source" ||
    fail 'Containerd btrfs setup must propagate loop-file allocation failures'
grep -Fq 'if ! loop_device=$(losetup --find --show "$loop_file")' <<<"$containerd_source" ||
    fail 'Containerd btrfs setup must propagate loop attachment failures'
grep -Fq 'if ! mkfs.btrfs -f "$loop_device"' <<<"$containerd_source" ||
    fail 'Containerd btrfs setup must propagate filesystem formatting failures'
grep -Fq 'if ! mount "$loop_device" "$mount_point"' <<<"$containerd_source" ||
    fail 'Containerd btrfs setup must propagate mount failures'
grep -Fq 'Existing containerd loop file backed up to' <<<"$containerd_source" ||
    fail 'Containerd btrfs setup must preserve unattached existing loop images'
grep -Fq 'if ! cat > "$cni_config" <<EOF' <<<"$containerd_source" ||
    fail 'Containerd IPv6 CNI write failure must be detected'
grep -Fq 'update_sysctl "net.ipv6.conf.all.forwarding=1" || return 1' <<<"$containerd_source" ||
    fail 'Containerd IPv6 forwarding failure must disable optional IPv6 cleanly'
grep -Fq 'if reboot; then' <<<"$containerd_source" ||
    fail 'Containerd must propagate a failed reboot while enabling btrfs'
printf 'Containerd installation fault-injection tests passed (6 scenarios)\n'
# Exercise the real Debian update expression as well as installation. In
# particular, a successful first update must not enter the repair branch.
source <(awk '/^PACKAGE_UPDATE=\(/ { printing=1 } printing { print } printing && /^\)/ { exit }' "$installer")
source <(awk '/^PACKAGE_INSTALL=\(/ { printing=1 } printing { print } printing && /^\)/ { exit }' "$installer")
for name in install_base_deps; do
    load_function "$name"
    for scenario in success recovered update_failed repair_failed install_failed; do
        (
            SYSTEM=Debian int=0 mock_updates=0 mock_repairs=0 mock_installs=0
            apt-get() {
                case "$*" in
                    update)
                        mock_updates=$((mock_updates + 1))
                        case "$scenario:$mock_updates" in
                            recovered:1|update_failed:*|repair_failed:1) return 100 ;;
                        esac
                        ;;
                    '--fix-broken install -y')
                        mock_repairs=$((mock_repairs + 1))
                        [[ "$scenario" != repair_failed ]] || return 100
                        ;;
                    '-y install '*)
                        mock_installs=$((mock_installs + 1))
                        [[ "$scenario" != install_failed ]] || return 100
                        ;;
                    *) fail "Unexpected apt-get: $*" ;;
                esac
                return 0
            }
            rc=0
            "$name" || rc=$?
            case "$scenario" in
                success) [[ "$rc:$mock_updates:$mock_repairs:$mock_installs" == 0:1:0:1 ]] ;;
                recovered) [[ "$rc:$mock_updates:$mock_repairs:$mock_installs" == 0:2:1:1 ]] ;;
                update_failed) [[ "$rc:$mock_updates:$mock_repairs:$mock_installs" == 1:2:1:0 ]] ;;
                repair_failed) [[ "$rc:$mock_updates:$mock_repairs:$mock_installs" == 1:1:1:0 ]] ;;
                install_failed) [[ "$rc:$mock_updates:$mock_repairs:$mock_installs" == 1:1:0:1 ]] ;;
            esac || fail "$name/$scenario returned $rc with updates=$mock_updates repairs=$mock_repairs installs=$mock_installs"
        )
    done
done
printf 'Debian package-update and repair paths passed\n'

containerd_source=$(<"$installer")
grep -Fq 'nerdctl-full did not provide a usable CNI plugin directory' <<<"$containerd_source" ||
    fail 'containerd must reject a bundle without CNI plugins'
grep -Fq 'for cni_candidate in /opt/cni/bin /usr/local/libexec/cni /usr/local/lib/cni /usr/lib/cni' <<<"$containerd_source" ||
    fail 'containerd must support newer nerdctl-full CNI locations'
grep -Fq 'ln -s "$cni_source/$cni_plugin" "/opt/cni/bin/$cni_plugin"' <<<"$containerd_source" ||
    fail 'containerd must expose discovered CNI plugins at the standard path'
printf 'Containerd CNI plugin layout compatibility checks passed\n'

load_function select_standard_snapshotter
containerd_install_path=/var/lib/containerd
findmnt() { printf '%s\n' overlay; }
[[ "$(select_standard_snapshotter | tail -n 1)" == native ]] ||
    fail 'overlay-backed containerd data root must use the native snapshotter'
findmnt() { printf '%s\n' ext4; }
[[ "$(select_standard_snapshotter | tail -n 1)" == overlayfs ]] ||
    fail 'normal containerd data root should retain overlayfs'
printf 'Containerd snapshotter compatibility checks passed\n'

for name in containerd_data_root_has_state configured_containerd_snapshotter guard_containerd_snapshotter; do
    load_function "$name"
done
snapshotter_guard_dir=$(mktemp -d)
snapshotter_state="$snapshotter_guard_dir/driver"
snapshotter_config="$snapshotter_guard_dir/config.toml"
snapshotter_nerdctl="$snapshotter_guard_dir/nerdctl.toml"
mkdir -p "$snapshotter_guard_dir/data"
printf '%s\n' content-state >"$snapshotter_guard_dir/data/marker"
containerd_install_path="$snapshotter_guard_dir/data"
DEFAULT_CONTAINERD_INSTALL_PATH="$snapshotter_guard_dir/data"
CONTAINERD_STORAGE_DRIVER_STATE="$snapshotter_state"
CONTAINERD_CONFIG_FILE="$snapshotter_config"
NERDCTL_CONFIG_FILE="$snapshotter_nerdctl"
printf '%s\n' overlayfs >"$snapshotter_state"
guard_containerd_snapshotter overlayfs || fail 'matching containerd snapshotter must preserve existing data'
if guard_containerd_snapshotter native; then
    fail 'containerd must reject switching existing data to another snapshotter'
fi
rm -f -- "$snapshotter_state"
printf '%s\n' 'snapshotter = "overlayfs"' >"$snapshotter_config"
guard_containerd_snapshotter overlayfs || fail 'containerd config should identify existing snapshotter'
rm -f -- "$snapshotter_config"
printf '%s\n' 'snapshotter = "overlayfs"' >"$snapshotter_nerdctl"
guard_containerd_snapshotter overlayfs || fail 'nerdctl config should identify existing snapshotter'
rm -f -- "$snapshotter_nerdctl"
if guard_containerd_snapshotter native; then
    fail 'containerd must reject unknown snapshotter on existing data'
fi
rm -rf -- "$snapshotter_guard_dir"
unset CONTAINERD_STORAGE_DRIVER_STATE CONTAINERD_CONFIG_FILE NERDCTL_CONFIG_FILE
printf 'Containerd existing-data snapshotter guard passed\n'

grep -Fq 'oneclickvirt transfer unpack configuration' <<<"$containerd_source" ||
    fail 'non-default containerd snapshotters must configure transfer unpack platforms'
grep -Fq 'platform = "${transfer_platform}"' <<<"$containerd_source" ||
    fail 'containerd transfer unpack configuration must be architecture-aware'
printf 'Containerd non-default snapshotter unpack configuration check passed\n'
grep -Fq 'native 快照器；用于 overlay-backed 宿主兼容性' <<<"$containerd_source" ||
    fail 'containerd completion summary must distinguish native from overlayfs'
printf 'Containerd snapshotter completion summary check passed\n'
grep -Fq 'try_storage_drivers || return 1' <<<"$containerd_source" ||
    fail 'containerd must stop when snapshotter protection rejects existing data'
printf 'Containerd snapshotter refusal propagation check passed\n'

load_function guard_existing_containerd_owner
package_owns_path() { return 1; }
systemctl() { :; }
guard_existing_containerd_owner || fail 'clean dedicated nodes must remain installable'
package_owns_path() { [[ "$1" == /usr/bin/containerd ]]; }
if guard_existing_containerd_owner; then
    fail 'package-owned containerd must not be overwritten'
fi
package_owns_path() { return 1; }
systemctl() {
    [[ "$*" == 'cat docker.service' ]] &&
        printf '%s\n' 'ExecStart=/usr/bin/dockerd --containerd=/run/containerd/containerd.sock'
}
if guard_existing_containerd_owner; then
    fail 'Docker shared-containerd nodes must not be taken over'
fi
printf 'Containerd cross-runtime ownership guard passed\n'
grep -Fq '"ca-certificates"' "$repo_root/scripts/ssh_bash.sh" ||
    fail 'Debian/RHEL guest bootstrap must install TLS root certificates'
grep -Fq 'ca-certificates' "$repo_root/scripts/ssh_sh.sh" ||
    fail 'Alpine guest bootstrap must install TLS root certificates'
printf 'Containerd guest TLS bootstrap contract passed\n'
