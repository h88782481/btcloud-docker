#!/bin/bash
# 在同一容器内同时运行 MariaDB、php-fpm 和 nginx：
# - 任一进程退出，整个容器退出，交给 compose 的 restart 策略重新拉起
# - 收到停止信号时优雅退出：php-fpm/nginx 用 SIGQUIT，MariaDB 用 SIGTERM
# - AUTO_UPDATE=true 时，后台定时执行 update-btcloud.sh（检查新版 Release 并自动升级）

set -u

# init.sql 由 docker-entrypoint.sh 生成（幂等建库建用户/同步密码）
mariadbd --user=mysql --init-file=/run/mysqld/init.sql &
DB_PID=$!

php-fpm -F &
FPM_PID=$!

nginx -g 'daemon off;' &
NGINX_PID=$!

# 自动更新循环（disown 后不影响下面的 wait -n；更新失败不影响站点运行）
if [ "${AUTO_UPDATE:-false}" = "true" ]; then
    UPDATE_INTERVAL="${UPDATE_INTERVAL:-86400}"
    echo "[start] AUTO_UPDATE 已开启，每 ${UPDATE_INTERVAL}s 检查一次 btcloud 新版本"
    (
        sleep 10
        while true; do
            update-btcloud.sh || true
            sleep "${UPDATE_INTERVAL}"
        done
    ) &
    disown
fi

shutdown() {
    kill -QUIT "${FPM_PID}" "${NGINX_PID}" 2>/dev/null || true
    kill -TERM "${DB_PID}" 2>/dev/null || true
}
trap shutdown TERM INT QUIT

# 等待任意一个先退出（收到停止信号时也会返回）
RC=0
wait -n || RC=$?

# 通知其余进程退出，并等全部收尾
shutdown
wait "${FPM_PID}" 2>/dev/null || true
wait "${NGINX_PID}" 2>/dev/null || true
wait "${DB_PID}" 2>/dev/null || true

exit "${RC}"
