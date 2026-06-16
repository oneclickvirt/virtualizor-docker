#!/bin/sh

set -e

#H#
#H# virtualizor.sh - A tool to control your Virtualizor container.
#H#
#H# Examples:
#H#   sh virtualizor.sh start
#H#   sh virtualizor.sh reinstall
#H#
#H# Options:
#H#   start       Starts the container
#H#   stop        Stops the container
#H#   install     Creates a container and runs the installation script
#H#   reinstall   Deletes all panel data and installs a fresh panel
#H#   uninstall   Completely removes all traces of virtualizor
#H#   build       Rebuilds the image
#H#   shell       Starts a shell inside the panel's container
#H#   help        Shows this message
#H#
#H# Environment:
#H#   CONFIG_FILE                 Path to config.sh. Defaults to ./config.sh
#H#   PASSWORD                    Root password. If unset, the script prompts.
#H#   VIRTUALIZOR_ASSUME_YES=1    Skip destructive confirmation prompts.

help() {
    awk '/^#H#/ { sub(/^#H# ?/, ""); print }' "$0"
}

log() {
    printf '%s | %s\n' "$1" "$2"
}

error() {
    printf 'ERROR: %s | 错误：%s\n' "$1" "$2" >&2
}

is_uint() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_port() {
    is_uint "$1" || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_email() {
    printf '%s' "${1:-}" | grep -Eq '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
}

project_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
CONFIG_FILE="${CONFIG_FILE:-$project_root/config.sh}"
cmd="${1:-help}"

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        error "Docker is not installed." "未安装 Docker。"
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        error "Docker is not running or current user cannot access it." "Docker 未运行，或当前用户无权限访问 Docker。"
        exit 1
    fi
}

require_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        error "Missing config file: $CONFIG_FILE. Copy example-config.sh to config.sh and edit it first." "缺少配置文件：${CONFIG_FILE}。请先复制 example-config.sh 为 config.sh 并修改。"
        exit 1
    fi

    # shellcheck source=/dev/null
    . "$CONFIG_FILE"

    is_port "${USER_HTTP_PORT:-}" || {
        error "USER_HTTP_PORT must be a TCP port from 1 to 65535." "USER_HTTP_PORT 必须是 1 到 65535 的 TCP 端口。"
        exit 1
    }
    is_port "${USER_HTTPS_PORT:-}" || {
        error "USER_HTTPS_PORT must be a TCP port from 1 to 65535." "USER_HTTPS_PORT 必须是 1 到 65535 的 TCP 端口。"
        exit 1
    }
    is_port "${ADMIN_HTTP_PORT:-}" || {
        error "ADMIN_HTTP_PORT must be a TCP port from 1 to 65535." "ADMIN_HTTP_PORT 必须是 1 到 65535 的 TCP 端口。"
        exit 1
    }
    is_port "${ADMIN_HTTPS_PORT:-}" || {
        error "ADMIN_HTTPS_PORT must be a TCP port from 1 to 65535." "ADMIN_HTTPS_PORT 必须是 1 到 65535 的 TCP 端口。"
        exit 1
    }
    is_uint "${PUID:-}" || {
        error "PUID must be numeric." "PUID 必须是数字。"
        exit 1
    }
    is_uint "${PGID:-}" || {
        error "PGID must be numeric." "PGID 必须是数字。"
        exit 1
    }
    is_email "${EMAIL:-}" || {
        error "EMAIL must be a valid email-like value." "EMAIL 必须是基本合法的邮箱格式。"
        exit 1
    }
    [ -n "${PANEL_DIR:-}" ] || {
        error "PANEL_DIR must not be empty." "PANEL_DIR 不能为空。"
        exit 1
    }
}

read_password() {
    if [ -n "${PASSWORD:-}" ]; then
        REPLY="$PASSWORD"
        return 0
    fi

    if [ -r /dev/tty ] && [ -w /dev/tty ] && tty_settings=$(stty -g </dev/tty 2>/dev/null); then
        trap 'stty "$tty_settings" </dev/tty 2>/dev/null || true' EXIT INT TERM
        printf "Password: " >/dev/tty
        stty -echo </dev/tty 2>/dev/null || true
        IFS= read -r REPLY </dev/tty
        ret=$?
        stty "$tty_settings" </dev/tty 2>/dev/null || true
        trap - EXIT INT TERM
        printf "\n" >/dev/tty
        [ "$ret" -eq 0 ] || return "$ret"
    else
        log "No usable TTY for hidden input; password input may be visible." "当前没有可用于隐藏输入的 TTY，密码输入可能可见。"
        printf "Password: " >&2
        IFS= read -r REPLY || return 1
    fi

    [ -n "$REPLY" ] || {
        error "Password must not be empty." "密码不能为空。"
        return 1
    }
}

