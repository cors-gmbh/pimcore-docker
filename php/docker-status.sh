#!/bin/sh
set -e

export SCRIPT_NAME=/fpm-status
export SCRIPT_FILENAME=/fpm-status
export REQUEST_METHOD=GET

cgi-fcgi -bind -connect 127.0.0.1:9001