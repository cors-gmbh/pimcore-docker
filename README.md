# CORS Docker Images

## Local Docker Build
```bash
docker build \
  --pull \
  --tag cors-base \
  --target=cors_php_fpm \
  --build-arg PHP_VERSION=8.3 \
  --build-arg PHP_TYPE=fpm \
  --build-arg ALPINE_VERSION=3.20 \
  --build-arg IMAGICK_VERSION_FROM_SRC=28f27044e435a2b203e32675e942eb8de620ee58 \
  --progress plain \
  .
```

### Debug
```bash
docker build \
  --tag base-debug \
  -f Dockerfile-debug \
  --build-arg FROM=cors-base \
  --build-arg PHP_VERSION=8.3 \
  --build-arg ALPINE_VERSION=3.20 \
  --build-arg IMAGICK_VERSION_FROM_SRC=28f27044e435a2b203e32675e942eb8de620ee58 \
  --progress plain \
  .
```

## Project Kaniko Build
Example is for ocay Project, used to test local builds with kaniko.

```bash
docker run -v "$(pwd)":/workspace -v "$(pwd)/cache":/cache -v ./auth.json:/kaniko/.docker/config.json gcr.io/kaniko-project/executor:latest \
    --context /workspace \
    --use-new-run \
    --dockerfile "Dockerfile" \
    --target=cors_php \
    --build-arg COMPOSER_AUTH="$COMPOSER_AUTH"  \
    --build-arg DOCKER_BASE_VERSION="5.2.0"  \
    --build-arg APP_ENV="coreshop"  \
    --build-arg PHP_VERSION="8.2" \
    --build-arg NGINX_VERSION="1.26" \
    --build-arg ALPINE_VERSION="3.20" \
    --build-arg REGISTRY_URL="europe-west3-docker.pkg.dev/cors-wolke/cors/docker" \
    --cache=true \
    --cache-dir=/cache \
    --tar-path=/cache \
    --no-push \
    --cache-repo=europe-west3-docker.pkg.dev/cors-wolke/cors/ocay/php-alpine-fpm \
    --single-snapshot \
    --destination=/cache/image.tar.gz
```