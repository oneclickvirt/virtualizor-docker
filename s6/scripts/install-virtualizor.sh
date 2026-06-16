#!/usr/bin/with-contenv bash
# shellcheck shell=bash

set -u

FILEREPO="${FILEREPO:-https://files.virtualizor.com}"
EMPS_MIRROR_URL="${EMPS_MIRROR_URL:-https://files.softaculous.com}"
LOG="${VIRTUALIZOR_INSTALL_LOG:-/root/virtualizor.log}"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-200}"
MIN_EMPS_PHP_VERSION="${MIN_EMPS_PHP_VERSION:-7.4}"
ALLOW_EOL_EMPS_PHP="${ALLOW_EOL_EMPS_PHP:-false}"

mkdir -p "$(dirname "$LOG")"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

log() {
    printf '%s | %s\n' "$1" "$2"
}

warn() {
    printf 'WARNING: %s | 警告：%s\n' "$1" "$2"
}

show_log_tail() {
    if [ -f "$LOG" ]; then
        log "Last ${LOG_TAIL_LINES} lines from ${LOG}:" "输出 ${LOG} 最后 ${LOG_TAIL_LINES} 行："
        tail -n "$LOG_TAIL_LINES" "$LOG" || true
    fi
}

fail() {
    printf 'ERROR: %s | 错误：%s\n' "$1" "$2"
    show_log_tail
    exit 1
}

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

