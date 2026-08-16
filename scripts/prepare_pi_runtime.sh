#!/bin/bash
set -euo pipefail

PI_VERSION="0.72.1"
PI_ARCHIVE_SHA256="40b2f027fc0f581317072921bf2e7ddfec871c3a4e94b73c39d73fc2abc5e517"
PI_EXECUTABLE_SHA256="d2ab03267a9d13d029195aa374ecfe9bd0305e3fcf120c92c96bedfac25bd2dc"
PI_URL="https://github.com/earendil-works/pi/releases/download/v${PI_VERSION}/pi-darwin-arm64.tar.gz"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="$PROJECT_DIR/Whale/Resources/Pi/pi"
EXECUTABLE="$DESTINATION/pi"

sha256() {
  shasum -a 256 "$1" | cut -d ' ' -f 1
}

runtime_is_valid() {
  [ -x "$EXECUTABLE" ] &&
    [ -f "$DESTINATION/package.json" ] &&
    [ -f "$DESTINATION/theme/dark.json" ] &&
    [ "$(sha256 "$EXECUTABLE")" = "$PI_EXECUTABLE_SHA256" ] &&
    [ "$($EXECUTABLE --version)" = "$PI_VERSION" ]
}

if runtime_is_valid; then
  echo "Pi v${PI_VERSION} is ready."
  exit 0
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/whale-pi.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
ARCHIVE="$TEMP_DIR/pi.tar.gz"
EXTRACTED="$TEMP_DIR/extracted"

echo "Downloading Pi v${PI_VERSION} for Apple Silicon..."
if ! curl --fail --location --silent --show-error --output "$ARCHIVE" "$PI_URL"; then
  echo "Pi download failed. Connect to the internet and build again." >&2
  exit 1
fi

if [ "$(sha256 "$ARCHIVE")" != "$PI_ARCHIVE_SHA256" ]; then
  echo "Pi archive checksum does not match the pinned release." >&2
  exit 1
fi

mkdir -p "$EXTRACTED"
tar -xzf "$ARCHIVE" -C "$EXTRACTED"

DOWNLOADED="$EXTRACTED/pi"
DOWNLOADED_EXECUTABLE="$DOWNLOADED/pi"
if [ ! -x "$DOWNLOADED_EXECUTABLE" ] ||
  [ ! -f "$DOWNLOADED/package.json" ] ||
  [ ! -f "$DOWNLOADED/theme/dark.json" ] ||
  [ "$(sha256 "$DOWNLOADED_EXECUTABLE")" != "$PI_EXECUTABLE_SHA256" ] ||
  [ "$($DOWNLOADED_EXECUTABLE --version)" != "$PI_VERSION" ]; then
  echo "Downloaded Pi runtime does not match the pinned release." >&2
  exit 1
fi

if [ "$DESTINATION" != "$PROJECT_DIR/Whale/Resources/Pi/pi" ]; then
  echo "Refusing to replace an unexpected Pi destination: $DESTINATION" >&2
  exit 1
fi

rm -rf "$DESTINATION"
mkdir -p "$(dirname "$DESTINATION")"
mv "$DOWNLOADED" "$DESTINATION"
echo "Pi v${PI_VERSION} is ready."
