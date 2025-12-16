#!/bin/bash

################################################################################
# Docker 日志清理脚本
#
# 用途：清理 Docker 容器的日志文件，防止磁盘空间被占满
# 使用方法：
#   ./clean-docker-logs.sh                    # 清理所有容器的日志
#   ./clean-docker-logs.sh <container_name>   # 清理指定容器的日志
#   ./clean-docker-logs.sh --truncate         # 截断日志文件而不是删除
#   ./clean-docker-logs.sh --dry-run          # 预览将要清理的日志
################################################################################

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 默认配置
DRY_RUN=false
TRUNCATE=false
SPECIFIC_CONTAINER=""
VERBOSE=false

# 显示帮助信息
show_help() {
    cat << EOF
Docker 日志清理脚本

使用方法:
    $0 [选项] [容器名称]

选项:
    -h, --help          显示此帮助信息
    -d, --dry-run       预览模式，不实际删除日志
    -t, --truncate      截断日志文件而不是删除（保留文件但清空内容）
    -v, --verbose       详细输出模式
    -a, --all           清理所有容器日志（默认）
    --max-size SIZE     只清理超过指定大小的日志（如 100M, 1G）

示例:
    $0                              # 清理所有容器的日志
    $0 dify-api                     # 清理 dify-api 容器的日志
    $0 --dry-run                    # 预览将要清理的日志
    $0 --truncate                   # 截断所有容器的日志文件
    $0 --max-size 100M              # 只清理超过 100MB 的日志文件

EOF
}

# 打印信息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否有 Docker 权限
check_docker_permission() {
    if ! docker ps >/dev/null 2>&1; then
        print_error "无法访问 Docker。请检查："
        echo "  1. Docker 是否正在运行"
        echo "  2. 当前用户是否有 Docker 权限（可能需要 sudo）"
        exit 1
    fi
}

# 获取容器的日志文件路径
get_log_path() {
    local container_id=$1
    docker inspect --format='{{.LogPath}}' "$container_id" 2>/dev/null
}

# 获取文件大小（人类可读格式）
get_file_size() {
    local file=$1
    if [ -f "$file" ]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            stat -f%z "$file" 2>/dev/null || echo "0"
        else
            # Linux
            stat -c%s "$file" 2>/dev/null || echo "0"
        fi
    else
        echo "0"
    fi
}

# 将字节转换为人类可读格式
bytes_to_human() {
    local bytes=$1
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes}B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1024}")KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}")MB"
    else
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}")GB"
    fi
}

# 清理单个容器的日志
clean_container_log() {
    local container_id=$1
    local container_name=$2
    local log_path

    log_path=$(get_log_path "$container_id")

    if [ -z "$log_path" ] || [ "$log_path" = "<no value>" ]; then
        print_warning "容器 $container_name 没有日志文件"
        return
    fi

    if [ ! -f "$log_path" ]; then
        print_warning "容器 $container_name 的日志文件不存在: $log_path"
        return
    fi

    local file_size
    file_size=$(get_file_size "$log_path")
    local human_size
    human_size=$(bytes_to_human "$file_size")

    if [ "$file_size" -eq 0 ]; then
        [ "$VERBOSE" = true ] && print_info "容器 $container_name 的日志文件已经是空的"
        return
    fi

    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY RUN] 将清理容器 $container_name 的日志 ($human_size): $log_path"
        return
    fi

    print_info "清理容器 $container_name 的日志 ($human_size)..."

    if [ "$TRUNCATE" = true ]; then
        # 截断日志文件（保留文件但清空内容）
        if sudo truncate -s 0 "$log_path" 2>/dev/null; then
            print_success "已截断容器 $container_name 的日志文件 (释放 $human_size)"
            TOTAL_CLEANED=$((TOTAL_CLEANED + file_size))
        else
            print_error "截断容器 $container_name 的日志文件失败"
        fi
    else
        # 删除并重新创建日志文件
        if sudo sh -c "cat /dev/null > '$log_path'" 2>/dev/null; then
            print_success "已清理容器 $container_name 的日志 (释放 $human_size)"
            TOTAL_CLEANED=$((TOTAL_CLEANED + file_size))
        else
            print_error "清理容器 $container_name 的日志失败"
        fi
    fi
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -t|--truncate)
                TRUNCATE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -a|--all)
                SPECIFIC_CONTAINER=""
                shift
                ;;
            --max-size)
                MAX_SIZE=$2
                shift 2
                ;;
            -*)
                print_error "未知选项: $1"
                show_help
                exit 1
                ;;
            *)
                SPECIFIC_CONTAINER=$1
                shift
                ;;
        esac
    done
}

# 主函数
main() {
    local TOTAL_CLEANED=0

    print_info "Docker 日志清理脚本启动"
    echo ""

    # 检查 Docker 权限
    check_docker_permission

    # 获取容器列表
    local containers
    if [ -n "$SPECIFIC_CONTAINER" ]; then
        # 检查指定的容器是否存在
        if ! docker ps -a --format '{{.Names}}' | grep -q "^${SPECIFIC_CONTAINER}$"; then
            print_error "容器 '$SPECIFIC_CONTAINER' 不存在"
            exit 1
        fi
        containers=$(docker ps -a --filter "name=^${SPECIFIC_CONTAINER}$" --format '{{.ID}}:{{.Names}}')
    else
        containers=$(docker ps -a --format '{{.ID}}:{{.Names}}')
    fi

    if [ -z "$containers" ]; then
        print_warning "没有找到任何容器"
        exit 0
    fi

    # 统计信息
    local container_count
    container_count=$(echo "$containers" | wc -l)

    if [ "$DRY_RUN" = true ]; then
        print_warning "运行在预览模式，不会实际清理日志"
        echo ""
    fi

    print_info "找到 $container_count 个容器"
    echo ""

    # 清理每个容器的日志
    while IFS=: read -r container_id container_name; do
        clean_container_log "$container_id" "$container_name"
    done <<< "$containers"

    echo ""
    if [ "$DRY_RUN" = false ]; then
        local human_total
        human_total=$(bytes_to_human "$TOTAL_CLEANED")
        print_success "日志清理完成！共释放空间: $human_total"
    else
        print_info "预览完成"
    fi
}

# 解析参数并执行
parse_args "$@"
main
