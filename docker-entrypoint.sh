#!/bin/sh
# btcloud 容器入口脚本
# 1) 修正 /var/www/html 属主/权限，确保 PHP-FPM (www-data) 可读写
#    (应用会写: 根目录 .env、record.txt、data/、runtime/、public/install/、public/win/)
# 2) 初始化内置 MariaDB: 首次启动初始化数据目录；每次启动生成幂等的
#    init.sql（建库、建用户、把密码同步为环境变量的值），由 mariadbd --init-file 执行
#
# FIX_PERMS 环境变量:
#   auto   (默认) 检测到有不属于 www-data 的文件时才修复
#   always 每次启动都强制修复
#   never  跳过修复

set -e

APP_DIR="/var/www/html"
DB_DIR="/var/lib/mysql"
FIX_PERMS="${FIX_PERMS:-auto}"

MYSQL_DATABASE="${MYSQL_DATABASE:-btcloud}"
MYSQL_USER="${MYSQL_USER:-btcloud}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"

# ---------- btcloud 源码权限 ----------

fix_perms() {
    echo "[entrypoint] Fixing owner/permissions of ${APP_DIR} ..."
    chown -R www-data:www-data "${APP_DIR}"
    find "${APP_DIR}" -type d ! -perm 755 -exec chmod 755 {} +
    find "${APP_DIR}" -type f ! -perm 644 -exec chmod 644 {} +
    echo "[entrypoint] Permissions fixed."
}

if [ "${FIX_PERMS}" != "never" ]; then
    if [ -z "$(ls -A "${APP_DIR}" 2>/dev/null)" ]; then
        echo "[entrypoint] ${APP_DIR} is empty!"
        echo "[entrypoint] Please extract btcloud release package into ./data/btcloud on host."
    elif [ "${FIX_PERMS}" = "always" ] \
        || [ -n "$(find "${APP_DIR}" ! -user www-data -print -quit 2>/dev/null)" ]; then
        fix_perms
    else
        echo "[entrypoint] Permissions OK, skip fixing."
    fi
fi

# ---------- MariaDB 初始化 ----------

mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld

if [ ! -d "${DB_DIR}/mysql" ]; then
    echo "[entrypoint] Initializing MariaDB data directory in ${DB_DIR} ..."
    chown -R mysql:mysql "${DB_DIR}"
    mariadb-install-db --user=mysql --datadir="${DB_DIR}" \
        --skip-test-db --auth-root-authentication-method=socket >/dev/null
    echo "[entrypoint] MariaDB data directory initialized."
elif [ -n "$(find "${DB_DIR}" -maxdepth 1 ! -user mysql -print -quit 2>/dev/null)" ]; then
    echo "[entrypoint] Fixing owner of ${DB_DIR} ..."
    chown -R mysql:mysql "${DB_DIR}"
fi

if [ -z "${MYSQL_PASSWORD}" ] || [ "${MYSQL_PASSWORD}" = "ChangeMe_btcloud" ]; then
    echo "[entrypoint] WARN: MYSQL_PASSWORD 未设置或仍是默认值，请在 docker-compose.yml 里修改！"
fi

# 生成启动初始化 SQL（幂等）: 建库 + 建用户 + 密码与环境变量保持一致
ESC_PWD="$(printf '%s' "${MYSQL_PASSWORD}" | sed "s/'/''/g")"
{
    echo "CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    if [ -n "${MYSQL_PASSWORD}" ]; then
        for h in 127.0.0.1 localhost; do
            echo "CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'${h}' IDENTIFIED BY '${ESC_PWD}';"
            echo "ALTER USER '${MYSQL_USER}'@'${h}' IDENTIFIED BY '${ESC_PWD}';"
            echo "GRANT ALL PRIVILEGES ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'${h}';"
        done
        echo "FLUSH PRIVILEGES;"
    fi
} > /run/mysqld/init.sql
chown mysql:mysql /run/mysqld/init.sql
chmod 600 /run/mysqld/init.sql

exec "$@"
