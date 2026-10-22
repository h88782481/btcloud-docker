# PHP 保持 8.3 系列，跟随该标签更新补丁版本；btcloud 版本由 Compose 指定。
FROM php:8.3-fpm-alpine AS base

FROM base AS release
RUN apk add --no-cache curl jq unzip
ARG BTCLOUD_RELEASE_TAG

# 只获取指定 tag；安装包必须唯一，且源码直接位于 ZIP 根目录。
RUN set -eu; \
    : "${BTCLOUD_RELEASE_TAG:?请在 docker-compose.yml 中填写 BTCLOUD_RELEASE_TAG}"; \
    tag_uri="$(jq -rn --arg tag "${BTCLOUD_RELEASE_TAG}" '$tag | @uri')"; \
    curl -fsSL --connect-timeout 10 --max-time 60 \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/flucont/btcloud/releases/tags/${tag_uri}" \
        -o /tmp/release.json; \
    zip_url="$(jq -er '[.assets[] | select(.name | endswith(".zip"))] | if length == 1 then .[0].browser_download_url else error("Release 必须包含且仅包含一个 ZIP 安装包") end' /tmp/release.json)"; \
    curl -fSL --connect-timeout 10 --max-time 3600 \
        "${zip_url}" -o /tmp/release.zip; \
    mkdir -p /opt/btcloud; \
    unzip -q /tmp/release.zip -d /opt/btcloud; \
    for file in think public/index.php app/script/convert.sh; do \
        if [ ! -f "/opt/btcloud/${file}" ]; then \
            printf '安装包结构错误: 缺少 %s\n' "${file}" >&2; exit 1; \
        fi; \
    done; \
    test -d /opt/btcloud/data; \
    printf '%s\n' "${BTCLOUD_RELEASE_TAG}" > /opt/btcloud-release-tag; \
    rm /tmp/release.json /tmp/release.zip

FROM base
ARG BTCLOUD_RELEASE_TAG
LABEL org.opencontainers.image.title="btcloud-docker"
LABEL org.opencontainers.image.version="${BTCLOUD_RELEASE_TAG}"

RUN apk add --no-cache \
        nginx mariadb mariadb-client bash grep sed zip unzip su-exec tzdata
ENV TZ=Asia/Shanghai

RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
        freetype-dev libjpeg-turbo-dev libpng-dev libwebp-dev libzip-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" pdo_mysql zip gd opcache; \
    apk add --no-cache freetype libjpeg-turbo libpng libwebp libzip; \
    apk del --no-network .build-deps

RUN printf '%s\n' \
        '[mysqld]' \
        'bind-address = 127.0.0.1' \
        'port = 3306' \
        'character-set-server = utf8mb4' \
        'collation-server = utf8mb4_general_ci' \
        'skip-name-resolve' \
        'performance_schema = OFF' \
        'innodb_buffer_pool_size = 64M' \
        'aria_pagecache_buffer_size = 16M' \
        'tmp_table_size = 16M' \
        'max_heap_table_size = 16M' \
        'max_connections = 30' \
        > /etc/my.cnf.d/btcloud.cnf

RUN printf '%s\n' \
        'upload_max_filesize = 1024M' \
        'post_max_size = 1056M' \
        'memory_limit = 256M' \
        'max_execution_time = 600' \
        'max_input_time = 600' \
        'date.timezone = Asia/Shanghai' \
        'expose_php = Off' \
        'opcache.memory_consumption = 64' \
        'opcache.interned_strings_buffer = 8' \
        'opcache.max_accelerated_files = 20000' \
        'opcache.validate_timestamps = 1' \
        'opcache.revalidate_freq = 2' \
        > /usr/local/etc/php/conf.d/btcloud.ini

# PHP-FPM 按需启动，限制同时处理的请求数。
RUN printf '%s\n' \
        '[www]' \
        'pm = ondemand' \
        'pm.max_children = 2' \
        'pm.process_idle_timeout = 30s' \
        'pm.max_requests = 500' \
        'request_terminate_timeout = 600s' \
        > /usr/local/etc/php-fpm.d/zz-btcloud.conf

COPY --from=release /opt/btcloud /opt/btcloud
COPY --from=release /opt/btcloud-release-tag /opt/btcloud-release-tag
COPY nginx.conf /etc/nginx/http.d/default.conf
COPY docker-entrypoint.sh start.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/start.sh

WORKDIR /var/www/html
EXPOSE 80
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["start.sh"]
