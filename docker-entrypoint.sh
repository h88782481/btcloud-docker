#!/bin/sh
# btcloud PHP-FPM 容器入口脚本
# 自动修正 /var/www/html 目录权限，确保 PHP-FPM 可以读写

set -e

APP_DIR="/var/www/html"

if [ -d "${APP_DIR}" ]; then
    echo "[entrypoint] APP_DIR = ${APP_DIR}"

    if [ -n "$(ls -A ${APP_DIR} 2>/dev/null)" ]; then
        echo "[entrypoint] Fixing permissions ..."
        chown -R www-data:www-data "${APP_DIR}" || true
        find "${APP_DIR}" -type d -exec chmod 755 {} \; || true
        find "${APP_DIR}" -type f -exec chmod 644 {} \; || true

        for dir in data runtime public/upload public/download public/install; do
            if [ -d "${APP_DIR}/${dir}" ]; then
                chmod -R 775 "${APP_DIR}/${dir}" || true
            fi
        done

        echo "[entrypoint] Permissions fixed."
    else
        echo "[entrypoint] ${APP_DIR} is empty!"
        echo "[entrypoint] Please extract btcloud release package into ./data on host."
    fi
else
    echo "[entrypoint] WARN: ${APP_DIR} not mounted."
fi

exec "$@"
