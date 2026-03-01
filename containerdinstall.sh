#!/bin/bash
# from
# https://github.com/oneclickvirt/containerd
# 2026.03.01

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }
export DEBIAN_FRONTEND=noninteractive
utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
if [[ -z "$utf8_locale" ]]; then
    _yellow "No UTF-8 locale found"
else
    export LC_ALL="$utf8_locale"
    export LANG="$utf8_locale"
    export LANGUAGE="$utf8_locale"
fi
if [ "$(id -u)" != "0" ]; then
    _red "This script must be run as root" 1>&2
    exit 1
fi
if [ ! -d /usr/local/bin ]; then
    mkdir -p /usr/local/bin
fi

# ======== 系统检测 ========
REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch" "Alpine")
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
    "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)"
    "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)"
    "$(lsb_release -sd 2>/dev/null)"
    "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)"
    "$(grep . /etc/redhat-release 2>/dev/null)"
    "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')"
    "$(grep . /etc/alpine-release 2>/dev/null)"
)
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
if [[ -z $SYSTEM ]]; then
    _red "ERROR: The script does not support the current system!"
    exit 1
fi

# ======== 架构检测 ========
ARCH_UNAME=$(uname -m)
case "$ARCH_UNAME" in
    x86_64)  ARCH_TYPE="amd64" ;;
    aarch64) ARCH_TYPE="arm64" ;;
    armv7l)  ARCH_TYPE="arm"   ;;
    *)
        _red "Unsupported arch: $ARCH_UNAME"
        exit 1
        ;;
esac
_blue "Detected system: $SYSTEM  arch: $ARCH_TYPE"

# ======== CDN 检测 ========
check_china() {
    local ip_info
    ip_info=$(curl -sLk --connect-timeout 5 --max-time 10 "https://ipapi.co/json/" 2>/dev/null || true)
    if echo "$ip_info" | grep -q '"country": "CN"'; then
        CN=true
    fi
}
check_china

if [[ "${CN}" == true ]]; then
    _yellow "China mainland network detected, using domestic CDN"
    cdn_success_url="https://cdn.spiritlhl.net/"
else
    cdn_success_url=""
fi

# ======== 工具函数 ========
update_sysctl() {
    local key="${1%%=*}"
    local val="${1##*=}"
    if grep -q "^${key}" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s|^${key}.*|${key}=${val}|g" /etc/sysctl.conf
    else
        echo "${key}=${val}" >> /etc/sysctl.conf
    fi
    sysctl -w "${key}=${val}" >/dev/null 2>&1 || true
}

is_private_ipv6() {
    local addr="$1"
    [[ "$addr" =~ ^fd ]] && return 0
    [[ "$addr" =~ ^fc ]] && return 0
    [[ "$addr" =~ ^fe[89ab] ]] && return 0
    [[ "$addr" == "::1" ]] && return 0
    return 1
}

# ======== 检测公网 IPv6 ========
check_ipv6() {
    IPV6=$(ip -6 addr show 2>/dev/null | grep global | awk '{print length, $2}' | sort -nr | head -n 1 | awk '{print $2}' | cut -d '/' -f1)
    if [[ -z "$IPV6" ]] || is_private_ipv6 "$IPV6"; then
        IPV6=""
        local API_NET=("ipv6.ip.sb" "https://ipget.net" "ipv6.ping0.cc" "https://api.my-ip.io/ip" "https://ipv6.icanhazip.com")
        for p in "${API_NET[@]}"; do
            local response
            response=$(curl -sLk6m8 "$p" 2>/dev/null | tr -d '[:space:]')
            if [[ $? -eq 0 ]] && ! echo "$response" | grep -q "error"; then
                IPV6="$response"
                break
            fi
            sleep 1
        done
    fi
    if [[ -n "$IPV6" ]] && ! is_private_ipv6 "$IPV6"; then
        _green "Detected public IPv6: $IPV6"
        IPV6_ENABLED=true
    else
        _yellow "No public IPv6 detected"
        IPV6_ENABLED=false
    fi
}

