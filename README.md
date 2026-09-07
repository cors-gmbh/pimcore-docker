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

 - ***Alpine***: 3.23, 3.24
 - ***PHP***: 8.4, 8.5
 - ***Variants***: pimcore, pimcore-slim
 - ***Nginx***: 1.28, 1.29

## Available Images

Since 10.0 there is one PHP image per PHP/Alpine combination. It serves as php-fpm, cli, queue worker, xdebug and
blackfire container; what runs is decided by the command and environment variables at container start:

| Purpose            | How                                                        |
|--------------------|------------------------------------------------------------|
| php-fpm            | default command `php-fpm`                                  |
| cli / migrations   | `command: bin/console ...` or any shell command            |
| queue workers      | `command: supervisord` (uses the bundled supervisord.conf) |
| xdebug             | `XDEBUG_ENABLED=1` (`XDEBUG_HOST`, `XDEBUG_MODE`, `XDEBUG_CONFIG` optional) |
| blackfire probe    | `BLACKFIRE_ENABLED=1` (`BLACKFIRE_AGENT_SOCKET` optional, default `tcp://127.0.0.1:8307`) |

xdebug and the blackfire probe are part of the image but not loaded unless enabled, so there is no overhead in
production. They cannot be enabled at the same time.

- ***pimcore***: PHP-FPM with all extensions and tools Pimcore needs, including LibreOffice for document conversion.
- ***pimcore-slim***: Same image without LibreOffice (and its Qt/GTK/Mesa dependencies), roughly 650 MB smaller.
  Use it for projects that don't convert office documents to PDF/previews.
- ***nginx***: Optimized web server configuration to serve Pimcore applications efficiently.

Both PHP variants are built in one `docker buildx bake` run and share every layer except the LibreOffice one.

Images are named like:

- ***pimcore***: ghcr.io/cors-gmbh/pimcore-docker/pimcore:8.4-alpine3.24-10.0-LATEST
- ***pimcore-slim***: ghcr.io/cors-gmbh/pimcore-docker/pimcore-slim:8.4-alpine3.24-10.0-LATEST
- ***nginx***: ghcr.io/cors-gmbh/pimcore-docker/nginx:1.29-10.0-LATEST

Removed in 10.0: `php-fpm`, `php-cli`, `php-fpm-debug`, `php-supervisord` and `php-fpm-blackfire`. Replace them with
`pimcore` and the command/environment from the table above.

### Building locally

```sh
docker buildx bake --load                                      # PHP 8.4 / Alpine 3.24, both variants
PHP_VERSION=8.5 ALPINE_VERSION=3.23 docker buildx bake --load pimcore-slim
```

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
    image: ghcr.io/cors-gmbh/pimcore-docker/pimcore:8.4-alpine3.24-10.0-LATEST
    depends_on:
      - db
    volumes:
      - ./:/var/www/html:cached

  php-debug:
    image: ghcr.io/cors-gmbh/pimcore-docker/pimcore:8.4-alpine3.24-10.0-LATEST
    depends_on:
      - db
    volumes:
      - ./:/var/www/html:cached
    environment:
      - XDEBUG_ENABLED=1
      - PHP_IDE_CONFIG=serverName=localhost

  supervisord:
    image: ghcr.io/cors-gmbh/pimcore-docker/pimcore:8.4-alpine3.24-10.0-LATEST
    command: supervisord
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

- ***PHP***: One image with the application code. It runs as FPM server, migration/pre-hook job (`bin/console`),
  queue worker (`supervisord`) or with the blackfire probe (`BLACKFIRE_ENABLED=1`), depending on the Kubernetes
  manifest.
- ***NGINX***: Frontend HTTP Server
- ***Node***: To build webpack encore and copy it to the PHP Containers and NGINX.

```Dockerfile
ARG PHP_VERSION
ARG NGINX_VERSION
ARG NODE_VERSION=22
ARG DOCKER_BASE_VERSION
ARG ALPINE_VERSION

FROM node:${NODE_VERSION}-alpine AS cors_node

RUN apk add --update python3 py3-setuptools make g++\
   && rm -rf /var/cache/apk/*

WORKDIR /var/www/html
COPY package.json package-lock.json postcss.config.js webpack.config.js tsconfig.json ./
RUN set -eux; \
    npm install;

COPY themes /var/www/html/themes

RUN set -eux; \
    npm run build;

FROM ghcr.io/cors-gmbh/pimcore-docker/pimcore:${PHP_VERSION}-alpine${ALPINE_VERSION}-${DOCKER_BASE_VERSION} AS cors_php

WORKDIR /var/www/html

ARG APP_ENV=prod
ENV APP_ENV=$APP_ENV
ENV APP_DEBUG=0

ARG COMPOSER_AUTH

USER www-data

COPY --chown=www-data:www-data composer.* ./
COPY --chown=www-data:www-data bin bin/

RUN set -eux; \
    COMPOSER_MEMORY_LIMIT=-1 composer install --prefer-dist --no-scripts --no-progress --no-dev; \
    mkdir -p var/cache var/log public/bundles; \
    chmod +x bin/console; \
    sync;

COPY --chown=www-data:www-data public/index.php public/index.php
COPY --chown=www-data:www-data config config/
COPY --chown=www-data:www-data src src/
COPY --chown=www-data:www-data templates templates/
COPY --chown=www-data:www-data themes themes/
COPY --chown=www-data:www-data translations translations/
COPY --chown=www-data:www-data var var/
COPY --chown=www-data:www-data .env .env

RUN set -eux; \
    bin/console cache:clear --env=$APP_ENV; \
    bin/console assets:install; \
    PIMCORE_DISABLE_CACHE=1 bin/console pimcore:build:classes; \
    COMPOSER_MEMORY_LIMIT=-1 composer dump-autoload --classmap-authoritative; \
    sync;

COPY --chown=www-data:www-data --from=cors_node /var/www/html/public public/

COPY .docker/supervisord/project.conf /etc/supervisor/conf.d/project.conf
COPY .docker/supervisord/coreshop.conf /etc/supervisor/conf.d/coreshop.conf

FROM ghcr.io/cors-gmbh/pimcore-docker/nginx:${NGINX_VERSION}-${DOCKER_BASE_VERSION} AS cors_nginx

COPY --from=cors_php /var/www/html/public public/
COPY --from=cors_node /var/www/html/public public/
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
