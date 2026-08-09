#!/usr/bin/env zsh
# evidence/capture.sh
#
# Proof/evidence tooling for the 2-iPhone E2E audio test (sonar-live-audio).
# Verified on: Darwin 25.3.0, Xcode 16.4 (xcrun devicectl 518.33),
# libimobiledevice (brew), ffmpeg 7.0 (avfoundation).
#
# Devices (fixed for this test run):
#   iPhone 17 Pro   devicectl-id: 7C62FC1E-FD1A-5EF1-B385-6FB189B54AD9   classic UDID: 00008150-001C09103C82401C
#   iPhone15,2      devicectl-id: F2BB4110-7FDA-5381-868C-09032A89A4D6   classic UDID: 00008120-0004306836C0201E
#
# IMPORTANT / inventory findings (2026-08-09):
#   - `xcrun devicectl` (Xcode 16.4) has NO screenshot/screen-capture subcommand at all
#     (checked full tree: device / device info / device process / list / manage / diagnose).
#     -> screenshots of physical devices must go through libimobiledevice's `idevicescreenshot`,
#        which needs the CLASSIC UDID (not the devicectl UUID) and a completed usbmuxd pairing
#        (`idevicepair pair`, device unlocked, "Trust this computer" tapped) + the device to be
#        reachable over USB (screenshotr service requires it; no dev-disk-image mount needed on
#        modern iOS but pairing + trust IS required).
#   - At inventory time `idevicepair list` was EMPTY on both devices -> pairing has NOT been
#     done yet. Run `idevicepair pair -u <classic-udid>` once per device (unlock + tap Trust)
#     before idevicescreenshot will work. This is NOT done automatically by this script.
#   - iPhone Mirroring.app exists at /System/Applications/iPhone Mirroring.app and was NOT
#     opened/tested (destructive/interactive by nature). If idevicescreenshot fails, fall back
#     to manually opening iPhone Mirroring for the target device, then use the interactive
#     screencapture fallback below (no GetWindowID tool is installed, so this is manual-click).
#   - idevicesyslog can stream/relay a connected, paired device's unified log to a file, filtered
#     with -m/--match. Also needs the pairing above.
#   - For "both iPhones audibly in the room" audio proof, no dedicated "afrecord" exists on this
#     Mac and `sox` is not installed. `ffmpeg` (avfoundation input) IS installed and can record
#     from the Mac's built-in microphone ("MacBook Pro Microphone") which will pick up whatever
#     is audibly playing from both iPhone speakers in the room. NOTE: one of the avfoundation
#     audio inputs was named "mRNA-Impfchip_R1CK-R0773D Microphone" -- that is the iPhone 17 Pro's
#     OWN mic exposed to the Mac via Continuity Microphone, NOT room audio -- do not use that
#     input for the "both phones audible" proof, it would only capture what's near/at that phone.
#
# Usage:
#   ./capture.sh list-devices                     # devicectl + idevice_id inventory (read-only)
#   ./capture.sh list-audio                        # ffmpeg avfoundation device list (read-only)
#   ./capture.sh pair-check                        # idevicepair status for both target devices
#   ./capture.sh screenshot [17pro|15_2|both]       # idevicescreenshot (needs pairing done first)
#   ./capture.sh screenshot-window                  # interactive screencapture fallback (manual click)
#   ./capture.sh logs [17pro|15_2|both] [seconds]   # idevicesyslog -> evidence/logs/, filtered "Sonar"|"app.sonar"
#   ./capture.sh audio <seconds> [device_index]     # ffmpeg avfoundation mic capture -> evidence/audio/
#   ./capture.sh audio-devices                      # just print detected mic device index for "MacBook Pro Microphone"

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

mkdir -p logs screenshots audio

IPHONE17PRO_ID="7C62FC1E-FD1A-5EF1-B385-6FB189B54AD9"
IPHONE17PRO_UDID="00008150-001C09103C82401C"
IPHONE15_2_ID="F2BB4110-7FDA-5381-868C-09032A89A4D6"
IPHONE15_2_UDID="00008120-0004306836C0201E"

ts() { date +%Y%m%d-%H%M%S }

cmd="${1:-}"
shift || true

