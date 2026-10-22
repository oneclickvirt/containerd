# containerd

[![Hits](https://hits.spiritlhl.net/containerd.svg)](https://hits.spiritlhl.net/containerd)

基于 containerd + nerdctl 的容器环境一键安装与管理脚本

支持一键安装 containerd 运行时，并开设基于本仓库编译镜像的各种 Linux 容器（提供 SSH 访问），支持 IPv6、端口映射、资源限制等。

## 更新

[更新日志](CHANGELOG.md)

## 说明文档

国内(China Docs)：

[https://virt.spiritlhl.net/guide/containerd/containerd_precheck.html](https://virt.spiritlhl.net/guide/containerd/containerd_precheck.html)

国际(English Docs)：

[https://www.spiritlhl.net/en/guide/containerd/containerd_precheck.html](https://www.spiritlhl.net/en/guide/containerd/containerd_precheck.html)

说明文档中 containerd 分区内容

## 说明

- 使用 [nerdctl-full](https://github.com/containerd/nerdctl) 安装 containerd + runc + nerdctl + CNI + buildkitd 全套组件
- 使用本仓库自编译的基础镜像，默认从 GitHub Releases 离线包加载；如配置 `CONTAINERD_IMAGE_REGISTRY`，则在离线包不可用时回退尝试该 registry
- 支持系统：Ubuntu 22.04、Debian 12、Alpine、AlmaLinux 9、RockyLinux 9、OpenEuler 22.03
- 支持架构：amd64、arm64

## Stargazers over time

[![Stargazers over time](https://starchart.cc/oneclickvirt/containerd.svg)](https://starchart.cc/oneclickvirt/containerd)