# ======== 检测主网络接口 ========
detect_interface() {
    interface=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    if [[ -z "$interface" ]]; then
        interface=$(ip link show | awk '/^[0-9]+: /{gsub(":", "", $2); if($2!="lo") {print $2; exit}}')
    fi
    _blue "Main network interface: $interface"
    echo "$interface" > /usr/local/bin/containerd_main_interface
}

# ======== 安装基础依赖 ========
install_base_deps() {
    _yellow "Installing base dependencies..."
    case $SYSTEM in
        Debian|Ubuntu)
            eval "${PACKAGE_UPDATE[int]}" 2>/dev/null || true
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates iptables iproute2 \
                socat unzip tar jq 2>/dev/null || true
            ;;
        CentOS|Fedora)
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates iptables iproute \
                socat unzip tar jq 2>/dev/null || true
            ;;
        Alpine)
            ${PACKAGE_UPDATE[int]} 2>/dev/null || true
            ${PACKAGE_INSTALL[int]} curl wget ca-certificates iptables iproute2 \
                socat unzip tar jq 2>/dev/null || true
            ;;
    esac
    _green "Base dependencies installed"
}

# ======== 安装 nerdctl-full (containerd + runc + nerdctl + CNI + buildkitd) ========
install_containerd_stack() {
    _yellow "Installing containerd stack (nerdctl-full bundle)..."

    local nerdctl_ver
    nerdctl_ver=$(curl -s "${cdn_success_url}https://api.github.com/repos/containerd/nerdctl/releases/latest" 2>/dev/null \
        | grep tag_name | cut -d'"' -f4 | sed 's/v//')
    if [[ -z "$nerdctl_ver" ]]; then
        nerdctl_ver="2.0.4"
    fi
    _blue "nerdctl version: $nerdctl_ver"

    local nerdctl_url="${cdn_success_url}https://github.com/containerd/nerdctl/releases/download/v${nerdctl_ver}/nerdctl-full-${nerdctl_ver}-linux-${ARCH_TYPE}.tar.gz"
    local tmp_tar
    tmp_tar=$(mktemp /tmp/nerdctl-full-XXXXXX.tar.gz)

    _yellow "Downloading nerdctl-full (this may take a while)..."
    if ! curl -L --connect-timeout 30 --max-time 600 -o "$tmp_tar" "$nerdctl_url"; then
        _red "Failed to download nerdctl-full"
        rm -f "$tmp_tar"
        exit 1
    fi
    tar -C /usr/local -xzf "$tmp_tar"
    rm -f "$tmp_tar"
    _green "nerdctl-full extracted to /usr/local"

    # containerd systemd 服务文件
    if [[ ! -f /etc/systemd/system/containerd.service ]] && \
       [[ ! -f /usr/lib/systemd/system/containerd.service ]] && \
       [[ ! -f /usr/local/lib/systemd/system/containerd.service ]]; then
        cat > /etc/systemd/system/containerd.service <<'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=1048576
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
    fi

    # buildkitd 服务
    if [[ ! -f /etc/systemd/system/buildkit.service ]]; then
        cat > /etc/systemd/system/buildkit.service <<'EOF'
[Unit]
Description=BuildKit
Requires=containerd.service
After=containerd.service

[Service]
ExecStart=/usr/local/bin/buildkitd --oci-worker=false --containerd-worker=true
Type=notify
Restart=always
RestartSec=5
Delegate=yes

[Install]
WantedBy=multi-user.target
EOF
    fi

    # 确保 /usr/local/bin 在 PATH 中
    if ! echo "$PATH" | grep -q "/usr/local/bin"; then
        export PATH="/usr/local/bin:$PATH"
        echo 'export PATH="/usr/local/bin:$PATH"' >> /etc/profile
    fi

    _green "containerd stack installed"
}

# ======== 配置 containerd ========
configure_containerd() {
    _yellow "Configuring containerd..."
    mkdir -p /etc/containerd
    if command -v containerd >/dev/null 2>&1; then
        containerd config default > /etc/containerd/config.toml 2>/dev/null || true
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    fi
    _green "containerd configured"
}

