#!/bin/sh
set -e

# first arg is `-f` or `--some-option`
if [ "${1#-}" != "$1" ]; then
  set -- php-fpm "$@"
fi

if [ "$1" = 'php-fpm' ] || [ "$1" = 'bin/console' ]; then
  mkdir -p var/cache var/log public/var
  bin/console pimcore:deployment:classes-rebuild --no-interaction || true
  composer dump-autoload #required to load pimcore classes after they have been installed
fi

exec docker-php-entrypoint "$@"
