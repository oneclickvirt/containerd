#!/bin/bash
# entrypoint.sh - 适用于 bash 系统（Debian/Ubuntu/AlmaLinux/RockyLinux/OpenEuler）
# from https://github.com/oneclickvirt/containerd

set -e

# 设置 root 密码（支持通过环境变量传入）
if [[ -n "$ROOT_PASSWORD" ]]; then
    echo "root:${ROOT_PASSWORD}" | chpasswd 2>/dev/null || true
fi

# 修复 sshd_config.d/ 中的覆盖配置
config_dir="/etc/ssh/sshd_config.d/"
if [ -d "$config_dir" ]; then
    for file in "${config_dir}"*; do
        [ -f "$file" ] || continue
        sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' "$file" 2>/dev/null || true
        sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/g' "$file" 2>/dev/null || true
    done
fi

# 确保 sshd_config 允许 root 和密码登录
sshd_cfg="/etc/ssh/sshd_config"
if [ -f "$sshd_cfg" ]; then
    grep -q "^PermitRootLogin yes" "$sshd_cfg" || \
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$sshd_cfg"
    grep -q "^PasswordAuthentication yes" "$sshd_cfg" || \
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$sshd_cfg"
fi

# 修复 cloud-init 密码禁用策略
if [ -f /etc/cloud/cloud.cfg ]; then
    sed -E -i 's/ssh_pwauth:[[:space:]]*false/ssh_pwauth:   true/g' /etc/cloud/cloud.cfg 2>/dev/null || true
    sed -E -i 's/disable_root:[[:space:]]*true/disable_root: false/g' /etc/cloud/cloud.cfg 2>/dev/null || true
fi

# 确保 SSH 主机密钥存在
mkdir -p /var/run/sshd
ssh-keygen -A 2>/dev/null || true

# 启动 cron
if command -v cron >/dev/null 2>&1; then
    cron 2>/dev/null || true
elif command -v crond >/dev/null 2>&1; then
    crond 2>/dev/null || true
fi

# 设置 cron 保活 sshd
cron_line="* * * * * pgrep -x sshd>/dev/null||/usr/sbin/sshd"
(crontab -l 2>/dev/null | grep -v "sshd"; echo "$cron_line") | crontab - 2>/dev/null || true

# 前台运行 sshd
exec /usr/sbin/sshd -D -e
