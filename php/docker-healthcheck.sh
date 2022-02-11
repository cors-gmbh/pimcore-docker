#!/bin/sh
set -e

export SCRIPT_NAME=/ping
export SCRIPT_FILENAME=/ping
export REQUEST_METHOD=GET

bin/console doctrine:migrations:up-to-date

if cgi-fcgi -bind -connect 127.0.0.1:9000; then
  exit 0
fi

exit 1
