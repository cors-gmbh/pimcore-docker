#!/bin/sh
set -e

until bin/console doctrine:query:sql "SELECT * FROM classes" > /dev/null 2>&1; do
  (>&2 echo "Waiting for Pimcore to be installed...")
  sleep 1
done
