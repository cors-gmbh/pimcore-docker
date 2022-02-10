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

VOLUME /var/www/html

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
