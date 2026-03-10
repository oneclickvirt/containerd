#!/bin/bash
# from
# https://github.com/oneclickvirt/containerd
# 2026.03.01

# 容器内 SSH 初始化脚本（适用于 bash 系统：Debian/Ubuntu/AlmaLinux/RockyLinux/OpenEuler）

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

# ======== 安装必要模块 ========
install_required_modules() {
    local modules=("wget" "curl" "sudo" "openssh-server")
    case $SYSTEM in
        Debian|Ubuntu)
            apt-get update -y 2>/dev/null || true
            for module in "${modules[@]}"; do
                dpkg -l "$module" 2>/dev/null | grep -q "^ii" || apt-get -y install "$module" 2>/dev/null || true
            done
            apt-get -y install cron 2>/dev/null || apt-get -y install cronie 2>/dev/null || true
            ;;
        CentOS|Fedora)
            for module in "${modules[@]}"; do
                command -v "$module" >/dev/null 2>&1 || yum -y install "$module" 2>/dev/null || true
            done
            yum -y install cronie 2>/dev/null || true
            ;;
        *)
            for module in "${modules[@]}"; do
                command -v "$module" >/dev/null 2>&1 || ${PACKAGE_INSTALL[int]} "$module" 2>/dev/null || true
            done
            ;;
    esac
}

# ======== 更新 motd ========
update_motd() {
    grep -qF 'Related repo https://github.com/oneclickvirt/containerd' /etc/motd 2>/dev/null || \
        echo 'Related repo https://github.com/oneclickvirt/containerd' >> /etc/motd
    grep -qF 'https://t.me/spiritlhl' /etc/motd 2>/dev/null || \
        echo '--by https://t.me/spiritlhl' >> /etc/motd
}

# ======== 关闭 SELinux / iptables（RHEL 系）========
disable_selinux_iptables() {
    service iptables stop 2>/dev/null || true
    if [ -f /etc/selinux/config ]; then
        sed -i.bak '/^SELINUX=/cSELINUX=disabled' /etc/selinux/config
        setenforce 0 2>/dev/null || true
    fi
}

# ======== 配置 sshd ========
update_sshd_config() {
    local config_file="/etc/ssh/sshd_config"
    # 处理 include 目录中的覆盖配置
    local config_dir="/etc/ssh/sshd_config.d/"
    if [ -d "$config_dir" ]; then
        for file in "${config_dir}"*; do
            [ -f "$file" ] || continue
            sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' "$file"
            sed -i 's/PermitRootLogin no/PermitRootLogin yes/g' "$file"
            sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/g' "$file"
        done
    fi
    [ -f "$config_file" ] || return 0
    sed -i "s/^#\?Port.*/Port 22/g" "$config_file"
    sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/g" "$config_file"
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g" "$config_file"
    sed -i "s/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/g" "$config_file"
    sed -i "s/^#\?UsePAM.*/UsePAM yes/g" "$config_file"
    # 确保监听所有接口
    grep -q "^ListenAddress 0.0.0.0" "$config_file" || \
        sed -i 's/#ListenAddress 0.0.0.0/ListenAddress 0.0.0.0/' "$config_file" || \
        echo "ListenAddress 0.0.0.0" >> "$config_file"
}

# ======== 修复 cloud-init 策略 ========
fix_cloud_init() {
    if [ -f /etc/cloud/cloud.cfg ]; then
        sed -E -i 's/ssh_pwauth:[[:space:]]*false/ssh_pwauth:   true/g' /etc/cloud/cloud.cfg
        sed -E -i 's/disable_root:[[:space:]]*true/disable_root: false/g' /etc/cloud/cloud.cfg
        sed -E -i 's/disable_root:[[:space:]]*1/disable_root: 0/g' /etc/cloud/cloud.cfg
    fi
}

# ======== 生成并启动 sshd ========
start_sshd() {
    cd /etc/ssh || true
    ssh-keygen -A 2>/dev/null || true
    # 确保 /var/run/sshd 目录存在
    mkdir -p /var/run/sshd
    # 启动 sshd
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    elif command -v service >/dev/null 2>&1; then
        service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
    else
        /usr/sbin/sshd 2>/dev/null || true
    fi
}

# ======== 设置自启动 cron 任务确保 sshd 存活 ========
setup_cron_sshd() {
    local cron_line="* * * * * pgrep -x sshd>/dev/null||/usr/sbin/sshd"
    (crontab -l 2>/dev/null | grep -v "sshd"; echo "$cron_line") | crontab - 2>/dev/null || true
    if command -v crond >/dev/null 2>&1; then
        crond 2>/dev/null || true
    elif command -v cron >/dev/null 2>&1; then
        cron 2>/dev/null || true
    fi
}

# ======== 主流程 ========
passwd_input="${1:-123456}"

install_required_modules
update_motd
disable_selinux_iptables
fix_cloud_init
update_sshd_config

# 设置 root 密码
echo "root:${passwd_input}" | chpasswd 2>/dev/null || \
    echo "root:${passwd_input}" | sudo chpasswd 2>/dev/null || true

start_sshd
setup_cron_sshd

echo "SSH initialization completed"
