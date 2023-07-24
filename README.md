# CORS Docker Images

## Project Kaniko Build
Example is for ocay Project, used to test local builds with kaniko.

```bash
docker run -v "$(pwd)":/workspace -v "$(pwd)/cache":/cache -v ./auth.json:/kaniko/.docker/config.json gcr.io/kaniko-project/executor:latest \
    --context /workspace \
    --use-new-run \
    --dockerfile "Dockerfile" \
    --target=cors_php \
    --build-arg COMPOSER_AUTH="$COMPOSER_AUTH"  \
    --build-arg DOCKER_BASE_VERSION="4.1.0"  \
    --build-arg APP_ENV="coreshop"  \
    --build-arg PHP_VERSION="8.1" \
    --build-arg NGINX_VERSION="1.21" \
    --build-arg ALPINE_VERSION="3.17" \
    --build-arg REGISTRY_URL="europe-west3-docker.pkg.dev/cors-wolke/cors/docker" \
    --cache=true \
    --cache-dir=/cache \
    --tar-path=/cache \
    --no-push \
    --cache-repo=europe-west3-docker.pkg.dev/cors-wolke/cors/ocay/php-alpine-fpm \
    --single-snapshot \
    --destination=/cache/image.tar.gz
```