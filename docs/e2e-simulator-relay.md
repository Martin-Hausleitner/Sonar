# Simulator Relay E2E

This workflow gives Sonar an honest two-simulator E2E path. It proves app launch,
fresh install, stable simulator identity, peer visibility, and `AudioFrame`
relay plumbing through the normal `MultipathBonder` path. It does not prove real
Bluetooth, AWDL, UWB, AirPods, or acoustic hardware behavior.

## Run The Relay Only

```bash
python3 scripts/e2e/simulator_relay.py --port 8787
```

Open `http://127.0.0.1:8787` to see the dashboard.

Self-test:

```bash
python3 scripts/e2e/simulator_relay.py --self-test
```

Expected output:

```text
self-test passed
```

## Run Fresh-Install Two-Simulator E2E

The script picks two distinct available iPhone simulators. Override selection
with `DEVICE_A` and `DEVICE_B`, or with `SIMULATOR_A_NAME` and
`SIMULATOR_B_NAME`, when a machine needs specific devices.

```bash
scripts/e2e/run-simulator-e2e.sh
```

The script:

- starts the local relay and dashboard on `127.0.0.1:8787`
- builds the Debug simulator app
- boots both simulators
- uninstalls any existing app copy
- installs the fresh build
- grants simulator microphone permission where supported
- grants simulator Speech Recognition in the simulator TCC database because
  `simctl privacy` does not expose that service
- skips onboarding for the test run
- launches both apps with `SONAR_TEST_DEVICE_*`, `SONAR_SIM_RELAY_URL`, and `SONAR_AUTOSTART_SESSION`
- asserts both simulator identities are present and both sides send relayed frames
- captures relay state and screenshots under `build/e2e/simulator-relay-run`

## Pass Criteria

The run counts as a simulator E2E pass when:

- `state.json` contains both `SIM-A` and `SIM-B`
- `state.json` contains at least 10 routed frames
- relay frame events include traffic from both simulator identities
- each app shows its own local identity
- each app sees the other peer through `Simulator Relay`
- screenshots are captured for both devices
- screenshots show no permission dialogs blocking the session UI

The run must still be labelled simulated. Hardware-only proof still requires
real iPhones for Bluetooth, AWDL/Multipeer, UWB, AirPods, and acoustic latency.

## Known Gap: No Real Audio Crosses The Relay (verified 2026-08-10)

The relay E2E above proves identity/peer/frame *plumbing* only. The frames it
routes are **synthetic keepalives, not audio**:

- `SessionCoordinator.startAudioPipeline()` returns early into
  `startSimulatorRelayPipeline()` in simulator-relay mode
  (`sonar/Core/Coordinator/SessionCoordinator.swift:200-205`).
- `startSimulatorRelayPipeline()`
  (`sonar/Core/Coordinator/SessionCoordinator.swift:500-559`) never calls
  `audioEngine.prepare()`, installs no mic-capture sink
  (`audioEngine.captured → encodeAndSend`, only in the non-simulator branch at
  `SessionCoordinator.swift:393`), no receive chain
  (`bonder.inboundFrames → jitterBuffer`, `SessionCoordinator.swift:425`), and
  no playback drain timer (`SessionCoordinator.swift:445`).
- Instead a task sends the constant 27-byte payload
  `"sonar-simulator-relay-frame"` every 500 ms
  (`SessionCoordinator.swift:549-555`).

Measured proof (evidence committed): a full run with an 880 Hz tone injected
into the simulators' microphone routed 369 frames — every single payload was
the 27-byte ASCII keepalive, 0 of 201 SIM-A frames Opus-decodable
(`evidence/logs/2026-08-10-sim-relay-wiretap.json`,
`evidence/logs/2026-08-10-sim-relay-decode-verdict.json`).

Until the simulator-relay mode wires the real capture/encode/receive/playback
chains, an audio-path proof in the simulator is impossible by design. The
ready-made harness for the day that fix lands:

```bash
DEVICE_A=<udid> DEVICE_B=<udid> scripts/e2e/run-audio-proof.sh
```

It injects a known tone (BlackHole loopback), wiretaps the relay
(`scripts/e2e/relay_wiretap.py`), Opus-decodes the routed frames back to WAV
(`scripts/e2e/decode_relay_frames.swift`), verifies the tone spectrally
(`scripts/e2e/analyze_tone.py`), and checks the receiver-side
`playback inbound seq=… rms=…` log line
(`SessionCoordinator.decodeAndSchedule`).
