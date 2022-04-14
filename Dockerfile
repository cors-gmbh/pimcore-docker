ARG PHP_VERSION="8.0"
ARG PHP_TYPE="fpm"
ARG NGINX_VERSION=1.21

FROM nginx:${NGINX_VERSION}-alpine AS cors_nginx

COPY nginx/nginx-default.conf /etc/nginx/conf.d/

WORKDIR /var/www/html

FROM php:${PHP_VERSION}-${PHP_TYPE}-alpine as cors_php

SHELL ["/bin/sh", "-eo", "pipefail", "-c"]

ENV TIMEZONE Europe/Vienna

RUN apk add --no-cache \
      apk-tools autoconf gcc make g++ automake nasm ninja cmake clang clang-dev python3-dev \
      curl tzdata freetype libbsd graphviz openssl openblas-dev \
      ffmpeg html2text ghostscript libreoffice pngcrush jpegoptim \
      exiftool poppler-utils git wget icu-dev oniguruma-dev \
      libx11-dev libwebp libwebp-tools cmake unzip libxml2-dev libxslt-dev \
      xvfb ttf-dejavu ttf-droid ttf-freefont ttf-liberation \
      libwmf-dev libxext-dev libxt-dev librsvg-dev libzip-dev  \
      opencv opencv-dev py3-pip fcgi \
      libpng-dev libjpeg libxpm libjpeg-turbo-dev imap-dev krb5-dev openssl-dev libavif libavif-dev libheif libheif-dev zopfli; \
    curl -fsSL 'http://www.imagemagick.org/download/ImageMagick.tar.gz' -o ImageMagick.tar.gz && \
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
    apk del tzdata autoconf gcc make g++ automake nasm ninja cmake clang clang-dev; \
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


FROM cors_php AS cors_supervisord

RUN apk update && apk add --no-cache supervisor

COPY supervisord/supervisord.conf /etc/supervisor/supervisord.conf
COPY supervisord/pimcore.conf /etc/supervisor/conf.d/pimcore.conf

CMD ["/usr/bin/supervisord"]

