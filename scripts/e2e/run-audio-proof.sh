#!/usr/bin/env bash
# Two-simulator audio-path proof for Sonar.
#
# Extends run-simulator-e2e.sh's identity/frame assertions with a REAL signal
# proof: a known 880 Hz tone is injected digitally into both simulators'
# microphone (BlackHole 2ch loopback — no room acoustics), and the run then
# proves, with captured data, that the tone leaves instance A as Opus frames,
# crosses the relay, and is decoded + scheduled for playback on instance B:
#
#   1. relay wiretap  -> all routed AudioFrames (scripts/e2e/relay_wiretap.py)
#   2. offline decode -> frames from A Opus-decoded back to WAV
#                        (scripts/e2e/decode_relay_frames.swift)
#   3. tone analysis  -> Goertzel check that the WAV contains the 880 Hz tone
#                        (scripts/e2e/analyze_tone.py)
#   4. B-side log     -> `log stream` on simulator B capturing the app's
#                        "playback inbound seq=… rms=…" receive-chain evidence
#                        (SessionCoordinator.decodeAndSchedule)
#   5. screenshots    -> both simulators + side-by-side composite
#
# Requirements: BlackHole 2ch + SwitchAudioSource installed, app already built
# by run-simulator-e2e.sh (or it builds here), relay port free.
#
# STATUS 2026-08-10: expected RED until openspec .../sonar-live-audio-e2e
# tasks.md §1.6 lands — simulator-relay mode currently sends only a synthetic
# keepalive payload, never real audio (SessionCoordinator.swift:500-559), so
# the decode step fails with 0 decodable frames. That failure is the honest
# result, not a harness bug. See docs/e2e-simulator-relay.md "Known Gap".
#
# Usage: scripts/e2e/run-audio-proof.sh
#   DEVICE_A / DEVICE_B         override simulator UDIDs
#   TONE_HZ (880) TONE_SECONDS (15)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

BUNDLE_ID="${BUNDLE_ID:-app.sonar.ios}"
PORT="${SONAR_RELAY_PORT:-8787}"
RELAY_URL="http://127.0.0.1:${PORT}"
DERIVED_DATA="${DERIVED_DATA:-build/e2e/DerivedData}"
APP_PATH="${DERIVED_DATA}/Build/Products/Debug-iphonesimulator/Sonar.app"
OUT_DIR="${OUT_DIR:-build/e2e/audio-proof-run}"
TONE_HZ="${TONE_HZ:-880}"
TONE_SECONDS="${TONE_SECONDS:-15}"
STAMP="$(date +%Y-%m-%d)"

DEVICE_A="${DEVICE_A:?set DEVICE_A to a booted-able iPhone simulator UDID}"
DEVICE_B="${DEVICE_B:?set DEVICE_B to a second iPhone simulator UDID}"
[[ "$DEVICE_A" != "$DEVICE_B" ]] || { echo "DEVICE_A and DEVICE_B must differ" >&2; exit 1; }

command -v SwitchAudioSource >/dev/null || { echo "SwitchAudioSource missing (brew install switchaudio-osx)" >&2; exit 1; }
SwitchAudioSource -a -t input | grep -q "BlackHole 2ch" || { echo "BlackHole 2ch missing (brew install blackhole-2ch)" >&2; exit 1; }

mkdir -p "$OUT_DIR/screens" evidence/audio evidence/logs evidence/screenshots
OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd)"

# ---------------------------------------------------------------- build (reuse)
if [[ ! -d "$APP_PATH" ]]; then
  xcodebuild \
    -project Sonar.xcodeproj -scheme Sonar -configuration Debug \
    -destination "platform=iOS Simulator,id=${DEVICE_A}" \
    -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
    -derivedDataPath "$DERIVED_DATA" build >"$OUT_DIR/build.log" 2>&1
fi

