#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

SCHEME="${SCHEME:-Sonar}"
PROJECT="${PROJECT:-Sonar.xcodeproj}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-build/release/UnsignedDerivedData}"
PRODUCTS_DIR="${DERIVED_DATA}/Build/Products/Release-iphoneos"
APP_PATH="${PRODUCTS_DIR}/Sonar.app"
OUT_DIR="${OUT_DIR:-build/release/UnsignedIPA}"
IPA_PATH="${OUT_DIR}/Sonar-unsigned.ipa"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/Payload"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle at $APP_PATH" >&2
  exit 1
fi

ditto "$APP_PATH" "$OUT_DIR/Payload/Sonar.app"
(
  cd "$OUT_DIR"
  ditto -c -k --sequesterRsrc --keepParent Payload "$(basename "$IPA_PATH")"
)

echo "$IPA_PATH"