confirm_destructive() {
    if [ "${VIRTUALIZOR_ASSUME_YES:-0}" = "1" ] || [ "${2:-}" = "--yes" ] || [ "${2:-}" = "-y" ]; then
        return 0
    fi

    while true; do
        printf "%s [yes/no]: " "$1"
        IFS= read -r yn || exit 1
        case "$yn" in
            yes|YES|Yes|y|Y) return 0 ;;
            no|NO|No|n|N) exit 0 ;;
            *) log "Please answer yes or no." "请输入 yes 或 no。" ;;
        esac
    done
}

create_panel_dir() {
    mkdir -p "$PANEL_DIR"
    if [ ! -d "$PANEL_DIR" ]; then
        error "The directory was not created: $PANEL_DIR" "目录创建失败：$PANEL_DIR"
        exit 1
    fi
}

case "$cmd" in
    help|-h|--help)
        help
        exit 0
        ;;
esac

require_docker

case "$cmd" in
    build)
        docker build \
            --build-arg "S6_OVERLAY_VERSION=${S6_OVERLAY_VERSION:-3.2.3.0}" \
            -t virtualizor "$project_root"
        ;;

    install)
        require_config
        create_panel_dir

        log "Create a root password for the panel." "请为面板创建 root 密码。"
        read_password || exit 1

        docker create \
            --name virtualizor \
            --restart unless-stopped \
            --memory "${VIRTUALIZOR_MEM_LIMIT:-4g}" \
            --cpus "${VIRTUALIZOR_CPUS:-2}" \
            -p "$USER_HTTP_PORT":4082 \
            -p "$USER_HTTPS_PORT":4083 \
            -p "$ADMIN_HTTP_PORT":4084 \
            -p "$ADMIN_HTTPS_PORT":4085 \
            -e PUID="$PUID" \
            -e PGID="$PGID" \
            -e PASSWORD="$REPLY" \
            -e EMAIL="$EMAIL" \
            -e AUTO_RESTART_ON_UNHEALTHY="${AUTO_RESTART_ON_UNHEALTHY:-true}" \
            -v /etc/localtime:/etc/localtime:ro \
            -v "$PANEL_DIR/data/emps":/usr/local/emps \
            -v "$PANEL_DIR/data/init":/etc/init.d \
            -v "$PANEL_DIR/data/virtualizor":/usr/local/virtualizor \
            -v "$PANEL_DIR/data/cron":/etc/cron.d/ \
            virtualizor

        docker start -a virtualizor
        ;;

    reinstall)
        require_config
        confirm_destructive "This will delete all data of the current installation. Do you want to proceed?" "${2:-}"
        log "Stopping container." "正在停止容器。"
        docker stop virtualizor >/dev/null 2>&1 || true
        log "Deleting container." "正在删除容器。"
        docker rm virtualizor >/dev/null 2>&1 || true
        log "Deleting contents of $PANEL_DIR." "正在删除 $PANEL_DIR 的内容。"
        rm -rf -- "$PANEL_DIR"
        log "Installing Virtualizor." "正在重新安装 Virtualizor。"
        sh "$0" install
        ;;

    uninstall)
        require_config
        confirm_destructive "This will delete all data of the current installation. Do you want to proceed?" "${2:-}"
        log "Stopping container." "正在停止容器。"
        docker stop virtualizor >/dev/null 2>&1 || true
        log "Deleting container." "正在删除容器。"
        docker rm virtualizor >/dev/null 2>&1 || true
        log "Deleting contents of $PANEL_DIR." "正在删除 $PANEL_DIR 的内容。"
        rm -rf -- "$PANEL_DIR"
        log "Deleting image." "正在删除镜像。"
        docker rmi virtualizor
        ;;

    start)
        docker start virtualizor
        log "Container has been started." "容器已启动。"
        log "Check its output via: docker logs virtualizor" "可使用 docker logs virtualizor 查看输出。"
        ;;

    stop)
        docker stop virtualizor
        log "Container has been stopped." "容器已停止。"
        ;;

    shell)
        docker exec -it virtualizor bash
        ;;

    *)
        error "Unknown command: $cmd" "未知命令：$cmd"
        help
        exit 1
        ;;
esac
