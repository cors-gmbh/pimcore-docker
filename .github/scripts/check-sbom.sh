#!/usr/bin/env bash
# Checks that Trivy finds the SBOM written by generate-sbom (php/generate-sbom.php) in an image
# and reports the PHP version of the image for it. Trivy silently skips SBOM files it cannot
# parse, so scanning the image is the only reliable check. Also prints the components of the
# SBOM and the vulnerabilities Trivy finds in them.
#
#   .github/scripts/check-sbom.sh <image> [<image> ...]
#
# TRIVY overrides the trivy command, e.g. "docker run --rm ... ghcr.io/aquasecurity/trivy:<version>".
set -euo pipefail

TARGET=usr/local/share/sbom/php.cdx.json
TRIVY=${TRIVY:-trivy}

failed=0
result=$(mktemp)
trap 'rm -f "$result"' EXIT

for image in "$@"; do
  echo "::group::SBOM of $image"
  $TRIVY image --quiet --scanners vuln --list-all-pkgs --format json "$image" > "$result"

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
