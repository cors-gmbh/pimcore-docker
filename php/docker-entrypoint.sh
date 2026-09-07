#!/bin/sh
set -e

# first arg is `-f` or `--some-option`
if [ "${1#-}" != "$1" ]; then
  set -- php-fpm "$@"
fi

# `supervisord` without arguments -> use the bundled config
if [ "$1" = 'supervisord' ] && [ "$#" -eq 1 ]; then
  set -- supervisord -c /etc/supervisor/supervisord.conf
fi

#
# optional extensions: xdebug and the blackfire probe ship with the image but are
# only loaded when requested. They are enabled through PHP_INI_SCAN_DIR, so this
# works for any user without writing to /usr/local/etc/php/conf.d.
#
OPTIONAL_INI=/usr/local/etc/php/optional
SCAN_DIR="${PHP_INI_SCAN_DIR:-/usr/local/etc/php/conf.d}"

if [ "${XDEBUG_ENABLED:-0}" = "1" ] && [ "${BLACKFIRE_ENABLED:-0}" = "1" ]; then
  echo "XDEBUG_ENABLED and BLACKFIRE_ENABLED cannot be set at the same time" >&2
  exit 1
fi

if [ "${XDEBUG_ENABLED:-0}" = "1" ]; then
  SCAN_DIR="$SCAN_DIR:$OPTIONAL_INI/xdebug"

  if [ -z "$XDEBUG_CONFIG" ]; then
    HOST="$XDEBUG_HOST"
    # OrbStack
    [ -n "$HOST" ] || HOST=$(getent ahostsv4 host.internal 2>/dev/null | awk 'NR==1{ print $1 }')
    # Docker for Mac
    [ -n "$HOST" ] || HOST=$(getent hosts docker.for.mac.localhost 2>/dev/null | awk '{ print $1 }')
    # default gateway
    [ -n "$HOST" ] || HOST=$(ip route 2>/dev/null | awk '/default/ { print $3 }')
    [ -z "$HOST" ] || export XDEBUG_CONFIG="client_host=$HOST"
  fi
fi

if [ "${BLACKFIRE_ENABLED:-0}" = "1" ]; then
  if [ ! -e "$(php -r 'echo ini_get("extension_dir");')/blackfire.so" ]; then
    echo "BLACKFIRE_ENABLED=1 but this image has no blackfire probe for its PHP version" >&2
    exit 1
  fi
  SCAN_DIR="$SCAN_DIR:$OPTIONAL_INI/blackfire"
fi

export PHP_INI_SCAN_DIR="$SCAN_DIR"

if [ "$1" = 'php-fpm' ] || [ "$1" = 'bin/console' ]; then
  mkdir -p var/cache var/log public/var
fi

exec docker-php-entrypoint "$@"
