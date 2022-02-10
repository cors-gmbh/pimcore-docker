#!/bin/sh
set -e

echo "Install Pimcore"
vendor/bin/pimcore-install --skip-database-config --ignore-existing-config --no-interaction

rm -rf var/config/system.yml
rm -rf var/cache

touch /var/www/html/var/tmp/.pimcore_installed