# ---------------------------------------------------------------- audio routing
SAVED_OUTPUT="$(SwitchAudioSource -c -t output)"
SAVED_INPUT="$(SwitchAudioSource -c -t input)"
restore_audio() {
  SwitchAudioSource -t output -s "$SAVED_OUTPUT" >/dev/null 2>&1 || true
  SwitchAudioSource -t input -s "$SAVED_INPUT" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- relay
python3 scripts/e2e/simulator_relay.py --host 127.0.0.1 --port "$PORT" >"$OUT_DIR/relay.log" 2>&1 &
RELAY_PID=$!

LOG_PIDS=()
AFPLAY_PID=""
cleanup() {
  restore_audio
  [[ -n "$AFPLAY_PID" ]] && kill "$AFPLAY_PID" >/dev/null 2>&1 || true
  for pid in "${LOG_PIDS[@]:-}"; do kill "$pid" >/dev/null 2>&1 || true; done
  kill "$RELAY_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
sleep 1

# Route BEFORE launch so the simulators bind BlackHole as their mic source.
SwitchAudioSource -t input -s "BlackHole 2ch" >/dev/null
SwitchAudioSource -t output -s "BlackHole 2ch" >/dev/null

# ---------------------------------------------------------------- tone file
ffmpeg -y -f lavfi -i "sine=frequency=${TONE_HZ}:sample_rate=48000:duration=${TONE_SECONDS}" \
  -ac 1 -filter:a "volume=0.7" "$OUT_DIR/tone-${TONE_HZ}hz.wav" >/dev/null 2>&1

# ---------------------------------------------------------------- sims + app
for device in "$DEVICE_A" "$DEVICE_B"; do
  xcrun simctl boot "$device" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$device" -b
  xcrun simctl terminate "$device" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$device" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$device" "$APP_PATH"
  xcrun simctl privacy "$device" grant microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl spawn "$device" defaults write "$BUNDLE_ID" sonar.onboarded -bool YES
done

start_log_stream() {
  local device="$1" label="$2"
  xcrun simctl spawn "$device" log stream --level=info --style=compact \
    --predicate 'subsystem == "app.sonar.ios"' \
    >"evidence/logs/${STAMP}-sim-relay-${label}.log" 2>&1 &
  LOG_PIDS+=("$!")
}
start_log_stream "$DEVICE_A" "SIM-A"
start_log_stream "$DEVICE_B" "SIM-B"

launch_device() {
  local device="$1" name="$2"
  local suffix="${device:0:6}"
  SIMCTL_CHILD_SONAR_TEST_DEVICE_ID="${name}-${suffix}" \
  SIMCTL_CHILD_SONAR_TEST_DEVICE_NAME="$name" \
  SIMCTL_CHILD_SONAR_SIM_RELAY_URL="$RELAY_URL" \
  SIMCTL_CHILD_SONAR_AUTOSTART_SESSION=1 \
  xcrun simctl launch --terminate-running-process "$device" "$BUNDLE_ID" >"$OUT_DIR/${name}.launch.log"
}
launch_device "$DEVICE_A" "SIM-A"
launch_device "$DEVICE_B" "SIM-B"

# ---------------------------------------------------------------- wait for loop
echo "waiting for both devices + first routed frames..."
python3 - "$RELAY_URL" <<'PY'
import json, sys, time, urllib.request
relay = sys.argv[1]
deadline = time.time() + 90
while time.time() < deadline:
    with urllib.request.urlopen(relay + "/api/state", timeout=3) as response:
        state = json.loads(response.read().decode("utf-8"))
    if len(state.get("devices", [])) >= 2 and len(state.get("frameCountsBySource", {})) >= 2:
        print("relay live:", json.dumps(state["frameCountsBySource"]))
        sys.exit(0)
    time.sleep(2)
sys.exit("timeout: relay never saw 2 devices with frames from both")
PY

# ---------------------------------------------------------------- inject tone
echo "injecting ${TONE_HZ} Hz tone for ${TONE_SECONDS}s via BlackHole..."
afplay "$OUT_DIR/tone-${TONE_HZ}hz.wav" &
AFPLAY_PID=$!
wait "$AFPLAY_PID"
AFPLAY_PID=""
sleep 2

# ---------------------------------------------------------------- capture
python3 scripts/e2e/relay_wiretap.py --relay-url "$RELAY_URL" \
  --out "evidence/logs/${STAMP}-sim-relay-wiretap.json" | tee "$OUT_DIR/wiretap-summary.json"

xcrun simctl io "$DEVICE_A" screenshot --type=png "evidence/screenshots/${STAMP}-sim-relay-SIM-A.png"
xcrun simctl io "$DEVICE_B" screenshot --type=png "evidence/screenshots/${STAMP}-sim-relay-SIM-B.png"
ffmpeg -y -i "evidence/screenshots/${STAMP}-sim-relay-SIM-A.png" \
       -i "evidence/screenshots/${STAMP}-sim-relay-SIM-B.png" \
       -filter_complex "hstack=inputs=2" \
       "evidence/screenshots/${STAMP}-sim-relay-side-by-side.png" >/dev/null 2>&1

# Stop log streams + restore audio before offline analysis.
for pid in "${LOG_PIDS[@]:-}"; do kill "$pid" >/dev/null 2>&1 || true; done
LOG_PIDS=()
restore_audio

# ---------------------------------------------------------------- decode + verify
A_ID="SIM-A-${DEVICE_A:0:6}"
B_ID="SIM-B-${DEVICE_B:0:6}"
swift scripts/e2e/decode_relay_frames.swift \
  --in "evidence/logs/${STAMP}-sim-relay-wiretap.json" \
  --source "$A_ID" \
  --out "evidence/audio/${STAMP}-sim-relay-decoded-from-SIM-A.wav" | tee "$OUT_DIR/decode-A.json"
swift scripts/e2e/decode_relay_frames.swift \
  --in "evidence/logs/${STAMP}-sim-relay-wiretap.json" \
  --source "$B_ID" \
  --out "evidence/audio/${STAMP}-sim-relay-decoded-from-SIM-B.wav" | tee "$OUT_DIR/decode-B.json"

python3 scripts/e2e/analyze_tone.py "evidence/audio/${STAMP}-sim-relay-decoded-from-SIM-A.wav" \
  --tone-hz "$TONE_HZ" | tee "$OUT_DIR/tone-analysis-A.json"
python3 scripts/e2e/analyze_tone.py "evidence/audio/${STAMP}-sim-relay-decoded-from-SIM-B.wav" \
  --tone-hz "$TONE_HZ" | tee "$OUT_DIR/tone-analysis-B.json"

grep -c "playback inbound" "evidence/logs/${STAMP}-sim-relay-SIM-B.log" >/dev/null \
  || { echo "FAIL: no receive-chain playback log lines on SIM-B" >&2; exit 1; }

echo
echo "audio-proof PASS"
echo "  wiretap:      evidence/logs/${STAMP}-sim-relay-wiretap.json"
echo "  decoded WAVs: evidence/audio/${STAMP}-sim-relay-decoded-from-SIM-{A,B}.wav"
echo "  B-side log:   evidence/logs/${STAMP}-sim-relay-SIM-B.log (playback inbound lines)"
echo "  screenshots:  evidence/screenshots/${STAMP}-sim-relay-*.png"
