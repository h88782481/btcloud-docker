#!/bin/bash
# 服务启动前部署镜像中的指定 Release，并准备数据库初始化 SQL。
set -Eeuo pipefail
trap 'printf "[entrypoint] ERROR: 第 %s 行执行失败\n" "$LINENO" >&2' ERR

APP_DIR=/var/www/html
DB_DIR=/var/lib/mysql
RELEASE_DIR=/opt/btcloud
MARKER="${APP_DIR}/data/.release-tag"
DEPLOYING="${APP_DIR}/.deployment-in-progress"

fail() {
    printf '[entrypoint] ERROR: %s\n' "$*" >&2
    exit 1
}

: "${BTCLOUD_DOMAIN:?必须配置 BTCLOUD_DOMAIN}"
: "${MYSQL_DATABASE:?必须配置 MYSQL_DATABASE}"
: "${MYSQL_USER:?必须配置 MYSQL_USER}"
: "${MYSQL_PASSWORD:?必须配置 MYSQL_PASSWORD}"
: "${PLUGIN_SYNC_ENABLED:?必须配置 PLUGIN_SYNC_ENABLED}"

case "${PLUGIN_SYNC_ENABLED}" in
    true)
        [[ "${PLUGIN_SYNC_INTERVAL:?必须配置 PLUGIN_SYNC_INTERVAL}" =~ ^[1-9][0-9]*$ ]] \
            || fail 'PLUGIN_SYNC_INTERVAL 必须是正整数秒数'
        ;;
    false) ;;
    *) fail 'PLUGIN_SYNC_ENABLED 必须是 true 或 false' ;;
esac

[[ "${BTCLOUD_DOMAIN}" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] \
    || fail 'BTCLOUD_DOMAIN 必须是 http(s)://域名，可带端口，不能带路径或末尾斜杠'
[[ "${BTCLOUD_DOMAIN}" != *example.com* ]] || fail '请设置实际站点域名'
[[ "${MYSQL_DATABASE}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,63}$ ]] || fail 'MYSQL_DATABASE 格式不正确'
[[ "${MYSQL_USER}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,63}$ ]] || fail 'MYSQL_USER 格式不正确'
[[ "${MYSQL_USER}" != root ]] || fail '应用数据库用户不能使用 root'
case "${MYSQL_DATABASE}" in
    mysql|information_schema|performance_schema|sys) fail '不能使用数据库系统库' ;;
esac
[[ "${MYSQL_PASSWORD}" != ChangeMe_btcloud ]] || fail '请替换默认数据库密码'
[[ ! -e "${DEPLOYING}" ]] || fail '上次部署未完成，请按 README 恢复或处理后再启动'

# 仅在首次部署或 Release tag 改变时覆盖源码；data 和已有 .env 保留。
release_tag="$(cat /opt/btcloud-release-tag)"
deploy=false
if [[ ! -f "${MARKER}" ]] || [[ "$(cat "${MARKER}")" != "${release_tag}" ]]; then
    deploy=true
    printf '[entrypoint] 部署 btcloud Release %s\n' "${release_tag}"
    printf '%s\n' "${release_tag}" > "${DEPLOYING}"
    shopt -s dotglob
    for source in "${RELEASE_DIR}"/*; do
        name="${source##*/}"
        if [[ "${name}" == data && -d "${APP_DIR}/data" ]] \
            || [[ "${name}" == .env && -f "${APP_DIR}/.env" ]]; then
            continue
        fi
        cp -a "${source}" "${APP_DIR}/"
    done
fi

# 只修改不符合要求的文件；保留可执行位，.env 单独限制为 600。
find "${APP_DIR}" \( ! -user www-data -o ! -group www-data \) -exec chown www-data:www-data {} +
find "${APP_DIR}" -type d ! -perm 755 -exec chmod 755 {} +
find "${APP_DIR}" -type f ! -name .env \
    \( ! -perm -644 -o -perm -020 -o -perm -002 \) -exec chmod u+rw,go+r,go-w {} +
find "${APP_DIR}" -type f -name .env ! -perm 600 -exec chmod 600 {} +

if [[ "${deploy}" == true ]]; then
    (
        cd "${APP_DIR}/app/script"
        su-exec www-data bash ./convert.sh "${APP_DIR}/" "${BTCLOUD_DOMAIN}"
    )
    su-exec www-data cp /opt/btcloud-release-tag "${MARKER}"
    rm "${DEPLOYING}"
    printf '[entrypoint] 部署完成: %s\n' "${release_tag}"
fi

mkdir -p /run/mysqld
chown mysql:mysql /run/mysqld
find "${DB_DIR}" \( ! -user mysql -o ! -group mysql \) -exec chown mysql:mysql {} +
if [[ ! -d "${DB_DIR}/mysql" ]]; then
    mariadb-install-db --user=mysql --datadir="${DB_DIR}" \
        --skip-test-db --auth-root-authentication-method=socket
fi

# 使用 MariaDB mysql_native_password 哈希，密码中的引号、反斜杠和换行不进入 SQL。
password_hash="$(php -r 'echo "*", strtoupper(sha1(sha1(getenv("MYSQL_PASSWORD"), true)));')"
umask 077
{
    printf 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;\n' "${MYSQL_DATABASE}"
    for host in 127.0.0.1 localhost; do
        printf "CREATE USER IF NOT EXISTS '%s'@'%s' IDENTIFIED BY PASSWORD '%s';\n" "${MYSQL_USER}" "${host}" "${password_hash}"
        printf "ALTER USER '%s'@'%s' IDENTIFIED BY PASSWORD '%s';\n" "${MYSQL_USER}" "${host}" "${password_hash}"
        printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%s';\n" "${MYSQL_DATABASE}" "${MYSQL_USER}" "${host}"
    done
} > /run/mysqld/init.sql
umask 022

exec "$@"
