# PHP backport images

The PHP security release of 2026-10-21 fixes CVE-2026-109618 / CVE-2026-109619 ("php2shell").
docker-library only publishes the fixed versions for Alpine 3.23 and 3.24, and PHP 8.1 (end of
life) not at all. The official images for the older Alpine versions our 7.x/8.x branches build on
are frozen on vulnerable PHP versions. This directory rebuilds them ourselves.

| Directory | PHP | Source |
|---|---|---|
| `8.1/alpine3.21/{fpm,cli}` | 8.1.34 + backports | last official docker-library 8.1.34 Dockerfiles ([`5c037abaf9`](https://github.com/docker-library/php/tree/5c037abaf9/8.1/alpine3.21)) plus the PHP security team's backport patch (2026-10-21) and our port of the 2026-11-19 fixes; docker-library's own patches (11678, 19131, 14834) are vendored as `php-src-<n>.patch`, because github.com answers `.patch` URLs with 503 now and then |
| `8.2/alpine3.2{1,2}/{fpm,cli}` | 8.2.36 | official `8.2/alpine3.23` Dockerfiles of [`8f7cce4`](https://github.com/docker-library/php/tree/8f7cce4), `FROM alpine:3.21` / `3.22` |
| `8.3/alpine3.2{1,2}/{fpm,cli}` | 8.3.37 | official `8.3/alpine3.23` Dockerfiles of `8f7cce4`, `FROM alpine:3.21` / `3.22` |
| `8.4/alpine3.2{1,2}/{fpm,cli}` | 8.4.28 | official `8.4/alpine3.23` Dockerfiles of `8f7cce4`, `FROM alpine:3.21` / `3.22` |
| `8.5/alpine3.2{1,2}/{fpm,cli}` | 8.5.13 | official `8.5/alpine3.23` Dockerfiles of `8f7cce4`, `FROM alpine:3.21` / `3.22` |

For 8.2 to 8.5 the `FROM` line is the **only** change. docker-library generates the Alpine
variants of a release from one template, and the official 3.23 and 3.24 Dockerfiles of
`f6048b5f` differ in nothing but that line.

For 8.1, the backport ([php-src@1d7dec178a09](https://github.com/php/php-src/commit/1d7dec178a094e6e75b229ce22754045f8c6070a),
branch `PHP-8.1-CVE-2026-109618-109619`, on top of `php-8.1.34`) is vendored as
`php-src-CVE-2026-109618-109619.patch`, sha256-checked and applied after docker-library's own
patches. `PHP_SECURITY_BACKPORT` marks those images, because `php -v` still reports 8.1.34.

### 8.1: security release of 2026-11-19

For the release of 2026-11-19 (8.2.36 / 8.3.37 / 8.4.28 / 8.5.13) there is no 8.1 backport from
the PHP security team. `php-src-CVE-2026-11-19.patch` is our own port: the 12 fixes of php-src
branch `PHP-8.2` cherry-picked on top of `1d7dec178a09`, with their tests, as one diff without
`NEWS`. The Dockerfiles check its sha256 and apply it after the October patch.

| php-src (`PHP-8.2`) | Advisory | CVE | 8.1 |
|---|---|---|---|
| `13c4db2987` | GHSA-jm4m-qfqx-967m FPM worker stdio pipe fd closed twice | CVE-2026-129291 | clean |
| `7b2a394103` | GHSA-mmf9-xm3v-hg2x quadratic folded header concatenation | CVE-2026-127960 | clean |
| `9c0b44ffd6` | GHSA-f6gg-rchx-xw8j mixed case HTTPS and FTPS | CVE-2026-128064 | clean |
| `548bd27949` | GHSA-658j-r8rw-q6mx `session.upload_progress.enabled` off by default | CVE-2026-115560 | adapted (1) |
| `e2d3cee9ad` | GHSA-fm2m-fjf5-v3cp RCE via corrupted session file | CVE-2026-126714 | clean |
| `cb20015e04` | GHSA-gr4f-wgx5-jpfv `DATEG(tzcache)` use-after-free | CVE-2026-129496 | adapted (2) |
| `13a0f8c8c1` | GHSA-4646-p932-gw34 keep SOAP DTD alive during cleanup | CVE-2026-129506 | clean |
| `c7a30157f6` | GHSA-qc49-hpvq-g2w6 drain unread request bodies (FPM request smuggling) | CVE-2026-129289 | clean |
| `99a5ad7441` | GHSA-7qg2-v9fj-4mwv FPM XSS in status endpoint (from PHP 8.2.31) | CVE-2026-6735 | clean, prerequisite (3) |
| `37abd0a7f7` | GHSA-3mg3-cr28-46gc FPM XSS in status endpoint via user and script | CVE-2026-129292 | clean after (3) |
| `1e109bfbd2` | GHSA-5j3f-64r7-f564 `PATH_INFO` underflow in CGI | CVE-2026-129538 | clean |
| `db90b7ba0d` | GHSA-68fq-fh7h-f8gr keyless phar signature | CVE-2026-128090 | clean |
| `382d249480` | GHSA-q23r-hr55-xmpg `SOAP-ENC:arraySize` OOB read | CVE-2026-15353 | clean |

1. 8.1 checks the output state before the active state, and it has its own INI handlers for
   `session.use_trans_sid` and `session.lazy_write` (`OnUpdateTransSid`, `OnUpdateLazyWrite`; in 8.2
   both use the checked `OnUpdateSessionBool`). The new runtime check goes first in every handler,
   these two included; `in_rfc1867_update` does not exist in 8.1. Extra test
   `ext/session/tests/session_ini_set_upload_progress_enabled_81.phpt` for the two handlers. Note
   that the October patch already switched the upload-progress callback off in 8.1; this fix adds
   the `Off` default and the runtime check of 8.2.
2. Conflict in `ext/zend_test/php_test.h` only, because 8.2 has more test globals there; only the
   new `warn_on_startup` global is added. The test expects 8.1's `Warning: Unknown: Input variables
   exceeded …` (8.2 labels it `PHP Request Startup:`).
3. The fix for GHSA-3mg3 replaces the escaping code that GHSA-7qg2 (CVE-2026-6735) added in
   PHP 8.2.31 (May 2026). 8.1.34 never got that fix, so it is cherry-picked first; with it, the
   GHSA-3mg3 commit applies unchanged and the request URI is escaped as in 8.2.

The 8.3+/8.5-only advisories of that release do not apply to 8.1: GHSA-g3vh-838c-65v7 (8.1 has no
`session_started_filename`), GHSA-8mjj-2r7p-4hg2 and GHSA-2fjv-p558-g82m (no
`fatal_error_backtraces` / `last_fatal_error_backtrace`), GHSA-mg3p-mxj9-g2mm (no `ext/uri`).

To rebuild the patch: in php-src, branch from `1d7dec178a09`, `git cherry-pick -x` the commits of
the table in that order (resolving as described), then
`git diff --no-renames 1d7dec178a09..HEAD -- . ':(exclude)NEWS'`.

`.github/workflows/php-backport.yml` builds amd64 + arm64, smoke tests them (PHP version, Alpine
version, `php -m`, `php-fpm -t`; for 8.1 also the backport marker and `session.upload_progress.enabled`
off) and publishes
`ghcr.io/cors-gmbh/pimcore-docker/php-backport:<php>-<type>-alpine<alpine>`, plus an immutable
`<full version>-<type>-alpine<alpine>` tag (8.1: `8.1.34-cve-2026-11-19-<type>-alpine3.21`; the October
state stays available as `8.1.34-cve-2026-109618-<type>-alpine3.21`). `docker-build.yml` uses these images as base for
exactly the combinations in its `BACKPORT_COMBOS` list instead of the official `php` image.

Check a running container:

```sh
php -v                         # 8.1.34 / 8.2.36 / 8.3.37 / 8.4.28 / 8.5.13
cat /etc/alpine-release        # unchanged Alpine version
echo $PHP_SECURITY_BACKPORT    # 8.1 only: CVE-2026-109618 CVE-2026-109619 php-src@1d7dec178a09 CVE-2026-129291 … php-src-CVE-2026-11-19.patch
php -i | grep session.upload_progress.enabled   # 8.1: Off
```

Remove a directory once no branch builds that PHP/Alpine combination any more. For the next PHP
security release, update `PHP_VERSION`, `PHP_URL`/`PHP_ASC_URL` and `PHP_SHA256` from the
docker-library commit of that release (or copy its `alpine3.23` Dockerfiles again and change `FROM`).
