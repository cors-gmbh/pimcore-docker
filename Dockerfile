ARG PHP_VERSION="8.4"
ARG ALPINE_VERSION=3.24

# All variants (fpm, cli, slim, debug, supervisord, blackfire) are built on the
# same php:*-fpm-alpine base so they share every layer up to the variant-specific
# one. The fpm image ships the php CLI binary as well, so there is no need for a
# separate php:*-cli base.
#
# Layer order, from bottom to top:
#   1. runtime system packages (imagemagick, ghostscript, ffmpeg, fonts, ...)
#   2. PHP extensions, compiled with a temporary build-deps set that is removed
#      again in the same layer; only the actually needed shared libraries stay
#   3. composer, scripts, php.ini              -> cors_php_base   (= *-slim images)
#   4. LibreOffice                             -> cors_php_full   (= regular images)

FROM php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION} AS cors_php_base

ARG PHP_VERSION
ARG ALPINE_VERSION

SHELL ["/bin/sh", "-eo", "pipefail", "-c"]

ENV TIMEZONE=Europe/Vienna

# 1. runtime packages
RUN set -eux; \
    apk update && apk upgrade && apk add --no-cache \
      apk-tools curl wget unzip git fcgi tzdata \
      musl-locales icu-data-full \
      ttf-dejavu ttf-droid ttf-freefont ttf-liberation \
      imagemagick ghostscript graphviz ffmpeg poppler-utils exiftool \
      pngcrush jpegoptim zopfli libwebp-tools \
      libjpeg libxpm libavif libheif librsvg libwmf lcms2 openblas; \
    cp /usr/share/zoneinfo/${TIMEZONE} /etc/localtime; \
    echo "${TIMEZONE}" > /etc/timezone; \
    apk del tzdata; \
    rm -rf /var/cache/apk/*

# 2. PHP extensions
RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
      $PHPIZE_DEPS linux-headers \
      icu-dev oniguruma-dev libxml2-dev libxslt-dev libzip-dev bzip2-dev openssl-dev \
      freetype-dev libpng-dev libjpeg-turbo-dev libwebp-dev libxpm-dev \
      imagemagick-dev rabbitmq-c-dev; \
    \
    if [ "$(php -r 'echo PHP_VERSION_ID;')" -ge 80500 ]; then \
      # no PECL release supports PHP 8.5 yet, build from git
      git clone --depth 1 https://github.com/Imagick/imagick.git /tmp/imagick; \
      cd /tmp/imagick && phpize && ./configure && make -j"$(nproc)" && make install; \
      cd / && rm -rf /tmp/imagick; \
    else \
      pecl install imagick; \
    fi; \
    docker-php-ext-enable imagick; \
    \
    PHP_EXT="intl mysqli bcmath bz2 soap xsl pdo pdo_mysql exif zip sockets pcntl"; \
    php -r 'exit(extension_loaded("mbstring") ? 0 : 1);' || PHP_EXT="$PHP_EXT mbstring"; \
    php -r 'exit(extension_loaded("fileinfo") ? 0 : 1);' || PHP_EXT="$PHP_EXT fileinfo"; \
    php -r 'exit(extension_loaded("Zend OPcache") ? 0 : 1);' || PHP_EXT="$PHP_EXT opcache"; \
    docker-php-ext-configure gd --enable-gd --with-freetype --with-jpeg --with-webp --with-xpm; \
    docker-php-ext-install -j"$(nproc)" $PHP_EXT gd; \
    \
    pecl install apcu redis; \
    pecl install https://pecl.php.net/get/amqp-2.2.0.tgz; \
    docker-php-ext-enable redis apcu amqp; \
    \
    # keep only the shared libraries the extensions actually link against, then
    # drop all -dev packages and compilers (same approach as the official php image)
    runDeps="$( \
      scanelf --needed --nobanner --format '%n#p' --recursive /usr/local/lib/php/extensions \
        | tr ',' '\n' | sort -u \
        | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache --virtual .cors-php-rundeps $runDeps; \
    apk del --no-network .build-deps; \
    \
    docker-php-source delete; \
    rm -rf /tmp/pear /tmp/* /usr/local/lib/php/doc /usr/local/lib/php/test /var/cache/apk/*; \
    php -m

# 3. composer, helper scripts, config
ENV COMPOSER_ALLOW_SUPERUSER=1
ENV COMPOSER_MEMORY_LIMIT=-1
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

RUN mkdir -p /usr/local/var/log/php7/ /usr/local/var/run/

WORKDIR /var/www/html

COPY --chmod=755 php/docker-entrypoint.sh    /usr/local/bin/docker-entrypoint
COPY --chmod=755 php/docker-migrate.sh       /usr/local/bin/docker-migrate
COPY --chmod=755 php/docker-install.sh       /usr/local/bin/install
COPY --chmod=755 php/docker-wait.sh          /usr/local/bin/wait
COPY --chmod=755 php/docker-wait-db.sh       /usr/local/bin/wait_db
COPY --chmod=755 php/docker-wait-pimcore.sh  /usr/local/bin/wait_pimcore
COPY --chmod=755 php/docker-healthcheck.sh   /usr/local/bin/health
COPY --chmod=755 php/docker-readiness.sh     /usr/local/bin/readiness
COPY --chmod=755 php/docker-status.sh        /usr/local/bin/status

COPY fpm/php.ini             /usr/local/etc/php/php.ini
COPY fpm/php-config.conf     /usr/local/etc/php-fpm.conf
COPY fpm/php-pool-config.conf /usr/local/etc/php-fpm.d/www.conf

ENTRYPOINT ["docker-entrypoint"]

# 4. LibreOffice (document -> PDF conversion in Pimcore). Only the modules
# needed for headless conversion; base/math/draw/gtk/postgres connector are left out.
FROM cors_php_base AS cors_php_full

RUN set -eux; \
    apk add --no-cache \
      libreoffice-common libreoffice-writer libreoffice-calc libreoffice-impress libreoffice-lang-en_us; \
    rm -rf /var/cache/apk/*

#
# final images: only ENTRYPOINT/CMD differ, so they add no layers
#

FROM cors_php_full AS cors_php_fpm
CMD ["php-fpm"]

FROM cors_php_full AS cors_php_cli
CMD ["/bin/sh", "-c"]

FROM cors_php_base AS cors_php_fpm_slim
CMD ["php-fpm"]

FROM cors_php_base AS cors_php_cli_slim
CMD ["/bin/sh", "-c"]
