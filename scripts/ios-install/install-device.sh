#!/usr/bin/env bash
# install-device.sh — Baut Sonar signiert und installiert es auf einem iPhone.
#
# Usage: scripts/ios-install/install-device.sh <UDID> [TEAM_ID]
#   UDID     Geräte-UDID aus `xcrun devicectl list devices`
#   TEAM_ID  Apple Developer Team (Default: TH2WQG73S9 = Martin)
#
# Ablauf: xcodegen generate → xcodebuild (id=UDID, -allowProvisioningUpdates,
# DEVELOPMENT_TEAM) → devicectl install + launch + Screenshot nach
# evidence/ios-install/. Idempotent — kann beliebig oft laufen.
#
# Voraussetzung: scripts/ios-install/preflight.sh ist grün (Apple-Account in
# Xcode vorhanden, Gerät verbunden + vertraut + Entwicklermodus an).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

UDID="${1:-}"
TEAM_ID="${2:-TH2WQG73S9}"
BUNDLE_ID="app.sonar.ios"
SCHEME="Sonar"
PROJECT="Sonar.xcodeproj"
DERIVED_DATA="build/device/DerivedData"
EVIDENCE_DIR="evidence/ios-install"
STAMP="$(date '+%Y-%m-%d_%H%M')"

if [[ -z "$UDID" ]]; then
  echo "🔴 Usage: $0 <UDID> [TEAM_ID]" >&2
  echo "   Geräte anzeigen: xcrun devicectl list devices" >&2
  exit 2
fi

echo "== Sonar Device-Install: UDID=$UDID TEAM=$TEAM_ID =="

# 0. Gerät erreichbar?
if ! xcrun devicectl list devices 2>/dev/null | grep -q "$UDID"; then
  echo "🔴 Gerät $UDID nicht in devicectl-Liste. USB anstecken, entsperren," >&2
  echo "   'Vertrauen' tippen, dann erneut. (preflight.sh für Details.)" >&2
  exit 1
fi

# 1. Projekt generieren (idempotent)
echo "-- xcodegen generate --"
xcodegen generate

# 2. Signierter Device-Build
echo "-- xcodebuild (signiert, Team $TEAM_ID) --"
if ! xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    -xcconfig sonar-device.xcconfig \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    build; then
  echo "🔴 Build fehlgeschlagen. Häufigste Ursachen:" >&2
  echo "   - Kein Apple-Account in Xcode (Xcode → Settings → Accounts → '+')" >&2
  echo "   - Free-Provisioning-Limit (max 3 App-IDs / 7-Tage-Zertifikat)" >&2
  echo "   - Gerät gesperrt / Vertrauen fehlt" >&2
  exit 1
fi

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/Sonar.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "🔴 App-Bundle fehlt: $APP_PATH" >&2
  exit 1
fi

# 3. Install
echo "-- devicectl install --"
if ! xcrun devicectl device install app --device "$UDID" "$APP_PATH"; then
  echo "🔴 Install fehlgeschlagen. Entwicklermodus an? Gerät entsperrt?" >&2
  exit 1
fi

# 4. Launch
echo "-- devicectl launch $BUNDLE_ID --"
if ! xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID"; then
  echo "🔴 Launch fehlgeschlagen. Auf dem Gerät ggf. 'Nicht vertrauenswürdiger" >&2
  echo "   Entwickler' bestätigen: Einstellungen → Allgemein → VPN & Geräte-" >&2
  echo "   verwaltung → Entwickler-App → Vertrauen. Dann erneut ausführen." >&2
  exit 1
fi

# 5. Screenshot-Beweis (idevicescreenshot, USB nötig)
mkdir -p "$EVIDENCE_DIR"
SHOT="$EVIDENCE_DIR/${STAMP}_device-${UDID:0:8}-launch.png"
echo "-- Screenshot → $SHOT --"
sleep 3
if command -v idevicescreenshot >/dev/null 2>&1 && idevicescreenshot -u "$UDID" "$SHOT" 2>/dev/null; then
  echo "✅ Screenshot: $SHOT"
else
  echo "🟠 Kein Screenshot möglich (idevicescreenshot fehlgeschlagen/fehlt —"
  echo "   braucht USB + Developer-Image). App läuft trotzdem; Beweis manuell"
  echo "   am Gerät: Screenshot machen und nach $EVIDENCE_DIR kopieren."
fi

echo "== ✅ FERTIG: Sonar installiert + gestartet auf $UDID (Team $TEAM_ID) =="
echo "   Hinweis Free-Provisioning: Signatur läuft nach 7 Tagen ab — dann"
echo "   dieses Script einfach erneut ausführen."
