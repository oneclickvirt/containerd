#!/bin/bash
# from
# https://github.com/oneclickvirt/containerd
# 2026.03.01
# 完整卸载 containerd 环境及所有容器
#
# Supported environment variables (non-interactive mode / 支持的环境变量，可实现无交互卸载):
#   CONFIRM_UNINSTALL=yes       - Skip confirmation prompt / 跳过确认提示直接卸载
#
# Example / 示例:
#   CONFIRM_UNINSTALL=yes bash containerduninstall.sh

_red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$*\033[0m"; }

if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root"
    exit 1
fi

echo ""
echo "======================================================"
_red "  ⚠  警告：即将卸载 containerd 全套环境"
echo "  包含：所有运行中/停止的容器、所有镜像、"
echo "  CNI 网络、systemd 服务、nerdctl/containerd 二进制"
echo "  操作不可逆！"
echo "======================================================"
if [[ "${CONFIRM_UNINSTALL:-}" == "yes" ]]; then
    confirm="yes"
    _blue "[non-interactive] CONFIRM_UNINSTALL=yes, proceeding with uninstall..."
else
    read -rp "$(_yellow "确认卸载？输入 yes 继续，其他任意键退出: ")" confirm
fi
if [[ "$confirm" != "yes" ]]; then
    _green "已取消"
    exit 0
fi

# ======== 1. 停止并删除所有容器（包括 ndpresponder） ========
_blue "[1/10] 停止并删除所有容器..."
if command -v nerdctl >/dev/null 2>&1; then
    # 列出所有命名空间
    namespaces=$(nerdctl namespace ls -q 2>/dev/null || echo "default")
    for ns in $namespaces; do
        containers=$(nerdctl -n "$ns" ps -aq 2>/dev/null || true)
        if [[ -n "$containers" ]]; then
            _yellow "  删除命名空间 ${ns} 中的容器..."
            nerdctl -n "$ns" rm -f $containers 2>/dev/null || true
        fi
    done
    _green "  容器已清理"
else
    _yellow "  nerdctl 未找到，跳过容器删除"
fi

# ======== 2. 删除所有镜像 ========
_blue "[2/10] 删除所有容器镜像..."
if command -v nerdctl >/dev/null 2>&1; then
    for ns in $(nerdctl namespace ls -q 2>/dev/null || echo "default"); do
        images=$(nerdctl -n "$ns" images -q 2>/dev/null || true)
        if [[ -n "$images" ]]; then
            _yellow "  删除命名空间 ${ns} 中的镜像..."
            nerdctl -n "$ns" rmi -f $images 2>/dev/null || true
        fi
    done
    _green "  镜像已清理"
fi

# ======== 3. 停止 systemd 服务 ========
_blue "[3/10] 停止并禁用 systemd 服务..."
for svc in buildkit buildkitd containerd check-dns nftables; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop "$svc" 2>/dev/null || true
        _yellow "  已停止 ${svc}"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        systemctl disable "$svc" 2>/dev/null || true
    fi
done
# 删除 systemd 服务文件
for f in \
    /usr/local/lib/systemd/system/containerd.service \
    /usr/local/lib/systemd/system/buildkit.service \
    /etc/systemd/system/containerd.service \
    /etc/systemd/system/buildkit.service \
    /etc/systemd/system/check-dns.service \
    /usr/lib/systemd/system/containerd.service \
    /usr/lib/systemd/system/buildkit.service; do
    [[ -f "$f" ]] && rm -f "$f" && _yellow "  删除 $f"
done
systemctl daemon-reload 2>/dev/null || true
_green "  服务已清理"

# ======== 4. 清理 CNI 网络配置 ========
_blue "[4/10] 清理 CNI 网络配置..."
rm -f /etc/cni/net.d/10-containerd-net.conflist
rm -f /etc/cni/net.d/11-containerd-ipv6.conflist
# 删除残留 CNI 网络接口
for br in ctn-br0 ctn-br1 nerdctl0 nerdctl1; do
    if ip link show "$br" >/dev/null 2>&1; then
        ip link set "$br" down 2>/dev/null || true
        ip link delete "$br" 2>/dev/null || true
        _yellow "  删除网络接口 $br"
    fi
done
_green "  CNI 网络已清理"

# ======== 5. 清理防火墙规则（nftables + iptables） ========
_blue "[5/10] 清理防火墙规则..."
# 清理 nftables 规则
if command -v nft >/dev/null 2>&1; then
    nft delete table ip containerd 2>/dev/null || true
    nft delete table ip6 containerd 2>/dev/null || true
    _yellow "  nftables containerd 表已删除"
fi
rm -f /etc/nftables.d/containerd.nft 2>/dev/null || true
# 清理 iptables 规则
if command -v iptables >/dev/null 2>&1; then
    iptables -t nat -D POSTROUTING -s 172.20.0.0/16 ! -d 172.20.0.0/16 -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -s 172.20.0.0/16 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d 172.20.0.0/16 -j ACCEPT 2>/dev/null || true
    _yellow "  IPv4 iptables 规则已清理"
fi
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -D FORWARD -i ctn-br1 -j ACCEPT 2>/dev/null || true
    ip6tables -D FORWARD -o ctn-br1 -j ACCEPT 2>/dev/null || true
    if [[ -f /usr/local/bin/containerd_ipv6_subnet ]]; then
        ipv6_subnet=$(cat /usr/local/bin/containerd_ipv6_subnet)
        ip6tables -D FORWARD -s "${ipv6_subnet}" -j ACCEPT 2>/dev/null || true
        ip6tables -D FORWARD -d "${ipv6_subnet}" -j ACCEPT 2>/dev/null || true
    fi
    _yellow "  IPv6 ip6tables 规则已清理"
fi
# 清理持久化规则文件
rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6 2>/dev/null || true
_green "  防火墙规则已清理"

# ======== 6. 删除 nerdctl-full 二进制及配置 ========
_blue "[6/10] 删除 nerdctl/containerd 二进制文件..."
# 主要二进制
for bin in \
    /usr/local/bin/nerdctl \
    /usr/bin/nerdctl \
    /usr/local/bin/containerd \
    /usr/bin/containerd \
    /usr/local/bin/containerd-shim \
    /usr/local/bin/containerd-shim-runc-v1 \
    /usr/local/bin/containerd-shim-runc-v2 \
    /usr/local/bin/ctr \
    /usr/bin/ctr \
    /usr/local/bin/runc \
    /usr/bin/runc \
    /usr/local/bin/buildctl \
    /usr/bin/buildctl \
    /usr/local/bin/buildkitd \
    /usr/bin/buildkitd \
    /usr/local/sbin/runc; do
    [[ -f "$bin" ]] && rm -f "$bin" && _yellow "  删除 $bin"
done
# CNI 插件
if [[ -d /usr/local/libexec/cni ]]; then
    rm -rf /usr/local/libexec/cni
    _yellow "  删除 /usr/local/libexec/cni"
fi
# containerd 配置目录
if [[ -d /etc/containerd ]]; then
    rm -rf /etc/containerd
    _yellow "  删除 /etc/containerd"
fi
if [[ -d /etc/buildkit ]]; then
    rm -rf /etc/buildkit
    _yellow "  删除 /etc/buildkit"
fi
if [[ -d /etc/nerdctl ]]; then
    rm -rf /etc/nerdctl
    _yellow "  删除 /etc/nerdctl"
fi
_green "  二进制及配置已清理"

# ======== 7. 清理 btrfs loop 文件系统 ========
_blue "[7/10] 清理 btrfs loop 文件系统..."
if [[ -f /usr/local/bin/containerd_loop_device ]]; then
    local_loop_device=$(cat /usr/local/bin/containerd_loop_device)
    local_mount_point=""
    if [[ -f /usr/local/bin/containerd_mount_point ]]; then
        local_mount_point=$(cat /usr/local/bin/containerd_mount_point)
    fi
    if [[ -n "$local_mount_point" ]] && mountpoint -q "$local_mount_point" 2>/dev/null; then
        umount "$local_mount_point" 2>/dev/null || umount -l "$local_mount_point" 2>/dev/null || true
        _yellow "  已卸载 $local_mount_point"
    fi
    if [[ -n "$local_loop_device" ]] && losetup "$local_loop_device" >/dev/null 2>&1; then
        losetup -d "$local_loop_device" 2>/dev/null || true
        _yellow "  已分离 loop 设备 $local_loop_device"
    fi
fi
if [[ -f /usr/local/bin/containerd_loop_file ]]; then
    local_loop_file=$(cat /usr/local/bin/containerd_loop_file)
    if [[ -f "$local_loop_file" ]]; then
        rm -f "$local_loop_file"
        _yellow "  删除 loop 文件 $local_loop_file"
    fi
    # 清理 fstab 条目
    if [[ -n "$local_loop_file" ]]; then
        sed -i "\|${local_loop_file}|d" /etc/fstab 2>/dev/null || true
    fi
fi
_green "  btrfs loop 文件系统已清理"

# ======== 8. 删除 containerd 数据目录 ========
_blue "[8/10] 删除 containerd 运行数据..."
# 如果有自定义安装路径，也一并删除
if [[ -f /usr/local/bin/containerd_install_path ]]; then
    custom_path=$(cat /usr/local/bin/containerd_install_path)
    if [[ -n "$custom_path" && -d "$custom_path" && "$custom_path" != "/" ]]; then
        rm -rf "$custom_path"
        _yellow "  删除 $custom_path"
    fi
fi
for dir in \
    /var/lib/containerd \
    /var/lib/buildkit \
    /var/lib/nerdctl \
    /run/containerd \
    /run/buildkit; do
    if [[ -d "$dir" ]]; then
        rm -rf "$dir"
        _yellow "  删除 $dir"
    fi
done
_green "  数据目录已清理"

# ======== 9. 删除本脚本安装的状态/辅助文件 ========
_blue "[9/10] 删除辅助状态文件..."
for f in \
    /usr/local/bin/containerd_arch \
    /usr/local/bin/containerd_cdn \
    /usr/local/bin/containerd_ipv6_enabled \
    /usr/local/bin/containerd_ipv6_subnet \
    /usr/local/bin/containerd_main_interface \
    /usr/local/bin/containerd_firewall_backend \
    /usr/local/bin/containerd_storage_driver \
    /usr/local/bin/containerd_need_disk_limit \
    /usr/local/bin/containerd_install_path \
    /usr/local/bin/containerd_loop_device \
    /usr/local/bin/containerd_loop_file \
    /usr/local/bin/containerd_mount_point \
    /usr/local/bin/containerd_storage_reboot \
    /usr/local/bin/check-dns.sh \
    /etc/profile.d/containerd-path.sh; do
    [[ -f "$f" ]] && rm -f "$f" && _yellow "  删除 $f"
done
# 删除 /tmp 残留
rm -f /tmp/spiritlhl_*.tar.gz 2>/dev/null || true
rm -f /tmp/ssh_bash.sh /tmp/ssh_sh.sh 2>/dev/null || true
_green "  状态文件已清理"

# ======== 10. 清理 sysctl 配置 ========
_blue "[10/10] 清理 sysctl 配置..."
if [[ -f /etc/sysctl.d/99-containerd.conf ]]; then
    rm -f /etc/sysctl.d/99-containerd.conf
    sysctl --system >/dev/null 2>&1 || true
    _yellow "  删除 /etc/sysctl.d/99-containerd.conf"
fi
_green "  sysctl 已清理"

echo ""
echo "======================================================"
_green "  ✓ containerd 环境已完整卸载！"
echo "======================================================"
echo ""
echo "如需重新安装，执行："
echo "  bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/containerd/main/containerdinstall.sh)"
