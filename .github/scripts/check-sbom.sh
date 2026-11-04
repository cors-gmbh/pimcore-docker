#!/usr/bin/env bash
# Checks that Trivy finds the SBOM written by generate-sbom (php/generate-sbom.php) in an image
# and reports the PHP version of the image for it. Trivy silently skips SBOM files it cannot
# parse, so scanning the image is the only reliable check. Also prints the components of the
# SBOM and the vulnerabilities Trivy finds in them.
#
#   .github/scripts/check-sbom.sh <image> [<image> ...]
#
# TRIVY overrides the trivy command, e.g. "docker run --rm ... ghcr.io/aquasecurity/trivy:<version>".
# PLATFORM (e.g. linux/arm64) overrides the platform that is scanned, see platform_of.
set -euo pipefail

TARGET=usr/local/share/sbom/php.cdx.json
TRIVY=${TRIVY:-trivy}

# Trivy scans linux/amd64 of a remote image index unless --platform is given, also on arm64
# runners, and fails for the arm images ("no child with platform linux/amd64 in index"). An
# image pushed by digest is an index with one platform plus attestation manifests: use that one.
# Local images and plain manifests print nothing, Trivy then needs no platform.
platform_of() {
  docker buildx imagetools inspect --raw "$1" 2>/dev/null | jq -r '
    [.manifests[]? | .platform | select(. != null and .architecture != "unknown")
      | "\(.os)/\(.architecture)\(if .variant then "/\(.variant)" else "" end)"]
    | unique | if length == 1 then .[0] else empty end' 2>/dev/null || true
}

failed=0
result=$(mktemp)
trap 'rm -f "$result"' EXIT

for image in "$@"; do
  echo "::group::SBOM of $image"
  platform=${PLATFORM:-$(platform_of "$image")}
  $TRIVY image --quiet --scanners vuln --list-all-pkgs --format json ${platform:+--platform "$platform"} "$image" > "$result"

  php_version=$(jq -r '.Metadata.ImageConfig.config.Env[]? | select(startswith("PHP_VERSION=")) | ltrimstr("PHP_VERSION=")' "$result")
  jq -r --arg target "$TARGET" '
    .Results[]? | select(.Target == $target) | .Type as $type
    | (.Packages[]? | "  \($type) \(.Name) \(.Version)"),
      (.Vulnerabilities[]? | "  \($type) \(.PkgName) \(.InstalledVersion): \(.VulnerabilityID) \(.Severity)")' "$result"
  echo "::endgroup::"

  if [ -z "$php_version" ]; then
    echo "::error::$image: no PHP_VERSION in the image config"
    failed=1
  elif ! jq -e --arg target "$TARGET" '[.Results[]? | select(.Target == $target)] | length > 0' "$result" > /dev/null; then
    echo "::error::$image: Trivy did not detect $TARGET (missing or not a valid CycloneDX file)"
    failed=1
  elif ! jq -e --arg target "$TARGET" --arg version "$php_version" '
      [.Results[]? | select(.Target == $target) | .Packages[]? | select(.Name == "php" and .Version == $version)]
      | length > 0' "$result" > /dev/null; then
    echo "::error::$image: $TARGET does not list php $php_version"
    failed=1
  else
    echo "$image: $TARGET detected, php $php_version," \
      "$(jq --arg target "$TARGET" '[.Results[]? | select(.Target == $target) | .Packages[]?] | length' "$result") components"
  fi
done

exit "$failed"
