# 宝塔面板第三方云端 (btcloud) 单容器镜像: Nginx + PHP-FPM + MariaDB
# 项目地址: https://github.com/flucont/btcloud
# 依赖: PHP >= 8.0 (v3.7+ 使用 ThinkPHP 8.1，需 PHP >= 8.1)、MySQL >= 5.6 (用 MariaDB 实现)
#
# 基础镜像已内置 mbstring / fileinfo / curl 等扩展，且默认启用 opcache，
# 这里只补装应用真正用到的扩展: pdo_mysql (think-orm)、zip (ZipArchive)、gd (登录验证码)
# 三个进程由 start.sh 监管；PHP 连数据库走容器内 127.0.0.1:3306，数据目录挂载在 ./data/mysql

FROM php:8.3-fpm-alpine

LABEL maintainer="btcloud-docker"
LABEL description="Nginx + PHP-FPM + MariaDB single-container image for flucont/btcloud"

# 使用阿里云镜像源加速（如无需可注释掉）
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories

# 系统组件:
# - nginx: 与 php-fpm 同容器运行（站点配置在 /etc/nginx/http.d/default.conf）
# - mariadb / mariadb-client: 内置数据库（数据目录挂载在 ./data/mysql）
# - bash / GNU grep / zip / unzip: 官方 app/script/convert.sh 批量替换域名时用到
#   (BusyBox grep 不支持 --include，BusyBox 没有 zip)
# - jq: 自动更新脚本解析 GitHub Release API
# - su-exec: 自动更新脚本从 root 降权到 www-data 执行
# - tzdata: 时区
RUN apk add --no-cache \
        nginx \
        mariadb \
        mariadb-client \
        bash \
        grep \
        sed \
        zip \
        unzip \
        jq \
        su-exec \
        tzdata

ENV TZ=Asia/Shanghai

# MariaDB 配置: 只监听容器内回环地址，不对外暴露
# 内存参数按低配服务器(1C1G)调优——btcloud 的库只有几 MB，这些缓冲绰绰有余；
# 大内存服务器可按需调大 innodb_buffer_pool_size
RUN { \
        echo '[mysqld]'; \
        echo 'bind-address = 127.0.0.1'; \
        echo 'port = 3306'; \
        echo 'character-set-server = utf8mb4'; \
        echo 'collation-server = utf8mb4_general_ci'; \
        echo 'skip-name-resolve'; \
        echo 'performance_schema = OFF'; \
        echo 'innodb_buffer_pool_size = 64M'; \
        echo 'aria_pagecache_buffer_size = 16M'; \
        echo 'tmp_table_size = 16M'; \
        echo 'max_heap_table_size = 16M'; \
        echo 'max_connections = 30'; \
    } > /etc/my.cnf.d/btcloud.cnf

# PHP 扩展（编译工具链由 docker-php-ext-install 自动临时安装并清理）
RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
        freetype-dev \
        libjpeg-turbo-dev \
        libpng-dev \
        libwebp-dev \
        libzip-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" \
        pdo_mysql \
        zip \
        gd; \
# 显式保留扩展运行所需的动态库，然后清理编译期的 -dev 包
    apk add --no-cache \
        freetype \
        libjpeg-turbo \
        libpng \
        libwebp \
        libzip; \
    apk del --no-network .build-deps

# 自定义 PHP 配置（宝塔插件包较大，需放宽上传和执行限制；
# 上传/下载走磁盘流式处理，memory_limit 256M 足够且对 1G 内存更安全）
RUN { \
        echo 'upload_max_filesize = 1024M'; \
        echo 'post_max_size = 1024M'; \
        echo 'memory_limit = 256M'; \
        echo 'max_execution_time = 600'; \
        echo 'max_input_time = 600'; \
        echo 'date.timezone = Asia/Shanghai'; \
        echo 'expose_php = Off'; \
    } > /usr/local/etc/php/conf.d/btcloud.ini

# OPcache 调优（基础镜像已默认启用 opcache；本应用代码量小，64M 足够）
RUN { \
        echo 'opcache.memory_consumption = 64'; \
        echo 'opcache.interned_strings_buffer = 8'; \
        echo 'opcache.max_accelerated_files = 20000'; \
        echo 'opcache.revalidate_freq = 60'; \
    } > /usr/local/etc/php/conf.d/opcache.ini

# php-fpm 进程管理: 按需拉起 worker，空闲自动回收（低配服务器空闲时几乎不占内存）
RUN { \
        echo '[www]'; \
        echo 'pm = ondemand'; \
        echo 'pm.max_children = 4'; \
        echo 'pm.process_idle_timeout = 30s'; \
        echo 'pm.max_requests = 500'; \
    } > /usr/local/etc/php-fpm.d/zz-btcloud.conf

# 站点配置（覆盖 alpine nginx 自带的 404 stub；compose 里也会 bind-mount 同一文件，方便改完直接重启生效）
COPY nginx.conf /etc/nginx/http.d/default.conf

# 入口脚本（修权限 + 初始化 MariaDB）+ 进程监管脚本 + 自动更新脚本
COPY docker-entrypoint.sh start.sh update-btcloud.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/start.sh /usr/local/bin/update-btcloud.sh

WORKDIR /var/www/html

EXPOSE 80

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["start.sh"]