# ======== 配置 CNI 网络 ========
configure_cni() {
    _yellow "Configuring CNI network..."
    mkdir -p /etc/cni/net.d

    cat > /etc/cni/net.d/10-containerd-net.conflist <<'EOF'
{
  "cniVersion": "1.0.0",
  "name": "containerd-net",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "ctn-br0",
      "isGateway": true,
      "ipMasq": true,
      "promiscMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [
          [{
            "subnet": "172.20.0.0/16",
            "gateway": "172.20.0.1"
          }]
        ],
        "routes": [
          {"dst": "0.0.0.0/0"}
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    },
    {
      "type": "firewall"
    },
    {
      "type": "tuning"
    }
  ]
}
EOF
    _green "CNI network configured"
}

# ======== 配置内核参数 ========
configure_kernel() {
    _yellow "Configuring kernel parameters..."
    modprobe overlay 2>/dev/null || true
    modprobe br_netfilter 2>/dev/null || true
    update_sysctl "net.ipv4.ip_forward=1"
    update_sysctl "net.bridge.bridge-nf-call-iptables=1"
    update_sysctl "net.bridge.bridge-nf-call-ip6tables=1"
    sysctl --system >/dev/null 2>&1 || true
    _green "Kernel parameters configured"
}

# ======== 启动服务 ========
start_services() {
    _yellow "Starting containerd and buildkitd services..."
    if [[ "$SYSTEM" == "Alpine" ]]; then
        rc-update add containerd default 2>/dev/null || true
        rc-service containerd start 2>/dev/null || true
    else
        systemctl daemon-reload
        systemctl enable containerd
        systemctl restart containerd
        sleep 3
        systemctl enable buildkit 2>/dev/null || true
        systemctl start buildkit 2>/dev/null || true
    fi
    sleep 2
    if pgrep -x containerd >/dev/null 2>&1; then
        _green "containerd is running"
    else
        _yellow "Warning: containerd may not be running. Check: systemctl status containerd"
    fi
}

# ======== 配置 IPv6 内核参数 ========
adapt_ipv6() {
    _yellow "Configuring IPv6 kernel parameters..."
    update_sysctl "net.ipv6.conf.all.forwarding=1"
    update_sysctl "net.ipv6.conf.default.proxy_ndp=1"
    update_sysctl "net.ipv6.conf.all.proxy_ndp=1"
    if [[ -n "$interface" ]]; then
        update_sysctl "net.ipv6.conf.${interface}.proxy_ndp=1"
    fi
    sysctl --system >/dev/null 2>&1 || true
}

# ======== 创建 IPv6 CNI 网络 ========
create_ipv6_network() {
    local ipv6_addr="$1"
    _yellow "Creating IPv6 CNI network..."

    # 计算 /80 子网 (取 IPv6 地址前缀)
    local prefix=""
    if command -v python3 >/dev/null 2>&1; then
        prefix=$(python3 -c "
import ipaddress, sys
try:
    addr = ipaddress.ip_address('${ipv6_addr}')
    net = ipaddress.ip_network(str(addr) + '/80', strict=False)
    print(str(net))
except Exception as e:
    sys.exit(1)
" 2>/dev/null || true)
    fi
    if [[ -z "$prefix" ]]; then
        prefix=$(echo "$ipv6_addr" | awk -F: '{print $1":"$2":"$3":"$4"::/80"}')
    fi

    echo "$prefix" > /usr/local/bin/containerd_ipv6_subnet

    cat > /etc/cni/net.d/11-containerd-ipv6.conflist <<EOF
{
  "cniVersion": "1.0.0",
  "name": "containerd-ipv6",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "ctn-br1",
      "isGateway": true,
      "ipMasq": false,
      "promiscMode": true,
      "ipam": {
        "type": "host-local",
        "ranges": [
          [{
            "subnet": "172.21.0.0/16",
            "gateway": "172.21.0.1"
          }],
          [{
            "subnet": "${prefix}"
          }]
        ],
        "routes": [
          {"dst": "0.0.0.0/0"},
          {"dst": "::/0"}
        ]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true}
    },
    {
      "type": "firewall"
    },
    {
      "type": "tuning"
    }
  ]
}
EOF
    _green "IPv6 CNI network (containerd-ipv6) created: $prefix"
}

