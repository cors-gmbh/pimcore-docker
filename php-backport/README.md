# PHP backport images

The PHP security release of 2026-10-21 fixes CVE-2026-109618 / CVE-2026-109619 ("php2shell").
docker-library only publishes the fixed versions for Alpine 3.23 and 3.24, and PHP 8.1 (end of
life) not at all. The official images for the older Alpine versions our 7.x/8.x branches build on
are frozen on vulnerable PHP versions. This directory rebuilds them ourselves.

| Directory | PHP | Source |
|---|---|---|
| `8.1/alpine3.21/{fpm,cli}` | 8.1.34 + backport | last official docker-library 8.1.34 Dockerfiles ([`5c037abaf9`](https://github.com/docker-library/php/tree/5c037abaf9/8.1/alpine3.21)) plus the PHP security team's backport patch |
| `8.2/alpine3.21/{fpm,cli}` | 8.2.35 | official `8.2/alpine3.23` Dockerfiles of [`f6048b5f`](https://github.com/docker-library/php/tree/f6048b5f6e3c2202ee082665a4ccc0d90de291a3), `FROM alpine:3.21` |
| `8.3/alpine3.2{1,2}/{fpm,cli}` | 8.3.36 | official `8.3/alpine3.23` Dockerfiles of `f6048b5f`, `FROM alpine:3.21` / `3.22` |
| `8.4/alpine3.2{1,2}/{fpm,cli}` | 8.4.27 | official `8.4/alpine3.23` Dockerfiles of `f6048b5f`, `FROM alpine:3.21` / `3.22` |

For 8.2 to 8.4 the `FROM` line is the **only** change. docker-library generates the Alpine
variants of a release from one template, and the official 3.23 and 3.24 Dockerfiles of
`f6048b5f` differ in nothing but that line.

For 8.1, the backport ([php-src@1d7dec178a09](https://github.com/php/php-src/commit/1d7dec178a094e6e75b229ce22754045f8c6070a),
branch `PHP-8.1-CVE-2026-109618-109619`, on top of `php-8.1.34`) is vendored as
`php-src-CVE-2026-109618-109619.patch`, sha256-checked and applied after docker-library's own
patches. `PHP_SECURITY_BACKPORT` marks those images, because `php -v` still reports 8.1.34.

`.github/workflows/php-backport.yml` builds amd64 + arm64, smoke tests them (PHP version, Alpine
version, `php -m`, `php-fpm -t`) and publishes
`ghcr.io/cors-gmbh/pimcore-docker/php-backport:<php>-<type>-alpine<alpine>`, plus an immutable
`<full version>-<type>-alpine<alpine>` tag. `docker-build.yml` uses these images as base for
exactly the combinations in its `BACKPORT_COMBOS` list instead of the official `php` image.

Check a running container:

```sh
php -v                         # 8.1.34 / 8.2.35 / 8.3.36 / 8.4.27
cat /etc/alpine-release        # unchanged Alpine version
echo $PHP_SECURITY_BACKPORT    # 8.1 only: CVE-2026-109618 CVE-2026-109619 php-src@1d7dec178a09
```

Remove a directory once no branch builds that PHP/Alpine combination any more. For the next PHP
security release, update `PHP_VERSION`, `PHP_URL`/`PHP_ASC_URL` and `PHP_SHA256` from the
docker-library commit of that release (or copy its `alpine3.23` Dockerfiles again and change `FROM`).
