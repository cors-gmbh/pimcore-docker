// Builds both variants of one PHP/Alpine combination in a single buildx
// invocation so they share layers (pimcore = pimcore-slim + LibreOffice).
//
// Local usage:
//   docker buildx bake --load                                 # 8.4 / alpine 3.24, both variants
//   docker buildx bake --load pimcore-slim
//   PHP_VERSION=8.5 ALPINE_VERSION=3.23 docker buildx bake --load pimcore
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
  targets = ["pimcore", "pimcore-slim"]
}

target "_php" {
  context    = "."
  dockerfile = "Dockerfile"
  args = {
    PHP_VERSION    = PHP_VERSION
    ALPINE_VERSION = ALPINE_VERSION
  }
  cache-from = ["type=registry,ref=${image("pimcore")}"]
  cache-to   = ["type=inline"]
}

target "pimcore" {
  inherits = ["_php"]
  target   = "cors_pimcore"
  tags     = [image("pimcore")]
}

target "pimcore-slim" {
  inherits = ["_php"]
  target   = "cors_pimcore_base"
  tags     = [image("pimcore-slim")]
}
