# 宝塔面板第三方云端 (btcloud) PHP-FPM 镜像
# 项目地址: https://github.com/flucont/btcloud
# 依赖: PHP >= 8.0 (v3.7+ 使用 ThinkPHP 8.1，需 PHP >= 8.1)

FROM php:8.2-fpm-alpine

LABEL maintainer="btcloud-docker"
LABEL description="Dockerfile for flucont/btcloud (Baota Panel Third-party Cloud)"

# 使用阿里云镜像源加速（如无需可注释掉）
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories

# 安装系统依赖
RUN apk add --no-cache \
        libzip-dev \
        zip \
        unzip \
        curl \
        icu-dev \
        oniguruma-dev \
        freetype-dev \
        libjpeg-turbo-dev \
        libpng-dev \
        libwebp-dev \
        libxml2-dev \
        tzdata \
        bash \
        shadow \
        grep \
        sed

# 设置时区
ENV TZ=Asia/Shanghai
RUN cp /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo "${TZ}" > /etc/timezone

# 安装 PHP 扩展
# - pdo_mysql / mysqli: 数据库
# - mbstring: 多字节字符串
# - zip: ZipArchive (必需)
# - fileinfo: 文件类型检测 (必需)
# - gd: 图像处理
# - opcache: 性能加速
# - bcmath: 高精度运算
# - intl: 国际化
# - exif: 图像元信息
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j"$(nproc)" \
        pdo_mysql \
        mysqli \
        mbstring \
        zip \
        fileinfo \
        gd \
        opcache \
        bcmath \
        intl \
        exif

# 安装 Composer（release 包无需，但兼容源码包场景）
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1

# 自定义 PHP 配置（宝塔插件包较大，需放宽上传和执行限制）
RUN { \
        echo 'upload_max_filesize = 1024M'; \
        echo 'post_max_size = 1024M'; \
        echo 'memory_limit = 512M'; \
        echo 'max_execution_time = 600'; \
        echo 'max_input_time = 600'; \
        echo 'date.timezone = Asia/Shanghai'; \
        echo 'expose_php = Off'; \
    } > /usr/local/etc/php/conf.d/btcloud.ini

# OPcache 配置
RUN { \
        echo 'opcache.enable = 1'; \
        echo 'opcache.enable_cli = 0'; \
        echo 'opcache.memory_consumption = 128'; \
        echo 'opcache.interned_strings_buffer = 16'; \
        echo 'opcache.max_accelerated_files = 20000'; \
        echo 'opcache.revalidate_freq = 60'; \
        echo 'opcache.fast_shutdown = 1'; \
    } > /usr/local/etc/php/conf.d/opcache.ini

# 复制入口脚本
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /var/www/html

EXPOSE 9000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
