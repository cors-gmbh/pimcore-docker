# PHP 8.1 security backport

PHP 8.1 is end of life. For CVE-2026-109618 / CVE-2026-109619 ("php2shell") the PHP security
team published only a source backport, the branch
[`PHP-8.1-CVE-2026-109618-109619`](https://github.com/php/php-src/tree/PHP-8.1-CVE-2026-109618-109619):
one commit ([`1d7dec178a09`](https://github.com/php/php-src/commit/1d7dec178a094e6e75b229ce22754045f8c6070a))
on top of `php-8.1.34`. There is no 8.1 release and no official Docker image with the fix.

This directory rebuilds the official image ourselves:

- `8.1/alpine3.21/{fpm,cli}/` are the last official docker-library/php build directories for
  8.1.34 ([`5c037abaf9`](https://github.com/docker-library/php/tree/5c037abaf9/8.1/alpine3.21)).
- The only changes: the vendored backport patch `php-src-CVE-2026-109618-109619.patch`
  (sha256-checked and applied right after the existing docker-library patches) and the
  `PHP_SECURITY_BACKPORT` environment variable as a marker, since `php -v` still reports 8.1.34.

`.github/workflows/php-backport.yml` builds amd64 + arm64 and publishes
`ghcr.io/cors-gmbh/pimcore-docker/php-backport:8.1-{fpm,cli}-alpine3.21` (and the immutable
`8.1.34-cve-2026-109618-{fpm,cli}-alpine3.21`). `docker-build.yml` uses it as base for PHP 8.1
on Alpine 3.21 instead of the official `php` image.

Check a running container:

```sh
php -v                         # PHP 8.1.34
echo $PHP_SECURITY_BACKPORT    # CVE-2026-109618 CVE-2026-109619 php-src@1d7dec178a09
```

Remove this directory once no project runs PHP 8.1 any more.
