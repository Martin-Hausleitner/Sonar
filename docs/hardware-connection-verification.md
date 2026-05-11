# Hardware Connection Verification

Run this on two physical iPhones with the same Sonar build installed. The
simulator relay E2E proves app launch, identity, and frame plumbing; this
checklist proves the real radios and external services.

## AWDL / Multipeer

1. Turn Wi-Fi and Bluetooth on for both devices.
2. Launch Sonar on both devices.
3. On both devices open `Verbinden`.
4. On each side, create a local pairing hint by tapping the live peer in
   `Geräte in der Nähe` or a known contact. If using QR instead, scan on one
   side and make sure the receiving side also has a reciprocal hint for the
   scanner (known contact, live-peer tap, or explicit accept path).
5. Start a session on both devices.
6. Pass criteria:
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
   - BLE is not considered proven by this QR scan alone; QR does not carry a reliable CoreBluetooth peripheral identifier for first-contact BLE reconnect.

## BLE

1. Turn Wi-Fi off on both devices.
2. Keep Bluetooth on.
3. Launch Sonar and wait for the peer to appear in "Geräte in der Nähe".
4. Tap the live BLE peer, then start a session.
5. Pass criteria:
   - Both devices show active path `Bluetooth`.
   - A-to-B and B-to-A frames or audio activity are visible.
   - Removing/forgetting the peer while connected drops the active Bluetooth path and no further BLE sends are reported for that peer.

## Tailscale

1. Put both phones in the same Tailnet.
2. Verify both have `100.64.0.0/10` Tailscale IPs.
3. Open `Verbinden` on both devices and select a known contact/live peer on
   both sides, or scan QR from A on B and give A a reciprocal hint for B
   (known contact, live-peer tap, or explicit accept path).
4. Pass criteria:
   - Active path becomes `Tailscale`.
   - A-to-B and B-to-A frames or audio activity are visible.

## Internet / LiveKit

1. Start `sonar-server` with valid LiveKit credentials.
2. Launch both apps with `SONAR_LIVEKIT_URL`, `SONAR_TOKEN_SERVER_URL`, and the same `SONAR_LIVEKIT_ROOM`.
3. Put devices on different networks.
4. Pass criteria:
   - Active path becomes `Internet` only after LiveKit reports a remote participant and the data channel path is connected.
   - Both devices exchange `sonar.audio` data channel frames.

The bundled `sonar-server` token endpoint is for trusted development checks:
`/token` has no app-level authentication, no room allow-list, and no explicit
Sonar TTL policy yet.
