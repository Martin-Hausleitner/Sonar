#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

DEVICE_A="${DEVICE_A:-38D0B930-6B32-4F07-B170-845A120C2516}"
DEVICE_B="${DEVICE_B:-97D9490F-66CA-44A3-9A42-693CC113BB80}"
BUNDLE_ID="${BUNDLE_ID:-app.sonar.ios}"
PORT="${SONAR_RELAY_PORT:-8787}"
RELAY_URL="http://127.0.0.1:${PORT}"
DERIVED_DATA="${DERIVED_DATA:-build/e2e/DerivedData}"
APP_PATH="${DERIVED_DATA}/Build/Products/Debug-iphonesimulator/Sonar.app"
OUT_DIR="${OUT_DIR:-build/e2e/simulator-relay-run}"

mkdir -p "$OUT_DIR/screens"
OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd)"
rm -f \
  "$OUT_DIR"/build.log \
  "$OUT_DIR"/relay.log \
  "$OUT_DIR"/*.launch.log \
  "$OUT_DIR"/state.json \
  "$OUT_DIR"/summary.md \
  "$OUT_DIR"/screens/*.png

python3 scripts/e2e/simulator_relay.py --host 127.0.0.1 --port "$PORT" >"$OUT_DIR/relay.log" 2>&1 &
RELAY_PID=$!
cleanup() {
  kill "$RELAY_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 1

grant_speech_recognition() {
  local device="$1"
  local db="${HOME}/Library/Developer/CoreSimulator/Devices/${device}/data/Library/TCC/TCC.db"
  [[ -f "$db" ]] || return 0

  sqlite3 "$db" <<SQL
INSERT OR REPLACE INTO access (
  service,
  client,
  client_type,
  auth_value,
  auth_reason,
  auth_version,
  indirect_object_identifier,
  flags,
  last_modified,
  last_reminded
) VALUES (
  'kTCCServiceSpeechRecognition',
  '${BUNDLE_ID}',
  0,
  2,
  4,
  1,
  'UNUSED',
  0,
  CAST(strftime('%s','now') AS INTEGER),
  CAST(strftime('%s','now') AS INTEGER)
);
SQL

  xcrun simctl spawn "$device" launchctl kickstart -k gui/501/com.apple.tccd >/dev/null 2>&1 || true
  xcrun simctl spawn "$device" launchctl kickstart -k user/501/com.apple.tccd >/dev/null 2>&1 || true
}

xcodebuild \
  -project Sonar.xcodeproj \
  -scheme Sonar \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${DEVICE_A}" \
  -derivedDataPath "$DERIVED_DATA" \
  build | tee "$OUT_DIR/build.log"

for device in "$DEVICE_A" "$DEVICE_B"; do
  xcrun simctl boot "$device" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$device" -b
  xcrun simctl terminate "$device" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$device" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl privacy "$device" reset all "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$device" "$APP_PATH"
  xcrun simctl privacy "$device" grant microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
  grant_speech_recognition "$device"
  xcrun simctl spawn "$device" defaults write "$BUNDLE_ID" sonar.onboarded -bool YES
done

launch_device() {
  local device="$1"
  local name="$2"
  local suffix="${device:0:6}"
  xcrun simctl boot "$device" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$device" -b
  SIMCTL_CHILD_SONAR_TEST_DEVICE_ID="${name}-${suffix}" \
  SIMCTL_CHILD_SONAR_TEST_DEVICE_NAME="$name" \
  SIMCTL_CHILD_SONAR_SIM_RELAY_URL="$RELAY_URL" \
  SIMCTL_CHILD_SONAR_AUTOSTART_SESSION=1 \
  xcrun simctl launch \
    --terminate-running-process \
    "$device" "$BUNDLE_ID" | tee "$OUT_DIR/${name}.launch.log"
}

launch_device "$DEVICE_A" "SIM-A"
launch_device "$DEVICE_B" "SIM-B"

sleep 8

python3 - "$RELAY_URL" "$OUT_DIR/state.json" <<'PY'
import json
import sys
import urllib.request

relay_url, out_path = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(relay_url + "/api/state", timeout=3) as response:
    state = json.loads(response.read().decode("utf-8"))
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(state, handle, indent=2, sort_keys=True)
if len(state.get("devices", [])) < 2:
    raise SystemExit(f"expected 2 relay devices, got {len(state.get('devices', []))}")
print(json.dumps({
    "devices": [d["name"] for d in state["devices"]],
    "frameCount": state.get("frameCount", 0),
    "serverSeq": state.get("serverSeq", 0),
}, sort_keys=True))
PY

xcrun simctl io "$DEVICE_A" screenshot --type=png "$OUT_DIR_ABS/screens/SIM-A-session.png" 2>&1
xcrun simctl io "$DEVICE_B" screenshot --type=png "$OUT_DIR_ABS/screens/SIM-B-session.png" 2>&1

cat >"$OUT_DIR/summary.md" <<EOF
# Sonar Simulator Relay E2E

- Relay: ${RELAY_URL}
- Device A: ${DEVICE_A}
- Device B: ${DEVICE_B}
- App: ${APP_PATH}
- State: ${OUT_DIR}/state.json
- Screenshots:
  - ${OUT_DIR_ABS}/screens/SIM-A-session.png
  - ${OUT_DIR_ABS}/screens/SIM-B-session.png

This run proves fresh install, launch, simulator identity, relay registration,
and two-simulator peer visibility. It does not prove real Bluetooth, AWDL, UWB,
AirPods, or acoustic hardware behavior.
EOF

echo "Simulator relay E2E summary: ${OUT_DIR}/summary.md"
