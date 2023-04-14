#!/bin/sh
set -e

export SCRIPT_NAME=/fpm-status
export SCRIPT_FILENAME=/fpm-status
export REQUEST_METHOD=GET

bin/console doctrine:migrations:up-to-date

if cgi-fcgi -bind -connect 127.0.0.1:9001; then
  exit 0
fi

exit 1
