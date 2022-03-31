ARG PHP_VERSION=8.0
ARG NGINX_VERSION=1.21
ARG NODE_VERSION=14

FROM pimcore/pimcore:PHP${PHP_VERSION}-fpm AS cors_php
WORKDIR /var/www/html

RUN set -x; \
    apt-get update; \
    apt-get install -y --no-install-recommends libfcgi-bin; \
    apt-get autoremove; \
    apt-get remove -y chromium mysql-common java-common x11-common x11-utils x11-xserver-utils x11proto-dev x11-proto-xext-dev; \
    rm -rf /root/.cache; \
    rm -rf /var/lib/apt/lists/*;

COPY php/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
COPY php/docker-install.sh /usr/local/bin/install
COPY php/docker-wait.sh /usr/local/bin/wait
COPY php/docker-wait-db.sh /usr/local/bin/wait_db
COPY php/docker-wait-pimcore.sh /usr/local/bin/wait_pimcore
COPY php/docker-healthcheck.sh /usr/local/bin/health

RUN chmod +x /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/install
RUN chmod +x /usr/local/bin/wait
RUN chmod +x /usr/local/bin/wait_db
RUN chmod +x /usr/local/bin/wait_pimcore
RUN chmod +x /usr/local/bin/health

ENTRYPOINT ["docker-entrypoint"]
CMD ["php-fpm"]

FROM nginx:${NGINX_VERSION}-alpine AS cors_nginx

COPY nginx/nginx-default.conf /etc/nginx/conf.d/

WORKDIR /var/www/html

FROM php:${PHP_VERSION}-fpm-alpine as cors_php_alpine


SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

ENV TIMEZONE Europe/Vienna
# Install PHP
RUN apk add --no-cache \
      apk-tools autoconf gcc make g++ automake nasm \
      imagemagick imagemagick-dev curl tzdata freetype libbsd graphviz openssl \
      ffmpeg html2text ghostscript libreoffice pngcrush jpegoptim \
      exiftool poppler-utils git wget icu-dev oniguruma-dev \
      libx11-dev libwebp libwebp-tools cmake unzip libxml2-dev libxslt-dev \
      xvfb ttf-dejavu ttf-droid ttf-freefont ttf-liberation \
      libwmf-dev libxext-dev libxt-dev librsvg-dev libzip-dev \
      libpng-dev libjpeg libxpm libjpeg-turbo-dev imap-dev krb5-dev openssl-dev; \
    docker-php-ext-install intl mbstring mysqli bcmath bz2 soap xsl pdo pdo_mysql fileinfo exif zip opcache; \
    docker-php-ext-configure gd -enable-gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install gd; \
    pecl install imagick; \
    pecl install apcu; \
    pecl install redis; \
    docker-php-ext-enable redis imagick apcu; \
    docker-php-ext-configure imap --with-kerberos --with-imap-ssl; \
    docker-php-ext-install imap; \
    docker-php-ext-enable imap; \
    cp /usr/share/zoneinfo/${TIMEZONE} /etc/localtime; \
    echo "${TIMEZONE}" > /etc/timezone; \
    apk del tzdata; \
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
COPY php/docker-install.sh /usr/local/bin/install
COPY php/docker-wait.sh /usr/local/bin/wait
COPY php/docker-wait-db.sh /usr/local/bin/wait_db
COPY php/docker-wait-pimcore.sh /usr/local/bin/wait_pimcore
COPY php/docker-healthcheck.sh /usr/local/bin/health

RUN chmod +x /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/install
RUN chmod +x /usr/local/bin/wait
RUN chmod +x /usr/local/bin/wait_db
RUN chmod +x /usr/local/bin/wait_pimcore
RUN chmod +x /usr/local/bin/health

ENTRYPOINT ["docker-entrypoint"]
CMD ["php-fpm"]