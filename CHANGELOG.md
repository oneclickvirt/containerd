2026.06.29
- 修复 CI 非交互 smoke test 的 fake `curl` 未模拟 `-o` 下载产物导致单容器创建提前失败的问题；同步 README 和 `version-check` 中默认镜像来源说明，明确当前默认使用 Releases 离线包，`CONTAINERD_IMAGE_REGISTRY` 仅在显式配置时作为回退 registry。

2026.06.15
- 系统参数兼容性补强：单容器、批量创建和 `version-check` 统一支持 `debian12`、`debian/12`、`ubuntu22.04` 等版本别名，未知版本改为明确报错并提示可用值，避免静默回退或下载不存在镜像。

2026.06.03
- CI/CD 基线补强：GitHub Actions 增加 `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24`、job 超时、并发控制，升级 `docker/build-push-action` 到 v6，并改用 `gh` CLI 上传 Releases 资产以移除旧版上传 action
- CI 增加 Ubuntu/Debian/Alpine 容器内非交互 smoke test，覆盖安装、卸载、批量创建、单容器和管理脚本的语法与 help 入口
- 安全忽略规则补强：新增 `.env`、数据库文件、密钥文件、截图、ctlog 和容器信息文件等运行产物忽略
- 批量创建增强：`create_containerd.sh` 新增命令行参数模式，并将默认批量密码从时间 md5 片段升级为高熵随机密码
- 镜像管理调整：`onecontainerd.sh` 改为优先拉取 GHCR/自定义镜像仓库的多架构标签，兼容旧 GHCR 标签，失败后回退到 GitHub Releases 离线包
- 容器创建前增加容器名、参数、端口范围和宿主机端口占用预检，减少运行后失败和端口重复映射
- 安装脚本新增 `CONTAINERD_MAIN_INTERFACE` 指定宿主机出口网卡，并将 IPv6 CNI 子网改为从父前缀稳定切分，支持 `CONTAINERD_IPV6_SUBNET_PREFIX` 和 `CONTAINERD_IPV6_SUBNET_INDEX`
- 新增 `scripts/containerd_manage.sh`，支持容器资源快照查询、镜像快照、容器文件系统备份和镜像版本/远端资产检查
- 安装、批量创建、单容器创建、SSH bash 初始化、Docker entrypoint 与卸载脚本启用 Bash 严格模式，Alpine sh 脚本启用 POSIX `set -eu`，并为最小系统缺少 `shuf`、公网 IP 探测失败、systemd/nftables 尽力配置等路径增加显式降级
- 移除镜像和 SSH 初始化脚本中的 `123456` 默认密码，直接创建容器省略密码时改为自动生成随机密码

2026.06.02
- 统一无交互入口：安装、批量创建、卸载脚本均支持 `export noninteractive=true`，并在无交互模式下使用清晰默认值避免 stdin 阻塞
- 批量创建脚本新增环境变量覆盖：`CONTAINERD_CREATE_COUNT`、`CONTAINERD_CONTAINER_MEMORY`、`CONTAINERD_CONTAINER_CPU`、`CONTAINERD_CONTAINER_DISK`、`CONTAINERD_CONTAINER_SYSTEM`、`CONTAINERD_CONTAINER_IPV6`
- 优化批量创建日志展示，使用一次 shell 字段解析替代每行多次 `awk` 调用，避免不必要的重复外部命令

2026.03.02
- 修复容器创建后未正确配置 NAT 到宿主机公网 IP 的问题：在 containerdinstall.sh 新增 setup_iptables_nat() 函数，显式添加 IPv4 MASQUERADE 和 FORWARD 规则（基于子网而非网桥接口，避免接口未创建时规则失效）
- 修复 adapt_ipv6() 仅配置 sysctl 而缺少 ip6tables FORWARD 规则的问题：新增 ip6tables FORWARD 规则允许 ctn-br1 和 IPv6 子网双向流量
- 新增 persist_iptables_rules() 函数：自动持久化 iptables/ip6tables 规则，Debian/Ubuntu 安装 iptables-persistent 并启用 netfilter-persistent，CentOS 执行 iptables save
- 修复安装时调用顺序：先执行 create_ipv6_network() 写入 IPv6 子网文件，再执行 adapt_ipv6() 读取并添加规则
- 修复 onecontainerd.sh 缺少公网 IP 检测：新增 check_ipv4() 函数，容器创建完成后显示 SSH 连接信息（含公网 IP 和端口）
- 修复 onecontainerd.sh 在部分系统中 CNI 规则未自动建立的问题：容器启动后主动补充 iptables/ip6tables FORWARD 和 MASQUERADE 规则
- 修复 containerduninstall.sh 卸载时不清理 iptables 规则：新增步骤 [5/9] 删除所有由安装脚本添加的 iptables/ip6tables 规则及持久化文件

2026.03.01
- 初始化仓库，对应 oneclickvirt/docker 实现 containerd 版本
- 实现 containerdinstall.sh：一键安装 containerd + runc + nerdctl + CNI + buildkitd（nerdctl-full bundle）
- 实现 scripts/onecontainerd.sh：单个容器开设脚本，支持 ubuntu/debian/alpine/almalinux/rockylinux/openeuler
- 实现 scripts/create_containerd.sh：交互式批量容器开设脚本，记录至 ctlog 日志
- 实现 scripts/ssh_bash.sh：容器内 SSH 初始化（bash 系统，Debian/Ubuntu/RHEL 系）
- 实现 scripts/ssh_sh.sh：容器内 SSH 初始化（sh，Alpine 专用）
- 实现 dockerfiles/ 各系统 Dockerfile + entrypoint 脚本，支持 amd64 和 arm64 双架构
- 实现 .github/workflows/containerd_build.yml：自动构建镜像 tar 并发布到 GitHub Releases
- 支持公网 IPv6 检测，自动创建 containerd-ipv6 CNI 网络，启动 NDP Responder 实现独立 IPv6
- 支持国内 CDN 镜像加速（cdn.spiritlhl.net）
- 支持 lxcfs 挂载（若宿主机安装了 lxcfs，提供容器内真实 /proc 视图）
- 支持磁盘限制参数（需 xfs/btrfs snapshotter 支持 storage-opt）
