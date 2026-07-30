#!/usr/bin/env bash
set -euo pipefail

DRUSE_SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DRUSE_ODIN_PREFIX="${DRUSE_ODIN_PREFIX:-/opt/druse}"
DRUSE_PIN_FILE="$DRUSE_SOURCE_ROOT/odin-version.txt"

DRUSE_ODIN_RELEASE="$(sed -n 's/^release=//p' "$DRUSE_PIN_FILE")"
DRUSE_ODIN_COMMIT="$(sed -n 's/^commit=//p' "$DRUSE_PIN_FILE")"
DRUSE_ODIN_ASSET="$(sed -n 's/^linux_amd64_asset=//p' "$DRUSE_PIN_FILE")"
DRUSE_ODIN_DIGEST="$(sed -n 's/^linux_amd64_sha256=//p' "$DRUSE_PIN_FILE")"
DRUSE_ODIN_URL="https://github.com/odin-lang/Odin/releases/download/$DRUSE_ODIN_RELEASE/$DRUSE_ODIN_ASSET"

DRUSE_ODIN_TMP="$(mktemp -d /tmp/druse-install.XXXXXX)"
cleanup() {
  rm -rf -- "$DRUSE_ODIN_TMP"
}
trap cleanup EXIT

curl --retry 5 --retry-all-errors -fsSL "$DRUSE_ODIN_URL" \
  -o "$DRUSE_ODIN_TMP/$DRUSE_ODIN_ASSET"
printf '%s  %s\n' "$DRUSE_ODIN_DIGEST" \
  "$DRUSE_ODIN_TMP/$DRUSE_ODIN_ASSET" | sha256sum -c -

mkdir -p "$DRUSE_ODIN_PREFIX"
tar -xzf "$DRUSE_ODIN_TMP/$DRUSE_ODIN_ASSET" \
  -C "$DRUSE_ODIN_PREFIX" --strip-components=1

DRUSE_ODIN_VERSION="$($DRUSE_ODIN_PREFIX/odin version 2>&1)"
case "$DRUSE_ODIN_VERSION" in
  *"$DRUSE_ODIN_COMMIT"*) ;;
  *)
    echo "ERROR: installed compiler does not match $DRUSE_ODIN_COMMIT" >&2
    exit 1
    ;;
esac

echo "$DRUSE_ODIN_VERSION"
