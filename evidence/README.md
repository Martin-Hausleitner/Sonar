# evidence/ — 2-iPhone E2E audio test capture tooling

Mac: Darwin 25.3.0. Verified 2026-08-09 against Xcode 16.4 (`xcrun devicectl` 518.33).

Target devices:

| Device | devicectl identifier | classic UDID (libimobiledevice) |
|---|---|---|
| iPhone 17 Pro | `7C62FC1E-FD1A-5EF1-B385-6FB189B54AD9` | `00008150-001C09103C82401C` |
| iPhone15,2 ("iPhone von Felix") | `F2BB4110-7FDA-5381-868C-09032A89A4D6` | `00008120-0004306836C0201E` |

All commands below are wrapped in `./capture.sh` (`chmod +x` already set). Run `cd evidence && ./capture.sh <cmd>`.

## Tool inventory (what exists / what doesn't)

| Capability | Tool | Status |
|---|---|---|
| Device discovery | `xcrun devicectl list devices` | yes — shows both devices as `available` |
| Device screenshot via devicectl | `xcrun devicectl device ...` | **no** — Xcode 16.4's devicectl has NO screenshot/screen-capture subcommand anywhere in its tree (`device`, `device info`, `device process`, `list`, `manage`, `diagnose` all checked) |
| Device screenshot via libimobiledevice | `idevicescreenshot` | installed, **but currently fails**: `Could not start screenshotr service: Invalid service` — needs a Developer Disk Image mounted on the device (open Xcode → Window → Devices and Simulators, select the device once, let Xcode prepare it) |
| Classic-UDID pairing | `idevicepair` | both devices already validated as paired (`idevicepair -u <udid> validate` → SUCCESS) |
| iPhone Mirroring.app | — | present at `/System/Applications/iPhone Mirroring.app`; not opened/tested (interactive) |
| Window-ID lookup for `screencapture -l` | `GetWindowID` | **not installed** — no CLI window-id tool found |
| Mac window screenshot | `screencapture` | yes, built-in; use interactive mode `-i -w` as fallback (click-to-select, no window ID needed) |
| Device syslog | `idevicesyslog` | installed and working (needs the pairing above, which is already done) |
| Device syslog via devicectl | — | **no** `console`/log-stream subcommand exists in devicectl |
| Full diagnostic bundle | `xcrun devicectl device sysdiagnose --device <id>` | exists as heavyweight fallback (full sysdiagnose archive, not screenshots) — not wired into capture.sh, use only if syslog isn't enough |
| Room audio recording | `ffmpeg -f avfoundation` | yes — **tested end-to-end**, records from "MacBook Pro Microphone" (avfoundation index 2 on this Mac) |
| Room audio recording | `sox` | **not installed** |
| Room audio recording | `afrecord` | **not installed** (only `afconvert` exists, which converts, doesn't record) |

Important avfoundation gotcha found during inventory: one of the audio input devices is literally named **"mRNA-Impfchip_R1CK-R0773D Microphone"** — that's the iPhone 17 Pro's own mic exposed to the Mac via Continuity Microphone, **not room audio**. Do not use it for the "both phones audible in the room" proof; use "MacBook Pro Microphone" (built-in) instead. `./capture.sh audio-devices` resolves the correct index dynamically at capture time (indices can shift).

## Working commands

```sh
cd evidence

# Read-only inventory (safe, run anytime)
./capture.sh list-devices     # devicectl + idevice_id, both target devices confirmed present
./capture.sh list-audio       # ffmpeg avfoundation device list
./capture.sh audio-devices    # prints just the resolved "MacBook Pro Microphone" index
./capture.sh pair-check       # idevicepair validate for both devices (both already paired)

# Screenshots (currently BLOCKED, see gap below)
./capture.sh screenshot both        # idevicescreenshot for both devices -> evidence/screenshots/
./capture.sh screenshot 17pro       # single device
./capture.sh screenshot-window      # fallback: interactive screencapture, click the Mirroring window

# Logs — streams idevicesyslog per device, filters case-insensitively on "sonar"
# (covers both "Sonar" and "app.sonar"; idevicesyslog's -m only supports a single
# substring, so this greps a raw capture instead of relying on -m)
./capture.sh logs both 60      # 60s capture from both devices -> evidence/logs/<ts>-*.log (+ .raw.log unfiltered)
./capture.sh logs 17pro 120    # single device, 120s

# Room audio (tested, works)
./capture.sh audio 30          # 30s from MacBook Pro Microphone -> evidence/audio/<ts>-room-audio.wav
```

## Open gaps

1. **Screenshots are blocked right now.** `idevicescreenshot` needs a mounted Developer Disk Image /
   personalized image, which Xcode sets up the first time it "prepares" a device for development
   (Xcode → Window → Devices and Simulators → select device, wait for "ready"). This was **not**
   done during inventory (would count as more than a read-only check). Do this once per device
   before relying on `./capture.sh screenshot`; otherwise use `./capture.sh screenshot-window`
   (requires manually opening iPhone Mirroring.app for the target device first — this script never
   launches it).
2. **No CLI window-id tool installed** (no `GetWindowID`), so the Mirroring-window fallback is
   interactive-click only (`screencapture -i -w`), not scriptable/non-interactive. Installing
   `GetWindowID` (e.g. via a manual build, not in Homebrew) would remove this manual step.
3. **`devicectl` has no screenshot or log-stream subcommand at all** in Xcode 16.4 — confirmed by
   walking the full `--help` tree. All physical-device capture goes through libimobiledevice
   instead of devicectl.
4. **`sysdiagnose` fallback not wired up** (`xcrun devicectl device sysdiagnose --device <id>`) —
   available if `idevicesyslog` proves insufficient (e.g. need full unified log incl. non-Sonar
   context), but it produces a large archive, not a quick targeted log, so it's documented but not
   scripted.