case "$cmd" in

  list-devices)
    echo "--- xcrun devicectl list devices ---"
    xcrun devicectl list devices
    echo
    echo "--- idevice_id -l (USB, classic UDID) ---"
    idevice_id -l
    echo
    echo "--- idevice_id -l -n (network/paired, classic UDID) ---"
    idevice_id -l -n
    ;;

  list-audio)
    ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A20 "AVFoundation"
    ;;

  audio-devices)
    idx=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 \
      | grep "AVFoundation audio devices" -A20 \
      | grep "MacBook Pro Microphone" \
      | sed -E 's/.*\[([0-9]+)\].*/\1/')
    if [[ -z "$idx" ]]; then
      echo "MacBook Pro Microphone not found in current avfoundation device list. Run '$0 list-audio' to inspect." >&2
      exit 1
    fi
    echo "$idx"
    ;;

  pair-check)
    echo "--- idevicepair list (paired via usbmuxd/lockdown) ---"
    idevicepair list
    echo
    echo "iPhone 17 Pro (classic UDID $IPHONE17PRO_UDID):"
    idevicepair -u "$IPHONE17PRO_UDID" validate 2>&1
    echo
    echo "iPhone15,2 (classic UDID $IPHONE15_2_UDID):"
    idevicepair -u "$IPHONE15_2_UDID" validate 2>&1
    echo
    echo "If either says 'ERROR: Device ... not paired' or similar, run:"
    echo "  idevicepair pair -u <classic-udid>   # then unlock device + tap 'Trust'"
    ;;

  screenshot)
    target="${1:-both}"
    out_ts=$(ts)
    shoot() {
      local udid="$1" label="$2"
      local out="screenshots/${out_ts}-${label}.png"
      echo "Capturing screenshot for $label ($udid) -> $out"
      idevicescreenshot -u "$udid" "$out"
      if [[ $? -ne 0 ]]; then
        echo "idevicescreenshot FAILED for $label. Likely not paired yet (see: ./capture.sh pair-check)" \
             "or screenshotr service unavailable (needs Developer Disk Image mounted -- open Xcode" \
             "Window > Devices and Simulators with the device selected once to trigger this)." \
             "Fall back to: ./capture.sh screenshot-window" >&2
      fi
    }
    case "$target" in
      17pro) shoot "$IPHONE17PRO_UDID" "iphone17pro" ;;
      15_2)  shoot "$IPHONE15_2_UDID" "iphone15-2" ;;
      both)  shoot "$IPHONE17PRO_UDID" "iphone17pro"; shoot "$IPHONE15_2_UDID" "iphone15-2" ;;
      *) echo "usage: $0 screenshot [17pro|15_2|both]" >&2; exit 1 ;;
    esac
    ;;

  screenshot-window)
    # Fallback when idevicescreenshot is unavailable (no pairing / no screenshotr service).
    # Requires the operator to have manually opened iPhone Mirroring.app for the target
    # device beforehand (this script never launches it). Interactive: click the window.
    out="screenshots/$(ts)-mirroring-window.png"
    echo "Click the iPhone Mirroring window to capture it (or press space then click)..."
    screencapture -i -w -o "$out"
    echo "Saved: $out"
    ;;

  logs)
    target="${1:-both}"
    duration="${2:-60}"
    out_ts=$(ts)
    stream() {
      # idevicesyslog's -m/--match only accepts a single substring (no OR of
      # multiple terms), so we let it write unfiltered to a .raw file (own PID
      # tracked directly, no pipe -> no PID-of-last-in-pipeline ambiguity) and
      # grep -i (case-insensitive catches both "Sonar" and "app.sonar") into
      # the final .log file after stopping it.
      local udid="$1" label="$2"
      local raw="logs/${out_ts}-${label}.raw.log"
      echo "Streaming syslog for $label ($udid) -> logs/${out_ts}-${label}.log (${duration}s, grep -i sonar)"
      idevicesyslog -u "$udid" --no-colors -o "$raw" &
      echo $! > "logs/${out_ts}-${label}.pid"
    }
    case "$target" in
      17pro) stream "$IPHONE17PRO_UDID" "iphone17pro" ;;
      15_2)  stream "$IPHONE15_2_UDID" "iphone15-2" ;;
      both)  stream "$IPHONE17PRO_UDID" "iphone17pro"; stream "$IPHONE15_2_UDID" "iphone15-2" ;;
      *) echo "usage: $0 logs [17pro|15_2|both] [seconds]" >&2; exit 1 ;;
    esac
    echo "Recording for ${duration}s, then stopping..."
    sleep "$duration"
    for pidfile in logs/${out_ts}-*.pid; do
      [[ -f "$pidfile" ]] || continue
      kill "$(cat "$pidfile")" 2>/dev/null
      rm -f "$pidfile"
    done
    sleep 1
    for raw in logs/${out_ts}-*.raw.log; do
      [[ -f "$raw" ]] || continue
      grep -i "sonar" "$raw" > "${raw%.raw.log}.log"
    done
    echo "Done. Filtered logs in evidence/logs/${out_ts}-*.log (raw unfiltered in *.raw.log)"
    ;;

  audio)
    duration="${1:-30}"
    device_index="${2:-}"
    if [[ -z "$device_index" ]]; then
      device_index=$("$0" audio-devices) || exit 1
    fi
    out="audio/$(ts)-room-audio.wav"
    echo "Recording ${duration}s from avfoundation audio device [$device_index] (should be 'MacBook Pro Microphone') -> $out"
    ffmpeg -f avfoundation -i ":${device_index}" -t "$duration" "$out"
    echo "Saved: $out"
    ;;

  *)
    echo "usage: $0 {list-devices|list-audio|audio-devices|pair-check|screenshot|screenshot-window|logs|audio} [...]" >&2
    exit 1
    ;;
esac
