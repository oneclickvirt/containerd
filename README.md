# containerd

[![Hits](https://hits.spiritlhl.net/containerd.svg)](https://hits.spiritlhl.net/containerd)

基于 containerd + nerdctl 的容器环境一键安装与管理脚本

支持一键安装 containerd 运行时，并开设基于本仓库编译镜像的各种 Linux 容器（提供 SSH 访问），支持 IPv6、端口映射、资源限制等。

## 说明

- 使用 [nerdctl-full](https://github.com/containerd/nerdctl) 安装 containerd + runc + nerdctl + CNI + buildkitd 全套组件
- 使用本仓库自编译的基础镜像，优先从 GHCR 拉取，失败时回退到 GitHub Releases 离线包
- 支持系统：Ubuntu 22.04、Debian 12、Alpine、AlmaLinux 9、RockyLinux 9、OpenEuler 22.03
- 支持架构：amd64、arm64

## 安装 containerd 环境

```bash
bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/containerd/main/containerdinstall.sh)
```

无交互安装统一使用：

```bash
export noninteractive=true
bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/containerd/main/containerdinstall.sh)
```

可配合环境变量覆盖默认值：

```bash
export noninteractive=true
export NEED_DISK_LIMIT=y
export CONTAINERD_POOL_SIZE=20
export CONTAINERD_INSTALL_PATH=/var/lib/containerd
export CONTAINERD_LOOP_FILE=/opt/containerd-pool.img
export CONTAINERD_MAIN_INTERFACE=eth0
export CONTAINERD_IPV6_SUBNET_PREFIX=80
export CONTAINERD_IPV6_SUBNET_INDEX=1
bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/containerd/main/containerdinstall.sh)
```

常用安装环境变量：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| noninteractive | 设为 `true` 时使用默认值跳过交互提示 | unset |
| WITHOUTCDN | 设为 `TRUE` 时禁用 CDN 加速 | unset |
| NEED_DISK_LIMIT | 是否启用 btrfs 磁盘限制，支持 `y/yes/true/1` | n |
| CONTAINERD_INSTALL_PATH | containerd 数据目录 | /var/lib/containerd |
| CONTAINERD_POOL_SIZE | btrfs loop 存储池大小 GB | 20 |
| CONTAINERD_LOOP_FILE | btrfs loop 文件路径 | /opt/containerd-pool.img |
| CONTAINERD_MAIN_INTERFACE | 指定宿主机出口网卡，供 NAT/NDP 使用 | 自动检测 |
| CONTAINERD_IPV6_SUBNET_PREFIX | 从宿主机 IPv6 父网段切出的 CNI 子网前缀 | 80 |
| CONTAINERD_IPV6_SUBNET_INDEX | 从 /64 父网段中选择第几个子网（从 0 开始） | 1 |

## 开设单个容器

```bash
# 下载脚本
wget -q https://raw.githubusercontent.com/oneclickvirt/containerd/main/scripts/onecontainerd.sh
chmod +x onecontainerd.sh

# 用法:
# ./onecontainerd.sh <name> <cpu> <memory_mb> <password> <sshport> <startport> <endport> [ipv6:y/n] [system] [disk_gb]

# 示例: 创建名为 ct1 的 Debian 容器，1核 512MB，SSH端口25000，额外端口34975-35000
./onecontainerd.sh ct1 1 512 "" 25000 34975 35000 n debian 0
```

创建前会检查容器名、端口范围和宿主机端口占用，避免重复映射同一宿主机端口。
密码参数传入空字符串 `""` 时会自动生成高熵随机 root 密码，并写入容器记录文件。

| 参数 | 说明 | 默认值 |
|------|------|--------|
| name | 容器名称 | test |
| cpu | CPU 核数（支持 0.5 等） | 1 |
| memory_mb | 内存限制（MB） | 512 |
| password | root 密码，省略时自动生成随机密码 | 自动生成 |
| sshport | SSH 端口（宿主机→容器 22） | 25000 |
| startport | 公网端口范围起始 | 34975 |
| endport | 公网端口范围结束 | 35000 |
| ipv6 | 是否分配独立 IPv6（y/n） | n |
| system | 镜像系统，支持裸系统名或本仓库已构建版本别名 | debian |
| disk_gb | 磁盘限制 GB（0=不限制） | 0 |

**支持的 system 参数：** `ubuntu` / `debian` / `alpine` / `almalinux` / `rockylinux` / `openeuler`

也支持带版本的常见写法，并会自动归一化到本仓库实际镜像标签：

| 实际镜像 | 支持输入示例 |
|----------|--------------|
| `ubuntu` | `ubuntu22` / `ubuntu22.04` / `ubuntu/22.04` |
| `debian` | `debian12` / `debian/12` |
| `alpine` | `alpine/latest` |
| `almalinux` | `almalinux9` / `alma9` |
| `rockylinux` | `rockylinux9` / `rocky9` |
| `openeuler` | `openeuler22.03` / `openeuler/22.03` |

未列出的版本（例如 `debian11`、`centos7`）没有对应的本仓库镜像，脚本会直接报错并提示可用值，避免创建错误系统或后续下载不存在的镜像。

单容器创建镜像源变量：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| CONTAINERD_IMAGE_REGISTRY | 优先拉取的镜像仓库，脚本会拉取 `<registry>:<system>` 多架构标签 | ghcr.io/oneclickvirt/containerd |
| CONTAINERD_IMAGE_RELEASE_BASE | Releases 离线包基础地址 | https://github.com/oneclickvirt/containerd/releases/download |

## 批量开设容器

```bash
wget -q https://raw.githubusercontent.com/oneclickvirt/containerd/main/scripts/create_containerd.sh
chmod +x create_containerd.sh
./create_containerd.sh
```

交互式脚本，自动递增容器名（ct1, ct2, ...）、SSH 端口、公网端口，容器信息记录到 `ctlog` 文件。批量创建会为每个容器生成 32 位十六进制随机密码。

也可以直接用参数指定批量配置：

```bash
./create_containerd.sh --noninteractive --count 3 --memory 512 --cpu 1 --disk 0 --system debian --ipv6 n
```

无交互批量开设统一使用：

```bash
export noninteractive=true
export CONTAINERD_CREATE_COUNT=1
export CONTAINERD_CONTAINER_MEMORY=512
export CONTAINERD_CONTAINER_CPU=1
export CONTAINERD_CONTAINER_DISK=0
export CONTAINERD_CONTAINER_SYSTEM=debian
export CONTAINERD_CONTAINER_IPV6=n
./create_containerd.sh
```

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

辅助管理脚本：

```bash
bash scripts/containerd_manage.sh stats [container]
bash scripts/containerd_manage.sh snapshot <container> [image]
bash scripts/containerd_manage.sh backup <container> [output.tar]
bash scripts/containerd_manage.sh version-check [system]
```

## 卸载（完整清理）

一键卸载 containerd 全套环境，包括所有容器、镜像、CNI 网络、systemd 服务、二进制文件：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/containerd/main/containerduninstall.sh)
```

脚本会在执行前要求输入 `yes` 确认，操作不可逆。

无交互卸载统一使用：

```bash
export noninteractive=true
bash <(wget -qO- https://raw.githubusercontent.com/oneclickvirt/containerd/main/containerduninstall.sh)
```

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

检查本地镜像和远端 Releases 资产可用性：

```bash
bash scripts/containerd_manage.sh version-check debian
```

## 网络说明

- **IPv4**：通过 `-p` 端口映射（bridge 模式，CNI `containerd-net`）
- **出口网卡**：默认通过路由自动检测，也可用 `CONTAINERD_MAIN_INTERFACE=eth0` 指定，供 IPv4 NAT 和 IPv6 NDP 使用
- **IPv6（独立地址）**：安装时自动检测公网 IPv6 父前缀，默认从宿主机 `/64` 中切出 `/80` CNI 子网，创建 `containerd-ipv6` 网络，并启动 NDP Responder 容器实现 IPv6 NDP 代理
- **DNS 保活**：通过 `check-dns.service` 系统服务持续检测 DNS 可用性

## Stargazers over time

[![Stargazers over time](https://starchart.cc/oneclickvirt/containerd.svg)](https://starchart.cc/oneclickvirt/containerd)