is_email() {
    [[ "${1:-}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

detect_emps_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf '64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *) fail "Unsupported EMPS architecture: $(uname -m)" "不支持的 EMPS 架构：$(uname -m)" ;;
    esac
}

validate_env() {
    is_uint "${PUID:-}" || fail "PUID must be a numeric user id." "PUID 必须是数字用户 ID。"
    is_uint "${PGID:-}" || fail "PGID must be a numeric group id." "PGID 必须是数字用户组 ID。"
    is_email "${EMAIL:-}" || fail "EMAIL must be a valid email-like value." "EMAIL 必须是基本合法的邮箱格式。"
}

download() {
    local url="$1"
    local dest="$2"

    log "Downloading ${url}" "正在下载 ${url}"
    curl -fL --retry 3 --retry-delay 5 --connect-timeout 20 --progress-bar -o "$dest" "$url" \
        || fail "Failed to download ${url}." "下载失败：${url}。"
}

stop_emps_services() {
    local ctl

    for ctl in mysqlctl nginxctl fpmctl; do
        if [ -x "/usr/local/emps/bin/${ctl}" ]; then
            "/usr/local/emps/bin/${ctl}" stop || true
        fi
    done
}

find_ioncube_loader() {
    local php_version="$1"
    local php_major="${php_version%%.*}"
    local candidate

    for candidate in \
        "/usr/local/emps/lib/php/ioncube_loader_lin_${php_version}.so" \
        "/usr/local/emps/lib/php/ioncube_loader_lin_${php_major}.so" \
        /usr/local/emps/lib/php/ioncube_loader_lin_*.so; do
        if [ -f "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

build_php_args() {
    local php_bin="/usr/local/emps/bin/php"
    local php_version
    local loader

    [ -x "$php_bin" ] || fail "EMPS PHP binary was not found at ${php_bin}." "未找到 EMPS PHP：${php_bin}。"

    php_version="$("$php_bin" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
    [ -n "$php_version" ] || fail "Unable to detect EMPS PHP version." "无法检测 EMPS PHP 版本。"

    log "Detected EMPS PHP ${php_version}." "检测到 EMPS PHP ${php_version}。"
    "$php_bin" -v || true

    if ! version_ge "$php_version" "$MIN_EMPS_PHP_VERSION"; then
        if [ "$ALLOW_EOL_EMPS_PHP" != "true" ]; then
            fail \
                "EMPS provided PHP ${php_version}, below the minimum ${MIN_EMPS_PHP_VERSION}. Set ALLOW_EOL_EMPS_PHP=true only if you explicitly accept the risk." \
                "EMPS 提供的 PHP ${php_version} 低于最低要求 ${MIN_EMPS_PHP_VERSION}。仅在明确接受风险时设置 ALLOW_EOL_EMPS_PHP=true。"
        fi
        warn "Using EOL EMPS PHP ${php_version} because ALLOW_EOL_EMPS_PHP=true." "由于 ALLOW_EOL_EMPS_PHP=true，继续使用已停止维护的 EMPS PHP ${php_version}。"
    fi

    if loader="$(find_ioncube_loader "$php_version")"; then
        log "Using ionCube loader ${loader}." "使用 ionCube loader：${loader}。"
        PHP_CMD=( "$php_bin" -d "zend_extension=${loader}" )
    else
        warn "No matching ionCube loader was found; running installer with EMPS PHP defaults." "未找到匹配的 ionCube loader，将使用 EMPS PHP 默认配置运行安装器。"
        PHP_CMD=( "$php_bin" )
    fi
}

configure_runtime_users() {
    if getent group emps >/dev/null 2>&1; then
        groupmod -o -g "$PGID" emps || warn "Unable to update emps group id." "无法更新 emps 组 ID。"
    fi
    if id -u emps >/dev/null 2>&1; then
        usermod -o -u "$PUID" emps || warn "Unable to update emps user id." "无法更新 emps 用户 ID。"
    fi
    if getent group mysql >/dev/null 2>&1; then
        groupmod -o -g "$PGID" mysql || warn "Unable to update mysql group id." "无法更新 mysql 组 ID。"
    fi
    if id -u mysql >/dev/null 2>&1; then
        usermod -o -u "$PUID" mysql || warn "Unable to update mysql user id." "无法更新 mysql 用户 ID。"
    fi
    if id -u emps >/dev/null 2>&1; then
        chown -R emps:emps /usr/local/emps/ || warn "Unable to chown /usr/local/emps." "无法修改 /usr/local/emps 权限。"
    fi
}

detect_access_ip() {
    local ip
    local url

    for url in "https://api.ipify.org" "https://softaculous.com/ip.php"; do
        ip="$(curl -fsS --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
        if [ -n "$ip" ]; then
            printf '%s' "$ip"
            return 0
        fi
    done

    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [ -n "$ip" ]; then
        printf '%s' "$ip"
        return 0
    fi

    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
    [ -n "$ip" ] && printf '%s' "$ip"
}

print_install_summary() {
    local ip="$1"

    echo " "
    log "Installation completed." "安装完成。"
    echo "-------------------------------------"
    echo " Installation Completed / 安装完成 "
    echo "-------------------------------------"
    log "Congratulations, Virtualizor has been successfully installed." "恭喜，Virtualizor 已成功安装。"
    echo " "
    # shellcheck disable=SC2016 # PHP source is intentionally single-quoted for the shell.
    "${PHP_CMD[@]}" -r 'define("VIRTUALIZOR", 1); include("/usr/local/virtualizor/universal.php"); echo "API KEY : ".$globals["key"]."\nAPI Password : ".$globals["pass"]."\n";' || warn "Unable to print API credentials." "无法输出 API 凭据。"
    echo " "
    log "Admin login URL:" "管理员登录地址："
    echo "  https://${ip:-SERVER_IP}:4085/"
    echo "  http://${ip:-SERVER_IP}:4084/"
    log "User login URL:" "用户登录地址："
    echo "  https://${ip:-SERVER_IP}:4083/"
    echo "  http://${ip:-SERVER_IP}:4082/"
    echo " "
    log "Use docker logs virtualizor for installer and runtime logs." "可使用 docker logs virtualizor 查看安装与运行日志。"
    log "Thank you for choosing Softaculous Virtualizor." "感谢使用 Softaculous Virtualizor。"
}

main() {
    local arch
    local emps_url
    local phpret
    local ip
    local extra_args=()

    validate_env
    arch="$(detect_emps_arch)"
    emps_url="${EMPS_URL:-${EMPS_MIRROR_URL%/}/emps.php?latest=1&arch=${arch}}"

    log "Welcome to the Softaculous Virtualizor installer." "欢迎使用 Softaculous Virtualizor 安装器。"
    log "Installer log: ${LOG}" "安装日志：${LOG}"

    log "Updating packages." "正在更新软件包。"
    apt-get update || fail "apt-get update failed." "apt-get update 失败。"
    apt-get upgrade -y || fail "apt-get upgrade failed." "apt-get upgrade 失败。"

    stop_emps_services

    log "Preparing Virtualizor directories." "正在准备 Virtualizor 目录。"
    mkdir -p /usr/local/emps /usr/local/virtualizor
    find /usr/local/emps -mindepth 1 -maxdepth 1 -exec rm -rf {} +

    log "Installing PHP, MySQL and web server bundle." "正在安装 PHP、MySQL 和 Web 服务组件。"
    download "$emps_url" /usr/local/virtualizor/EMPS.tar.gz
    tar -xvzf /usr/local/virtualizor/EMPS.tar.gz -C /usr/local/emps \
        || fail "Failed to extract EMPS archive." "解压 EMPS 压缩包失败。"
    rm -f /usr/local/virtualizor/EMPS.tar.gz

    build_php_args

    log "Downloading Virtualizor installer." "正在下载 Virtualizor 安装器。"
    download "${FILEREPO%/}/install.inc" /usr/local/virtualizor/install.php

    if [ -n "${VIRTUALIZOR_INSTALL_ARGS:-}" ]; then
        read -r -a extra_args <<< "$VIRTUALIZOR_INSTALL_ARGS"
    fi

    log "Running Virtualizor master-only installer." "正在运行 Virtualizor 主控节点安装器。"
    "${PHP_CMD[@]}" /usr/local/virtualizor/install.php "email=${EMAIL}" "master=1" "${extra_args[@]}"
    phpret=$?
    rm -f /usr/local/virtualizor/install.php /usr/local/virtualizor/upgrade.php

    if [ "$phpret" != "8" ]; then
        fail "Virtualizor installer exited with code ${phpret}." "Virtualizor 安装器退出码为 ${phpret}。"
    fi

    configure_runtime_users

    log "Starting Virtualizor services." "正在启动 Virtualizor 服务。"
    /etc/init.d/virtualizor restart || fail "Failed to start Virtualizor services." "Virtualizor 服务启动失败。"

    ip="$(detect_access_ip || true)"
    if [ -z "$ip" ]; then
        warn "Unable to detect public IP; using SERVER_IP placeholder in URLs." "无法检测公网 IP，URL 中使用 SERVER_IP 占位。"
    fi

    print_install_summary "$ip"
}

main "$@"
