#!/bin/sh
# entrypoint_alpine.sh - 适用于 Alpine Linux
# from https://github.com/oneclickvirt/containerd

set -e

# 设置 root 密码
if [ -n "$ROOT_PASSWORD" ]; then
    echo "root:${ROOT_PASSWORD}" | chpasswd 2>/dev/null || true
fi

# 修复 sshd_config.d/
config_dir="/etc/ssh/sshd_config.d/"
if [ -d "$config_dir" ]; then
    for file in "${config_dir}"*; do
        [ -f "$file" ] || continue
        sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' "$file" 2>/dev/null || true
        sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/g' "$file" 2>/dev/null || true
    done
fi

# 确保 sshd_config 配置正确
sshd_cfg="/etc/ssh/sshd_config"
if [ -f "$sshd_cfg" ]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$sshd_cfg"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$sshd_cfg"
fi

# 确保 SSH 主机密钥存在
mkdir -p /var/run/sshd
ssh-keygen -A 2>/dev/null || true

# 启动 cron
crond 2>/dev/null || true

# 设置 cron 保活 sshd
cron_line="* * * * * pgrep -x sshd>/dev/null||/usr/sbin/sshd"
(crontab -l 2>/dev/null | grep -v "sshd"; printf "%s\n" "$cron_line") | crontab - 2>/dev/null || true

# 前台运行 sshd
exec /usr/sbin/sshd -D -e
