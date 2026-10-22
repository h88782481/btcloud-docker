#!/bin/bash
# 按数据库、PHP、Nginx、可选插件同步任务的顺序启动，按相反顺序关闭。
set -Eeuo pipefail
trap 'printf "[start] ERROR: 第 %s 行执行失败\n" "$LINENO" >&2' ERR

pids=()
names=()
signals=()

shutdown() {
    local status=$? index result target
    trap - EXIT
    trap '' TERM INT QUIT
    for ((index=${#pids[@]}-1; index>=0; index--)); do
        target="${pids[index]}"
        if [[ "${names[index]}" == PluginSync ]]; then
            target="-${target}"
        fi
        if kill -0 -- "${target}" 2>/dev/null; then
            if ! kill -"${signals[index]}" -- "${target}"; then
                printf '[start] ERROR: 无法通知 %s 退出\n' "${names[index]}" >&2
                status=1
            fi
        fi
        if wait "${pids[index]}"; then
            printf '[start] %s 已停止\n' "${names[index]}"
        else
            result=$?
            printf '[start] %s 退出码: %s\n' "${names[index]}" "${result}" >&2
        fi
    done
    exit "${status}"
}
trap shutdown EXIT
trap 'exit 0' TERM INT QUIT

# 覆盖 Alpine 默认的 skip-networking；监听地址仍由配置限制为 127.0.0.1。
mariadbd --user=mysql --skip-networking=0 &
pids+=("$!")
names+=(MariaDB)
signals+=(TERM)

# 等待数据库接受连接，再执行初始化 SQL；SQL 错误会阻止 Web 服务启动。
mariadb-admin --protocol=socket --user=root --connect-timeout=1 --wait=60 ping
mariadb --protocol=socket --user=root < /run/mysqld/init.sql
rm /run/mysqld/init.sql

php-fpm -F &
pids+=("$!")
names+=(PHP-FPM)
signals+=(QUIT)

nginx -e /dev/stderr -g 'daemon off; worker_shutdown_timeout 600s;' &
pids+=("$!")
names+=(Nginx)
signals+=(QUIT)

if [[ "${PLUGIN_SYNC_ENABLED}" == true ]]; then
    # 单独建立进程组，让关闭信号同时送达循环及其 PHP/sleep 子进程。
    set -m
    (
        set +m
        trap - EXIT TERM INT QUIT
        while true; do
            printf '[plugins] 开始同步插件列表和插件包\n'
            su-exec www-data php /var/www/html/think updateall
            printf '[plugins] 本轮命令结束，%s 秒后再次执行\n' "${PLUGIN_SYNC_INTERVAL}"
            sleep "${PLUGIN_SYNC_INTERVAL}"
        done
    ) &
    pids+=("$!")
    names+=(PluginSync)
    signals+=(TERM)
    set +m
fi

wait -n -p exited_pid "${pids[@]}"
printf '[start] ERROR: 受管进程 %s 意外退出\n' "${exited_pid}" >&2
exit 1
