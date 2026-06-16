#!/usr/bin/env bash
# shellcheck shell=bash

set -u

AUTO_RESTART_ON_UNHEALTHY="${AUTO_RESTART_ON_UNHEALTHY:-true}"

log() {
    printf '%s | %s\n' "$1" "$2"
}

probe() {
    curl -fsS --max-time 5 "http://127.0.0.1:4084/" >/dev/null 2>&1 \
        || curl -fsS --max-time 5 "http://127.0.0.1:4082/" >/dev/null 2>&1 \
        || curl -kfsS --max-time 5 "https://127.0.0.1:4085/" >/dev/null 2>&1 \
        || curl -kfsS --max-time 5 "https://127.0.0.1:4083/" >/dev/null 2>&1
}

if [ ! -x /etc/init.d/virtualizor ]; then
    log "Virtualizor init script is not installed yet." "尚未安装 Virtualizor init 脚本。"
    exit 1
fi

if probe; then
    exit 0
fi

if [ "$AUTO_RESTART_ON_UNHEALTHY" = "true" ]; then
    log "Virtualizor health probe failed; restarting services once." "Virtualizor 健康检查失败，尝试重启服务一次。"
    /etc/init.d/virtualizor restart >/proc/1/fd/1 2>/proc/1/fd/2 || true
    sleep 5
    if probe; then
        log "Virtualizor recovered after service restart." "Virtualizor 服务重启后恢复。"
        exit 0
    fi
fi

log "Virtualizor health probe failed." "Virtualizor 健康检查失败。"
exit 1
