# containerd

[![Hits](https://hits.spiritlhl.net/containerd.svg)](https://hits.spiritlhl.net/containerd)

基于 containerd + nerdctl 的容器环境一键安装与管理脚本，对应 [oneclickvirt/docker](https://github.com/oneclickvirt/docker) 的 containerd 版本实现。

支持一键安装 containerd 运行时，并开设基于本仓库编译镜像的各种 Linux 容器（提供 SSH 访问），支持 IPv6、端口映射、资源限制等。

## 说明

- 使用 [nerdctl-full](https://github.com/containerd/nerdctl) 安装 containerd + runc + nerdctl + CNI + buildkitd 全套组件
- 使用本仓库自编译的基础镜像（存储在 GitHub Releases），优先离线加载，无法获取时回退到官方镜像
- 支持系统：Ubuntu 22.04、Debian 12、Alpine、AlmaLinux 9、RockyLinux 9、OpenEuler 22.03
- 支持架构：amd64、arm64

## 安装 containerd 环境

```bash
bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/containerd/main/containerdinstall.sh)
```

## 开设单个容器

```bash
# 下载脚本
wget -q https://raw.githubusercontent.com/oneclickvirt/containerd/main/scripts/onecontainerd.sh
chmod +x onecontainerd.sh

# 用法:
# ./onecontainerd.sh <name> <cpu> <memory_mb> <password> <sshport> <startport> <endport> [ipv6:y/n] [system] [disk_gb]

# 示例: 创建名为 ct1 的 Debian 容器，1核 512MB，SSH端口25000，额外端口34975-35000
./onecontainerd.sh ct1 1 512 MyPassword 25000 34975 35000 n debian 0
```

| 参数 | 说明 | 默认值 |
|------|------|--------|
| name | 容器名称 | test |
| cpu | CPU 核数（支持 0.5 等） | 1 |
| memory_mb | 内存限制（MB） | 512 |
| password | root 密码 | 123456 |
| sshport | SSH 端口（宿主机→容器 22） | 25000 |
| startport | 公网端口范围起始 | 34975 |
| endport | 公网端口范围结束 | 35000 |
| ipv6 | 是否分配独立 IPv6（y/n） | n |
| system | 镜像系统 | debian |
| disk_gb | 磁盘限制 GB（0=不限制） | 0 |

**支持的 system 参数：** `ubuntu` / `debian` / `alpine` / `almalinux` / `rockylinux` / `openeuler`

## 批量开设容器

```bash
wget -q https://raw.githubusercontent.com/oneclickvirt/containerd/main/scripts/create_containerd.sh
chmod +x create_containerd.sh
./create_containerd.sh
```

交互式脚本，自动递增容器名（ct1, ct2, ...）、SSH 端口、公网端口，容器信息记录到 `ctlog` 文件。

## 查看与管理容器

```bash
nerdctl ps -a                  # 查看所有容器
nerdctl exec -it <name> bash   # 进入容器（bash 系统）
nerdctl exec -it <name> sh     # 进入容器（alpine）
nerdctl logs <name>            # 查看容器日志
nerdctl rm -f <name>           # 删除单个容器
nerdctl images                 # 查看所有镜像
nerdctl rmi <image>            # 删除镜像
```

## 卸载（完整清理）

一键卸载 containerd 全套环境，包括所有容器、镜像、CNI 网络、systemd 服务、二进制文件：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/containerd/main/containerduninstall.sh)
```

脚本会在执行前要求输入 `yes` 确认，操作不可逆。

> **复测流程**：先执行卸载，再执行安装，即可从零验证整个安装流程。

## 镜像说明

本仓库自编镜像通过 GitHub Actions 构建并发布到 Releases：

| 系统 | amd64 | arm64 |
|------|-------|-------|
| Ubuntu 22.04 | spiritlhl_ubuntu_amd64.tar.gz | spiritlhl_ubuntu_arm64.tar.gz |
| Debian 12 | spiritlhl_debian_amd64.tar.gz | spiritlhl_debian_arm64.tar.gz |
| Alpine latest | spiritlhl_alpine_amd64.tar.gz | spiritlhl_alpine_arm64.tar.gz |
| AlmaLinux 9 | spiritlhl_almalinux_amd64.tar.gz | spiritlhl_almalinux_arm64.tar.gz |
| RockyLinux 9 | spiritlhl_rockylinux_amd64.tar.gz | spiritlhl_rockylinux_arm64.tar.gz |
| OpenEuler 22.03 | spiritlhl_openeuler_amd64.tar.gz | spiritlhl_openeuler_arm64.tar.gz |

## 网络说明

- **IPv4**：通过 `-p` 端口映射（bridge 模式，CNI `containerd-net`）
- **IPv6（独立地址）**：安装时自动检测公网 IPv6，创建 `containerd-ipv6` CNI 网络，并启动 NDP Responder 容器实现 IPv6 NDP 代理
- **DNS 保活**：通过 `check-dns.service` 系统服务持续检测 DNS 可用性

## Stargazers over time

[![Stargazers over time](https://starchart.cc/oneclickvirt/containerd.svg)](https://starchart.cc/oneclickvirt/containerd)

