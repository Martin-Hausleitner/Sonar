# Hardware Connection Verification

Run this on two physical iPhones with the same Sonar build installed. The
simulator relay E2E proves app launch, identity, and frame plumbing; this
checklist proves the real radios and external services.

## AWDL / Multipeer

1. Turn Wi-Fi and Bluetooth on for both devices.
2. Launch Sonar on both devices.
3. Start a session on both devices.
4. Pass criteria:
   - Both devices show the peer name.
   - Both devices show active path `AWDL · Lokal`.
   - Speaking into A produces remote input activity or playback on B.
   - Speaking into B produces remote input activity or playback on A.

## QR Targeting

1. On device A open Verbinden -> Anzeigen.
2. On device B open Verbinden -> Scannen and scan A.
3. Place a third Sonar device nearby.
4. Pass criteria:
   - B connects to A, not the third device.
   - The third device does not become `peerOnline` on A or B.

## BLE

1. Turn Wi-Fi off on both devices.
2. Keep Bluetooth on.
3. Launch Sonar and start a session.
4. Pass criteria:
   - Both devices show active path `Bluetooth`.
   - A-to-B and B-to-A frames or audio activity are visible.

## Tailscale

1. Put both phones in the same Tailnet.
2. Verify both have `100.64.0.0/10` Tailscale IPs.
3. Scan QR from A on B.
4. Pass criteria:
   - Active path becomes `Tailscale`.
   - A-to-B and B-to-A frames or audio activity are visible.

## Internet / LiveKit

1. Start `sonar-server` with valid LiveKit credentials.
2. Launch both apps with `SONAR_LIVEKIT_URL`, `SONAR_TOKEN_SERVER_URL`, and the same `SONAR_LIVEKIT_ROOM`.
3. Put devices on different networks.
4. Pass criteria:
   - Active path becomes `Internet`.
   - Both devices exchange `sonar.audio` data channel frames.
