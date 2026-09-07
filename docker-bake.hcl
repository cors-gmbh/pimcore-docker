// Builds all PHP variants of one PHP/Alpine combination in a single buildx
// invocation so they share layers (fpm, cli, fpm-slim and cli-slim differ only
// in the LibreOffice layer and CMD).
//
// Local usage:
//   docker buildx bake --load                                 # 8.4 / alpine 3.24, all four variants
//   docker buildx bake --load fpm                             # only php-fpm
//   PHP_VERSION=8.5 ALPINE_VERSION=3.23 docker buildx bake --load fpm-slim
//
// CI passes REGISTRY, ARCH_PREFIX ("amd-"/"arm-") and RELEASE_TAG and adds --push.

variable "PHP_VERSION" {
  default = "8.4"
}

variable "ALPINE_VERSION" {
  default = "3.24"
}

variable "REGISTRY" {
  default = "ghcr.io/cors-gmbh/pimcore-docker"
}

variable "ARCH_PREFIX" {
  default = ""
}

variable "RELEASE_TAG" {
  default = "local"
}

function "image" {
  params = [name]
  result = "${REGISTRY}/${ARCH_PREFIX}${name}:${PHP_VERSION}-alpine${ALPINE_VERSION}-${RELEASE_TAG}"
}

group "default" {
  targets = ["fpm", "cli", "fpm-slim", "cli-slim"]
}

target "_php" {
  context    = "."
  dockerfile = "Dockerfile"
  args = {
    PHP_VERSION    = PHP_VERSION
    ALPINE_VERSION = ALPINE_VERSION
  }
  cache-to = ["type=inline"]
}

target "fpm" {
  inherits   = ["_php"]
  target     = "cors_php_fpm"
  tags       = [image("php-fpm")]
  cache-from = ["type=registry,ref=${image("php-fpm")}"]
}

target "cli" {
  inherits   = ["_php"]
  target     = "cors_php_cli"
  tags       = [image("php-cli")]
  cache-from = ["type=registry,ref=${image("php-fpm")}"]
}

target "fpm-slim" {
  inherits   = ["_php"]
  target     = "cors_php_fpm_slim"
  tags       = [image("php-fpm-slim")]
  cache-from = ["type=registry,ref=${image("php-fpm")}"]
}

target "cli-slim" {
  inherits   = ["_php"]
  target     = "cors_php_cli_slim"
  tags       = [image("php-cli-slim")]
  cache-from = ["type=registry,ref=${image("php-fpm")}"]
}
