#!/bin/sh
set -e

# run the healthcheck with minimal env variables
env -i \
  SCRIPT_NAME=/fpm-status \
  SCRIPT_FILENAME=/fpm-status \
  REQUEST_METHOD=GET \
  CONTENT_LENGTH=0 \
  cgi-fcgi -bind -connect 127.0.0.1:9001