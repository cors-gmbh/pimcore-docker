ARG PHP_VERSION="8.3"
ARG PHP_TYPE="fpm"
ARG ALPINE_VERSION=3.20

FROM php:${PHP_VERSION}-${PHP_TYPE}-alpine${ALPINE_VERSION} as cors_php

ARG PHP_VERSION
ARG PHP_TYPE
ARG ALPINE_VERSION
ARG IMAGICK_VERSION_FROM_SRC=""

SHELL ["/bin/sh", "-eo", "pipefail", "-c"]

ENV TIMEZONE Europe/Vienna

RUN set -eux; \
    apk update && apk upgrade && apk add --no-cache \
      apk-tools autoconf gcc make g++ automake nasm cmake clang clang-dev tar \
      curl tzdata freetype libbsd graphviz openssl openblas openblas-dev \
      ffmpeg pngcrush jpegoptim exiftool poppler-utils wget icu-dev oniguruma-dev \
      libwebp libwebp-tools cmake unzip libxml2-dev libxslt-dev \
      xvfb ttf-dejavu ttf-droid ttf-freefont ttf-liberation \
      libwmf-dev libxext-dev libxt-dev librsvg-dev libzip-dev fcgi \
      libpng-dev libjpeg libxpm libjpeg-turbo-dev imap-dev krb5-dev openssl-dev libavif libavif-dev libheif libheif-dev zopfli \
      musl-locales icu-data-full lcms2-dev ghostscript libreoffice imagemagick imagemagick-dev; \
    if [ "$PHP_VERSION" = "8.3" ] || [ "$PHP_VERSION" = "8.4" ]; then \
      mkdir -p /usr/src/php/ext/imagick; \
      curl -fsSL https://github.com/Imagick/imagick/archive/${IMAGICK_VERSION_FROM_SRC}.tar.gz | tar xvz -C "/usr/src/php/ext/imagick" --strip 1; \
      if [ "$PHP_VERSION" = "8.4" ]; then \
        sed -i 's/php_strtolower/zend_str_tolower/g' /usr/src/php/ext/imagick/imagick.c; \
      fi; \
      docker-php-ext-install imagick; \
    else \
      pecl install imagick; \
      docker-php-ext-enable imagick; \
    fi; \
    docker-php-ext-install intl mbstring mysqli bcmath bz2 soap xsl pdo pdo_mysql fileinfo exif zip opcache; \
    docker-php-ext-configure gd -enable-gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install gd; \
    docker-php-ext-configure pcntl --enable-pcntl; \
    docker-php-ext-install pcntl; \
    pecl install apcu redis; \
    docker-php-ext-enable redis apcu; \
    cp /usr/share/zoneinfo/${TIMEZONE} /etc/localtime; \
    echo "${TIMEZONE}" > /etc/timezone; \
    apk del tzdata autoconf gcc make g++ automake nasm cmake clang clang-dev openblas-dev tar; \
    rm -rf /var/cache/apk/*;

ENV COMPOSER_ALLOW_SUPERUSER 1
ENV COMPOSER_MEMORY_LIMIT -1
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

RUN mkdir -p /usr/local/var/log/php7/
RUN mkdir -p /usr/local/var/run/

WORKDIR /var/www/html

COPY php/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
COPY php/docker-migrate.sh /usr/local/bin/docker-migrate
COPY php/docker-install.sh /usr/local/bin/install
COPY php/docker-wait.sh /usr/local/bin/wait
COPY php/docker-wait-db.sh /usr/local/bin/wait_db
COPY php/docker-wait-pimcore.sh /usr/local/bin/wait_pimcore
COPY php/docker-healthcheck.sh /usr/local/bin/health
COPY php/docker-readiness.sh /usr/local/bin/readiness
COPY php/docker-status.sh /usr/local/bin/status

COPY fpm/php.ini /usr/local/etc/php/php.ini

RUN chmod +x /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-migrate
RUN chmod +x /usr/local/bin/install
RUN chmod +x /usr/local/bin/wait
RUN chmod +x /usr/local/bin/wait_db
RUN chmod +x /usr/local/bin/wait_pimcore
RUN chmod +x /usr/local/bin/health
RUN chmod +x /usr/local/bin/status

FROM cors_php as cors_php_cli

ENTRYPOINT ["docker-entrypoint"]
CMD ["/bin/sh", "-c"]

FROM cors_php as cors_php_fpm

COPY fpm/php-config.conf /usr/local/etc/php-fpm.conf
COPY fpm/php-pool-config.conf /usr/local/etc/php-fpm.d/www.conf

ENTRYPOINT ["docker-entrypoint"]
CMD ["php-fpm"]