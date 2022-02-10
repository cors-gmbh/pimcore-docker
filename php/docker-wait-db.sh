#!/bin/sh
set -e

until bin/console doctrine:query:sql "SELECT 1" > /dev/null 2>&1; do
  (>&2 echo "Waiting for MySQL to be ready...")
  sleep 1
done
