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
