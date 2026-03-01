#!/bin/bash

# Containerd 测试和验证脚本
# 用途: 验证 Containerd 环境的安装和功能
# 用法: bash test.sh [操作]

# =============== 颜色输出函数 ===============
_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }

# =============== 配置 ===============
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_CONTAINER_NAME="containerd-test-$$"
TEST_LOG="/tmp/containerd-test-$$.log"

# =============== 日志记录 ===============
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$TEST_LOG"
}

# =============== 检查环境 ===============
check_environment() {
    _blue "检查 Containerd 环境..."
    
    local failed=0
    
    # 检查 ctr 命令
    if command -v ctr >/dev/null 2>&1; then
        _green "✓ ctr 命令可用"
        log "✓ ctr 版本: $(ctr version 2>/dev/null | grep -i version | head -1)"
    else
        _red "✗ ctr 命令不可用"
        failed=$((failed + 1))
    fi
    
    # 检查 containerd 服务
    if pgrep -x containerd >/dev/null 2>&1; then
        _green "✓ containerd 进程运行中"
        log "✓ containerd 进程运行中"
    else
        _yellow "⚠ containerd 进程未运行"
        log "⚠ containerd 进程未运行"
    fi
    
    # 检查 runc
    if command -v runc >/dev/null 2>&1; then
        _green "✓ runc 可用"
        log "✓ runc 版本: $(runc --version | head -1)"
    else
        _yellow "⚠ runc 不可用"
        log "⚠ runc 不可用"
    fi
    
    # 检查 containerd 配置
    if [ -f /etc/containerd/config.toml ]; then
        _green "✓ 配置文件存在: /etc/containerd/config.toml"
        log "✓ 配置文件存在"
    else
        _yellow "⚠ 配置文件不存在"
        log "⚠ 配置文件不存在"
    fi
    
    return $failed
}

# =============== 测试镜像操作 ===============
test_image_operations() {
    _blue "测试镜像操作..."
    
    log "开始测试镜像操作"
    
    # 拉取镜像
    _yellow "  拉取镜像 alpine:latest..."
    if ctr images pull docker.io/library/alpine:latest >/dev/null 2>&1; then
        _green "  ✓ 镜像拉取成功"
        log "✓ 镜像拉取成功"
    else
        _yellow "  ⚠ 镜像拉取失败（可能是网络问题）"
        log "⚠ 镜像拉取失败"
        return 1
    fi
    
    # 列出镜像
    _yellow "  列出所有镜像..."
    if ctr images ls 2>/dev/null | grep -q alpine; then
        _green "  ✓ 镜像列表查询成功"
        log "✓ 镜像列表查询成功"
    else
        _red "  ✗ 无法找到拉取的镜像"
        log "✗ 无法找到拉取的镜像"
        return 1
    fi
    
    return 0
}

# =============== 测试容器创建和运行 ===============
test_container_creation() {
    _blue "测试容器创建和运行..."
    
    log "开始测试容器创建: $TEST_CONTAINER_NAME"
    
    # 创建容器
    _yellow "  创建容器..."
    if ctr run -d docker.io/library/alpine:latest "$TEST_CONTAINER_NAME" sleep 3600 >/dev/null 2>&1; then
        _green "  ✓ 容器创建成功"
        log "✓ 容器创建成功"
    else
        _red "  ✗ 容器创建失败"
        log "✗ 容器创建失败"
        return 1
    fi
    
    # 检查容器是否运行
    sleep 1
    _yellow "  检查容器状态..."
    if ctr containers ls 2>/dev/null | grep -q "$TEST_CONTAINER_NAME"; then
        _green "  ✓ 容器已注册"
        log "✓ 容器已注册"
    else
        _red "  ✗ 容器未注册"
        log "✗ 容器未注册"
        return 1
    fi
    
    return 0
}

# =============== 清理测试环境 ===============
cleanup_test_environment() {
    _blue "清理测试环境..."
    
    log "开始清理测试容器: $TEST_CONTAINER_NAME"
    
    # 删除容器任务
    _yellow "  删除容器任务..."
    ctr tasks kill "$TEST_CONTAINER_NAME" 2>/dev/null || true
    sleep 1
    
    # 删除容器
    _yellow "  删除容器..."
    if ctr containers delete "$TEST_CONTAINER_NAME" 2>/dev/null; then
        _green "  ✓ 容器已删除"
        log "✓ 容器已删除"
    else
        _yellow "  ⚠ 容器删除失败或已删除"
        log "⚠ 容器删除失败或已删除"
    fi
    
    # 验证删除
    if ! ctr containers ls 2>/dev/null | grep -q "$TEST_CONTAINER_NAME"; then
        _green "✓ 测试环境已完全清理"
        log "✓ 测试环境已完全清理"
        return 0
    else
        _yellow "⚠ 容器清理可能不完整"
        log "⚠ 容器清理可能不完整"
        return 1
    fi
}

# =============== 完整测试流程 ===============
run_full_test() {
    _blue "============================================"
    _blue "  Containerd 完整测试"
    _blue "============================================"
    echo
    
    log "开始 Containerd 完整测试"
    
    # 检查环境
    if ! check_environment; then
        _red "环境检查失败"
        return 1
    fi
    
    echo
    
    # 测试镜像操作
    if ! test_image_operations; then
        _yellow "镜像操作测试失败，跳过容器测试"
        return 1
    fi
    
    echo
    
    # 测试容器创建
    if ! test_container_creation; then
        _yellow "容器创建测试失败，继续清理..."
        cleanup_test_environment
        return 1
    fi
    
    echo
    
    # 清理环境
    cleanup_test_environment
    
    echo
    _green "============================================"
    _green "✓ 测试完成！"
    _green "============================================"
    log "测试完成"
    
    # 显示日志位置
    _blue "详细日志: $TEST_LOG"
}

# =============== 帮助信息 ===============
show_help() {
    cat << EOF
Containerd 测试脚本

用法: bash test.sh [操作]

操作:
    check       检查 Containerd 环境
    test        运行完整测试
    cleanup     清理测试环境
    help        显示此帮助信息

EOF
}

# =============== 主程序 ===============
main() {
    local operation="${1:-test}"
    
    case "$operation" in
        check)
            check_environment
            ;;
        test)
            run_full_test
            ;;
        cleanup)
            cleanup_test_environment
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            _red "未知操作: $operation"
            show_help
            exit 1
            ;;
    esac
}

# 执行主程序
main "$@"
