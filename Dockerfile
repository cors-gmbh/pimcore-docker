ARG PHP_VERSION="8.0"
ARG PHP_TYPE="fpm"

FROM php:${PHP_VERSION}-${PHP_TYPE}-alpine as cors_php

SHELL ["/bin/sh", "-eo", "pipefail", "-c"]

ENV TIMEZONE Europe/Vienna

RUN apk add --no-cache \
      apk-tools autoconf gcc make g++ automake nasm cmake clang clang-dev \
      curl tzdata freetype libbsd graphviz openssl openblas openblas-dev \
      ffmpeg ghostscript libreoffice pngcrush jpegoptim \
      exiftool poppler-utils wget icu-dev oniguruma-dev \
      libwebp libwebp-tools cmake unzip libxml2-dev libxslt-dev \
      xvfb ttf-dejavu ttf-droid ttf-freefont ttf-liberation \
      libwmf-dev libxext-dev libxt-dev librsvg-dev libzip-dev fcgi \
      libpng-dev libjpeg libxpm libjpeg-turbo-dev imap-dev krb5-dev openssl-dev libavif libavif-dev libheif libheif-dev zopfli \
      musl-locales; \
    curl -fsSL 'https://imagemagick.org/archive/ImageMagick.tar.gz' -o ImageMagick.tar.gz && \
      tar xvzf ImageMagick.tar.gz && \
      cd ImageMagick-*; \
      ./configure --with-lcms=yes --with-heic=yes;  \
      make --jobs=$(nproc);  \
      make install; \
      /sbin/ldconfig /usr/local/lib; \
      cd ..;  \
      rm -rf ImageMagick.tar.gz ImageMagick-*; \
    pecl install imagick; \
    docker-php-ext-enable imagick; \
    docker-php-ext-install intl mbstring mysqli bcmath bz2 soap xsl pdo pdo_mysql fileinfo exif zip opcache; \
    docker-php-ext-configure gd -enable-gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install gd; \
    pecl install apcu; \
    pecl install redis; \
    docker-php-ext-enable redis imagick apcu; \
    docker-php-ext-configure imap --with-kerberos --with-imap-ssl; \
    docker-php-ext-install imap; \
    docker-php-ext-enable imap; \
    cp /usr/share/zoneinfo/${TIMEZONE} /etc/localtime; \
    echo "${TIMEZONE}" > /etc/timezone; \
    apk del tzdata autoconf gcc make g++ automake nasm cmake clang clang-dev openblas-dev; \
    rm -rf /var/cache/apk/*;

COPY --from=madnight/alpine-wkhtmltopdf-builder:0.12.5-alpine3.10 \
    /bin/wkhtmltopdf /bin/wkhtmltopdf

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

COPY fpm/php.ini /usr/local/etc/php/php.ini

RUN chmod +x /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-migrate
RUN chmod +x /usr/local/bin/install
RUN chmod +x /usr/local/bin/wait
RUN chmod +x /usr/local/bin/wait_db
RUN chmod +x /usr/local/bin/wait_pimcore
RUN chmod +x /usr/local/bin/health

FROM cors_php as cors_php_cli

ENTRYPOINT ["docker-entrypoint"]
CMD ["/bin/sh", "-c"]

FROM cors_php as cors_php_fpm

COPY fpm/php-config.conf /usr/local/etc/php-fpm.conf
COPY fpm/php-pool-config.conf /usr/local/etc/php-fpm.d/www.conf

ENTRYPOINT ["docker-entrypoint"]
CMD ["php-fpm"]