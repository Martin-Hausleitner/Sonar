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

The script defaults to the two simulator UDIDs used in the current E2E setup.
Override them with `DEVICE_A` and `DEVICE_B` if needed.

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
- captures relay state and screenshots under `build/e2e/simulator-relay-run`

## Pass Criteria

The run counts as a simulator E2E pass when:

- `state.json` contains both `SIM-A` and `SIM-B`
- each app shows its own local identity
- each app sees the other peer through `Simulator Relay`
- screenshots are captured for both devices
- screenshots show no permission dialogs blocking the session UI

The run must still be labelled simulated. Hardware-only proof still requires
real iPhones for Bluetooth, AWDL/Multipeer, UWB, AirPods, and acoustic latency.
