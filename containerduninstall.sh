#!/bin/bash
# from
# https://github.com/oneclickvirt/containerd
# 2026.03.01
# 完整卸载 containerd 环境及所有容器

_red()    { echo -e "\033[31m\033[01m$@\033[0m"; }
_green()  { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue()   { echo -e "\033[36m\033[01m$@\033[0m"; }

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
read -rp "$(_yellow "确认卸载？输入 yes 继续，其他任意键退出: ")" confirm
if [[ "$confirm" != "yes" ]]; then
    _green "已取消"
    exit 0
fi

# ======== 1. 停止并删除所有容器 ========
_blue "[1/9] 停止并删除所有容器..."
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
_blue "[2/9] 删除所有容器镜像..."
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
_blue "[3/9] 停止并禁用 systemd 服务..."
for svc in buildkitd containerd check-dns; do
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
    /etc/systemd/system/check-dns.service \
    /usr/lib/systemd/system/containerd.service \
    /usr/lib/systemd/system/buildkit.service; do
    [[ -f "$f" ]] && rm -f "$f" && _yellow "  删除 $f"
done
systemctl daemon-reload 2>/dev/null || true
_green "  服务已清理"

# ======== 4. 清理 CNI 网络配置 ========
_blue "[4/9] 清理 CNI 网络配置..."
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

# ======== 5. 清理 iptables/ip6tables 规则 ========
_blue "[5/9] 清理 iptables NAT/FORWARD 规则..."
if command -v iptables >/dev/null 2>&1; then
    # 删除 IPv4 MASQUERADE 规则
    iptables -t nat -D POSTROUTING -s 172.20.0.0/16 ! -d 172.20.0.0/16 -j MASQUERADE 2>/dev/null || true
    # 删除 IPv4 FORWARD 规则
    iptables -D FORWARD -s 172.20.0.0/16 -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -d 172.20.0.0/16 -j ACCEPT 2>/dev/null || true
    _yellow "  IPv4 iptables 规则已清理"
fi
if command -v ip6tables >/dev/null 2>&1; then
    # 删除 IPv6 FORWARD 规则
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
if [[ -f /etc/iptables/rules.v4 ]]; then
    rm -f /etc/iptables/rules.v4
    _yellow "  删除 /etc/iptables/rules.v4"
fi
if [[ -f /etc/iptables/rules.v6 ]]; then
    rm -f /etc/iptables/rules.v6
    _yellow "  删除 /etc/iptables/rules.v6"
fi
_green "  iptables 规则已清理"

# ======== 6. 删除 nerdctl-full 二进制及配置 ========
_blue "[6/9] 删除 nerdctl/containerd 二进制文件..."
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
_green "  二进制及配置已清理"

# ======== 7. 删除 containerd 数据目录 ========
_blue "[7/9] 删除 containerd 运行数据..."
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

# ======== 8. 删除本脚本安装的状态/辅助文件 ========
_blue "[8/9] 删除辅助状态文件..."
for f in \
    /usr/local/bin/containerd_arch \
    /usr/local/bin/containerd_cdn \
    /usr/local/bin/containerd_ipv6_enabled \
    /usr/local/bin/containerd_ipv6_subnet \
    /usr/local/bin/containerd_main_interface \
    /usr/local/bin/check-dns.sh \
    /etc/profile.d/containerd-path.sh; do
    [[ -f "$f" ]] && rm -f "$f" && _yellow "  删除 $f"
done
# 删除 /tmp 残留
rm -f /tmp/spiritlhl_*.tar.gz 2>/dev/null || true
rm -f /tmp/ssh_bash.sh /tmp/ssh_sh.sh 2>/dev/null || true
_green "  状态文件已清理"

# ======== 9. 清理 sysctl 配置 ========
_blue "[9/9] 清理 sysctl 配置..."
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
