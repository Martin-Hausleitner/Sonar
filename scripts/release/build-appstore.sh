#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

TEAM_ID="${TEAM_ID:-FH29968UF7}"
SCHEME="${SCHEME:-Sonar}"
PROJECT="${PROJECT:-Sonar.xcodeproj}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-build/release/Sonar.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-build/release/AppStore}"
EXPORT_OPTIONS="${EXPORT_OPTIONS:-build/release/ExportOptions-app-store-connect.plist}"
DESTINATION="${DESTINATION:-export}"

mkdir -p "$(dirname "$ARCHIVE_PATH")" "$EXPORT_PATH" "$(dirname "$EXPORT_OPTIONS")"

AUTH_ARGS=()
if [[ -n "${ASC_KEY_PATH:-}" || -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" ]]; then
  : "${ASC_KEY_PATH:?Set ASC_KEY_PATH to the App Store Connect .p8 key path}"
  : "${ASC_KEY_ID:?Set ASC_KEY_ID to the App Store Connect key ID}"
  : "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to the App Store Connect issuer ID}"
  AUTH_ARGS+=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

cat >"$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>${DESTINATION}</string>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>uploadSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <true/>
</dict>
</plist>
PLIST

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  "${AUTH_ARGS[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  "${AUTH_ARGS[@]}"

find "$EXPORT_PATH" -maxdepth 1 -type f -name '*.ipa' -print
