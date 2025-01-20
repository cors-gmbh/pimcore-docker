[![CORS](https://github.com/cors-gmbh/.github/blob/dc0f9620a08711cfdcdbed7ec274b1675a29ef50/cors-we-want-you-3.jpg?raw=true)](https://cors.gmbh/jobs)


# CORS Pimcore Docker Images

This repository provides a Docker-based environment for running and managing [Pimcore](https://pimcore.com), a leading
open-source digital experience platform (DXP). It enables developers to quickly set up, develop, and test Pimcore
projects using a preconfigured Docker setup.

These optimized Docker images, based on Alpine Linux, are designed to run Pimcore in production environments,
specifically on Google Kubernetes Engine. This is also a Multi-Arch Build for ARM (Mainly Apple Silicon) and x86-64 
(AMD) Systems. 

As part of our journey to Kubernetes, we’ve been running this setup since 2021, and it has proven reliable. We share
this knowledge for free because we believe in open source, Pimcore, and the power of collaboration.

Cheers Dominik :)

## Table of Contents

- [Features](#features)
- [Versioning](#versioning)
- [Available Images](#available-images)
- [Getting Started](#getting-started)
- [Contributing](#contributing)
- [License](#license)

## Features

- ***Alpine Linux Base***: Lightweight and secure foundation for the Docker images.
- ***Optimized for Pimcore***: Tailored configurations to ensure optimal performance with Pimcore applications.
- ***Production-Ready***: Suitable for deployment in production environments with best practices incorporated.
- ***Development-Ready***: Use the same image in development as for production

## Versioning

We currently build the images for following Versions:

 - ***Alpine***: 3.20, 3.21
 - ***PHP***: 8.2, 8.3, 8.4
 - ***Variants***: CLI, FPM, FPM-Debug, Supervisord, FPM-Blackfire

## Available Images

- ***PHP-FPM***: Configured with necessary extensions and settings for running Pimcore.
- ***PHP-FPM Debug***: Configured with xdebug to also step-by-step debug.
- ***Nginx***: Optimized web server configuration to serve Pimcore applications efficiently.
- ***Supervisord***: Process control system to manage and monitor processes like PHP-FPM and Nginx.
- ***Blackfire***: Integrated for performance profiling and monitoring.

Images are named like:

- ***FPM***: ghcr.io/cors-gmbh/pimcore-docker/php-fpm:8.2-alpine3.21-7.0-LATEST
- ***FPM-Debug***: ghcr.io/cors-gmbh/pimcore-docker/php-fpm-debug:8.2-alpine3.21-7.0-LATEST
- ***Supervisord***: ghcr.io/cors-gmbh/pimcore-docker/php-supervisord:8.2-alpine3.21-7.0-LATEST
- ***Blackfire***: ghcr.io/cors-gmbh/pimcore-docker/php-fpm-blackfire:8.2-alpine3.21-7.0-LATEST
- ***Nginx***: ghcr.io/cors-gmbh/pimcore-docker/nginx:1.26-7.0-LATEST

## Getting Started

We use this image as our base layer for our Projects. We then use a custom Dockerfile and docker-compose.yaml per
Project.

### docker-compose.yaml

This is our example docker-compose.yaml that we use for Development. We further abstract this into a much more complex
setup. But for the gist of it, here is the simple version :)

```yaml
name: pimcore

services:
  db:
    image: mysql:8.4
    working_dir: /application
    volumes:
      - pimcore-database:/var/lib/mysql
      - .:/application:cached
    environment:
      - MYSQL_ROOT_PASSWORD=ROOT
      - MYSQL_DATABASE=pimcore
      - MYSQL_USER=pimcore
      - MYSQL_PASSWORD=pimcore

  nginx:
    image: nginx:stable-alpine
    ports: 80:80
    volumes:
      - ./:/var/www/html:ro
      - ./.docker/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - php
      - php-debug

  php:
    image: ghcr.io/cors-gmbh/pimcore-docker/php-fpm:8.2-alpine3.21-7.0-LATEST
    command: 'php-fpm'
    entrypoint: docker-php-entrypoint
    depends_on:
      - db
    volumes:
      - ./:/var/www/html:cached

  php-debug:
    image: ghcr.io/cors-gmbh/pimcore-docker/php-fpm-debug:8.2-alpine3.21-7.0-LATEST
    command: 'php-fpm'
    entrypoint: xdebug-entrypoint
    depends_on:
      - db
    volumes:
      - ./:/var/www/html:cached
    networks:
      - kwizda
      - cors_dev
    environment:
      - PHP_IDE_CONFIG=serverName=localhost

  supervisord:
    image: ghcr.io/cors-gmbh/pimcore-docker/php-supervisord:8.2-alpine3.21-7.0-LATEST
    depends_on:
      - db
    volumes:
      - ./:/var/www/html:cached

volumes:
  pimcore-database:
```

### Dockerfile

For Production and Stage Build, we then have our gitlab-ci pipeline [.project-gitlab-ci.yml](.project-gitlab-ci.yml)
which builds our project, pushes it to Google Artifact Registry and we update a separate project where the Kubernetes
Manifest lives. For now, we only have this setup for Gitlab.

This is the dockerfile we use in the Projects. It is a multi-stage build that builds several images for several
purposes:

- ***FPM***: FPM Server with the application code
- ***CLI***: CLI Image mainly to be slimmer and to run migrations and pre-hook jobs
- ***Supervisor***: To run queue workers
- ***NGINX***: Frontend HTTP Server
- ***Blackfire***: For Production Profiling, which is our default deployment anyway
- ***Node***: To build webpack encore and copy it to the PHP Containers and NGINX.

```Dockerfile
ARG NODE_VERSION=22
ARG DOCKER_BASE_VERSION
ARG NGINX_VERSION
ARG PHP_VERSION
ARG ALPINE_VERSION
ARG REGISTRY_URL

FROM node:${NODE_VERSION}-alpine3.16 AS cors_node

RUN apk add --update python3 make g++\
   && rm -rf /var/cache/apk/*

WORKDIR /var/www/html
COPY package.json yarn.lock postcss.config.js webpack.config.js ./
RUN set -eux; \
    yarn install; \
    yarn cache clean;

COPY assets /var/www/html/assets
COPY public/app /var/www/html/public/app

RUN set -eux; \
    yarn run encore prod

FROM ${REGISTRY_URL}/php-alpine-${ALPINE_VERSION}-fpm:${PHP_VERSION}-${DOCKER_BASE_VERSION} as cors_php

WORKDIR /var/www/html

ARG APP_ENV=prod
ENV APP_ENV=$APP_ENV
ENV APP_DEBUG=0

ARG COMPOSER_AUTH

USER www-data

COPY --chown=www-data:www-data composer.* ./
COPY --chown=www-data:www-data lib lib/

RUN set -eux; \
    COMPOSER_MEMORY_LIMIT=-1 composer install --prefer-dist --no-scripts --no-progress;

COPY --chown=www-data:www-data bin bin/
COPY --chown=www-data:www-data public/index.php public/index.php
COPY --chown=www-data:www-data config config/
COPY --chown=www-data:www-data src src/
COPY --chown=www-data:www-data templates templates/
COPY --chown=www-data:www-data themes themes/
COPY --chown=www-data:www-data translations translations/
COPY --chown=www-data:www-data var var/
COPY --chown=www-data:www-data .env .env

RUN set -eux; \
    chmod +x bin/console; \
    php -d memory_limit=-1 bin/console cache:clear --env=$APP_ENV -vvv; \
    mkdir -p var/cache var/log; \
    sleep 1; \
    bin/console assets:install; \
    PIMCORE_DISABLE_CACHE=1 bin/console pimcore:build:classes; \
    COMPOSER_MEMORY_LIMIT=-1 composer dump-autoload --classmap-authoritative --optimize; \
    sync;

COPY --chown=www-data:www-data --from=cors_node /var/www/html/public public/
COPY --chown=www-data:www-data public/pimcore public/pimcore

FROM ${REGISTRY_URL}/php-alpine-${ALPINE_VERSION}-supervisord:${PHP_VERSION}-${DOCKER_BASE_VERSION} as cors_php_supervisord

COPY .docker/supervisord/coreshop.conf /etc/supervisor/conf.d/coreshop.conf

ARG APP_ENV=prod
ENV APP_ENV=$APP_ENV
ENV APP_DEBUG=0

COPY --from=cors_php /var/www/html /var/www/html

FROM ${REGISTRY_URL}/php-alpine-${ALPINE_VERSION}-cli:${PHP_VERSION}-${DOCKER_BASE_VERSION} as cors_php_cli

ARG APP_ENV=prod
ENV APP_ENV=$APP_ENV
ENV APP_DEBUG=0

COPY --from=cors_php /var/www/html /var/www/html


FROM ${REGISTRY_URL}/php-alpine-${ALPINE_VERSION}-fpm-blackfire:${PHP_VERSION}-${DOCKER_BASE_VERSION} as cors_php_blackfire

ARG APP_ENV=prod
ENV APP_ENV=$APP_ENV
ENV APP_DEBUG=0

COPY --from=cors_php /var/www/html /var/www/html

FROM ${REGISTRY_URL}/nginx:${NGINX_VERSION}-${DOCKER_BASE_VERSION} AS cors_nginx

COPY --from=cors_php /var/www/html/public public/
COPY --from=cors_node /var/www/html/public public/
COPY public/.well-known public/.well-known

COPY .docker/nginx/pimcore-default.conf /etc/nginx/conf.d/default.conf
```

## Contributing

We welcome contributions to improve this project! If you encounter issues or have suggestions, please:

1. Fork the repository.
2. Create a new branch for your feature or bug fix.
3. Submit a pull request for review.

## License

This repository is licensed under the MIT [License](LICENSE). The docker images are not licensed since we didn't do any
due diligence on any included software and their licenses. Only the Sourcecode is MIT Licensed!

Happy Kubernetesing! 🎉
