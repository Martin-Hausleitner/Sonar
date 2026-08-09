## Why

Sonar pairs two iPhones over MultipeerConnectivity (MPC) and both devices can
see each other, but audio does not play back live end-to-end — the capture →
encode → transport → decode → playback loop does not close. Three concrete
defects were found by reading the current code:

1. `sonar/Resources/Info.plist` only declares `NSBonjourServices` =
   `_sonar-mpc._tcp` — the matching `_sonar-mpc._udp` entry required by
   `MCNearbyServiceAdvertiser`/`MCNearbyServiceBrowser` for full Bonjour
   resolution is missing, which can leave peers "visible" (via Bluetooth/other
   discovery) while the MPC session over Bonjour/Wi-Fi fails to fully resolve
   or degrades to a broken transport.
2. `AudioSessionPolicy.categoryOptions` in `sonar/Core/Audio/AudioEngine.swift`
   sets `.allowAirPlay`, `.allowBluetooth`, `.mixWithOthers` but never
   `.defaultToSpeaker` — with `.playAndRecord` and no override, iOS routes
   playback to the earpiece by default on many routes, so remote audio can be
   physically inaudible even when frames are being decoded correctly.
3. In `sonar/Core/Coordinator/SessionCoordinator.swift:387`, the capture-chain
   calls `if let data = try? encoder.encode(buffer) { … }` — any Opus
   encode failure (e.g. a format/frame-size mismatch between the mic tap's
   native `engine.inputNode.inputFormat(forBus: 0)` buffer, installed in
   `AudioEngine.prepare()` at `sonar/Core/Audio/AudioEngine.swift:117-125`,
   and the encoder's fixed `pcmFormat`/`samplesPerFrame` expectations in
   `sonar/Core/Audio/OpusCoder.swift`) is silently swallowed. No frame is
   sent and nothing is logged, so the sender-side of the loop can fail
   completely without any visible error.

Together these make it plausible that peers "see" each other (mDNS/NI/BLE
discovery working) while the actual audio loop is silently broken on one or
more of: transport establishment, output routing, and/or encode. This change
fixes all three, proves the fix with real recordings from two physical
devices (not simulators, not mocked data), and adds Soniox-based live
transcription so both participants also see a live transcript during the
call.

## What Changes

- **Fix MPC/Bonjour transport**: add the missing `_sonar-mpc._udp` entry to
  `NSBonjourServices` in `sonar/Resources/Info.plist` (or otherwise align the
  MPC service-type/Bonjour declaration so advertiser/browser resolve
  reliably), and verify actual `MCSessionState.connected` transitions are
  reached on both peers, not just discovery/found-peer callbacks.
- **Fix audio output routing**: set `.defaultToSpeaker` (or the appropriate
  documented category option) in `AudioSessionPolicy.categoryOptions` /
  `AudioEngine` so decoded remote audio is routed to a route the user can
  actually hear (speaker/AirPods/Bluetooth), not silently to the earpiece.
- **Fix silent Opus encode failures**: replace the swallowing
  `try? encoder.encode(buffer)` in `SessionCoordinator.swift:387` with error
  handling that surfaces/logs the failure (e.g. `os.Logger` + a metrics
  counter) and reconcile the mic tap's buffer format/frame size
  (`AudioEngine.prepare()`) with what `OpusCoder` expects, so encode either
  always succeeds for the negotiated hardware format or fails loudly instead
  of silently dropping every frame.
- **Add/extend unit tests** covering: Bonjour/Info.plist service-type
  consistency with `NearTransport`'s `serviceType`, `AudioSessionPolicy`
  category options including `.defaultToSpeaker`, and `OpusCoder`
  encode/decode round-trips against the actual mic-tap input format (not just
  the coder's own idealized format).
- **E2E proof with two physical iPhones** (iPhone 17 Pro + iPhone15,2): build,
  install via `devicectl`, run a live session, and capture real screen +
  audio recordings on both devices as evidence that speech on device A is
  heard on device B and vice versa.
- **New capability: Soniox live transcription**. Integrate the
  reverse-engineered Soniox streaming API (model `stt-rt-v5`, multi-speaker
  diarization, as reverse-engineered in the `soniox-route-lab` repo) as a
  live transcription engine so a live transcript is shown on-device during
  the call.
- **Report**: `docs/SONA-E2E-REPORT.md` documenting each step
  (✅/🔴) with embedded/linked evidence.

## Capabilities

### New Capabilities
- `live-audio-loop-e2e`: end-to-end proof obligation that two physical
  devices, once paired via MPC, actually hear each other's live audio
  (capture → encode → transport → decode → route to an audible output).
- `soniox-live-transcription`: live speech-to-text transcription of the
  active call using the reverse-engineered Soniox streaming API
  (`stt-rt-v5`, multi-speaker diarization), surfaced in the UI while the
  call is active.

### Modified Capabilities
- `mpc-transport`: `NearTransport`'s Bonjour/MPC service-type declaration
  and connection-state handling must guarantee peers reach
  `MCSessionState.connected`, not just discovery.
- `audio-session-routing`: `AudioSessionPolicy`/`AudioEngine` must route
  playback to an audible output by default (not silently to the earpiece).
- `opus-codec-pipeline`: capture → encode path must not silently drop
  frames on encode failure; failures must be observable (logged/metriced)
  and the mic tap's buffer format must be reconciled with the encoder's
  expected PCM format.

(No pre-existing `openspec/specs/` directory exists yet in this repo — all of
the above are treated as new capability specs under this change; there is
nothing to diff against.)

## Impact

- `sonar/Resources/Info.plist` (`NSBonjourServices`)
- `sonar/Core/Transport/NearTransport.swift` (MPC advertiser/browser/session)
- `sonar/Core/Audio/AudioEngine.swift` (`AudioSessionPolicy`, mic tap install)
- `sonar/Core/Audio/OpusCoder.swift` (encode/decode format handling)
- `sonar/Core/Coordinator/SessionCoordinator.swift` (capture-chain error
  handling around `encoder.encode`)
- New: Soniox live-transcription client/integration (new files under
  `sonar/Core/Transcription/` or similar, alongside the existing
  `LocalModelManager.swift`)
- `sonarTests/` (new/updated unit tests)
- Two physical devices: iPhone 17 Pro, iPhone15,2 (owned by Felix, requires
  device unlocked/connected — tracked as a blocker if unavailable)
- New: `docs/SONA-E2E-REPORT.md`, `evidence/` (screen + audio recordings)
- Branch: `feat/live-audio-e2e`