# ======== 启动 NDP Responder ========
start_ndpresponder() {
    _yellow "Starting NDP responder for IPv6..."
    local arch_tag
    case "$ARCH_TYPE" in
        amd64) arch_tag="x86" ;;
        arm64) arch_tag="arm64" ;;
        *)     arch_tag="x86" ;;
    esac

    nerdctl rm -f ndpresponder 2>/dev/null || true

    nerdctl run -d \
        --restart always \
        --cpus 0.02 \
        --memory 64m \
        --cap-drop=ALL \
        --cap-add=NET_RAW \
        --cap-add=NET_ADMIN \
        --network host \
        --name ndpresponder \
        "spiritlhl/ndpresponder_${arch_tag}" \
        -i "${interface}" -N containerd-ipv6 2>/dev/null \
    && _green "NDP responder started" \
    || _yellow "ndpresponder start failed; IPv6 may require manual NDP configuration"
}

# ======== DNS 保活服务 ========
setup_dns_check() {
    _yellow "Setting up DNS liveness check service..."
    cat > /usr/local/bin/check-dns.sh <<'EOF'
#!/bin/bash
# DNS liveness check for containerd
while true; do
    if ! nslookup github.com >/dev/null 2>&1; then
        if [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
            ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
        fi
        grep -q "8.8.8.8" /etc/resolv.conf || echo "nameserver 8.8.8.8" >> /etc/resolv.conf
        grep -q "1.1.1.1" /etc/resolv.conf || echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    fi
    sleep 60
done
EOF
    chmod +x /usr/local/bin/check-dns.sh

    if [[ "$SYSTEM" != "Alpine" ]]; then
        cat > /etc/systemd/system/check-dns.service <<'EOF'
[Unit]
Description=DNS Liveness Check for Containerd
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/check-dns.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable check-dns 2>/dev/null || true
        systemctl start check-dns 2>/dev/null || true
    fi
    _green "DNS check service configured"
}

# ======== 验证安装 ========
verify_install() {
    _yellow "Verifying installation..."
    local all_ok=true
    for cmd in containerd runc nerdctl; do
        if command -v "$cmd" >/dev/null 2>&1; then
            _green "  ✓ $cmd: $(${cmd} --version 2>/dev/null | head -1)"
        else
            _yellow "  ✗ $cmd not found"
            all_ok=false
        fi
    done
    if command -v buildkitd >/dev/null 2>&1; then
        _green "  ✓ buildkitd available"
    fi
    if $all_ok; then
        _green "All components installed successfully"
    else
        _yellow "Some components missing, please check manually"
    fi
}

# ======== 主流程 ========
main() {
    _blue "======================================================"
    _blue "  Containerd 容器运行时一键安装脚本"
    _blue "  from https://github.com/oneclickvirt/containerd"
    _blue "  2026.03.01"
    _blue "======================================================"
    echo

    # 重新计算 int（系统类型索引）
    for ((int = 0; int < ${#REGEX[@]}; int++)); do
        if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
            break
        fi
    done

    detect_interface
    check_ipv6
    install_base_deps
    install_containerd_stack
    configure_containerd
    configure_cni
    configure_kernel
    start_services
    setup_dns_check

    if [[ "$IPV6_ENABLED" == true ]]; then
        adapt_ipv6
        create_ipv6_network "$IPV6"
        start_ndpresponder
        echo "true" > /usr/local/bin/containerd_ipv6_enabled
    else
        echo "false" > /usr/local/bin/containerd_ipv6_enabled
    fi

    # 保存架构信息
    echo "$ARCH_TYPE" > /usr/local/bin/containerd_arch

    verify_install

    echo
    _green "======================================================"
    _green "  ✓ Containerd 安装完成！"
    _green "======================================================"
    echo
    _blue "常用命令:"
    _yellow "  查看容器:  nerdctl ps -a"
    _yellow "  拉取镜像:  nerdctl pull ubuntu:22.04"
    _yellow "  开设容器:  bash scripts/onecontainerd.sh <name> <cpu> <mem_mb> <passwd> <sshport> <startport> <endport>"
    _yellow "  批量开设:  bash scripts/create_containerd.sh"
    _yellow "  项目地址:  https://github.com/oneclickvirt/containerd"
    echo
}

main "$@"

