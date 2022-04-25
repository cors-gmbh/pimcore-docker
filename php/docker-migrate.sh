#!/bin/sh
set -e

echo "Generating Classes";
bin/console pimcore:deployment:classes-rebuild --create-classes --no-interaction;
echo "Composer dump-autoload";
composer dump-autoload;
echo "Running Migrations";
bin/console doctrine:migrations:migrate --no-interaction