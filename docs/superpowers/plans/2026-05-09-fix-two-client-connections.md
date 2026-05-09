# Two Client Connections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every advertised two-client connection path either genuinely connect and exchange frames, or be clearly disabled/labelled until it is wired.

**Execution status (2026-05-09):** Implemented and verified in the working tree. The code/docs/test work for Tasks 1-8 is complete, lint is clean, simulator two-client E2E passes, and the full Xcode scheme test passes. The individual `git commit` steps below were intentionally not run because no commit approval was given. Physical AWDL/BLE/UWB proof still requires two real iPhones and should use the hardware checklist added by this plan.

Fresh verification from 2026-05-09:

- `make lint` -> passed; SwiftFormat 0/118 files need formatting, SwiftLint 0 violations, Ruff/ShellCheck/yamllint/actionlint passed.
- `scripts/e2e/run-simulator-e2e.sh` -> passed; relay saw `SIM-A-38D0B9` and `SIM-B-97D949`, `frameCount: 24`, frames from both devices, screenshots written.
- `xcodebuild test -project Sonar.xcodeproj -scheme Sonar -destination 'id=DCF24978-ABA7-4DC1-9E95-D96B0CE16CD4' -only-testing:SonarTests` -> passed; 315 tests, 0 failures.
- `xcodebuild test -project Sonar.xcodeproj -scheme Sonar -destination 'id=DCF24978-ABA7-4DC1-9E95-D96B0CE16CD4'` -> passed; SonarTests 315/315 and SonarUITests 3/3.

Additional connection audit from 2026-05-09:

- Fixed `FarTransport` so a LiveKit room connection alone no longer marks the Internet path connected; at least one remote participant must be present.
- Added regression tests for the LiveKit two-client connection truth.
- `make lint` -> passed.
- Targeted connection tests -> passed; 60 tests, 0 failures.
- `scripts/e2e/run-simulator-e2e.sh` -> passed; relay saw `SIM-A-38D0B9` and `SIM-B-97D949`, `frameCount: 25`, frames from both devices, screenshots written.

**Architecture:** Keep `MultipathBonder` as the single source of active path truth. Remove optimistic UI state from QR confirmation, move all "connected" UI updates behind actual transport signals, and give each transport an explicit, testable handshake/framing contract. Treat Simulator Relay and Tailscale as currently proven paths; fix AWDL invite filtering, BLE bidirectional GATT, and LiveKit/Far startup before claiming those paths work.

**Tech Stack:** Swift 5.10, Combine, MultipeerConnectivity, CoreBluetooth, Network.framework, LiveKit Swift SDK, XCTest, Python simulator relay.

---

## File Structure

- Modify `sonar/UI/PairingView.swift`: QR confirmation should only submit `pendingPairing`; it must not mark a peer online.
- Modify `sonar/Core/Pairing/PairingService.swift`: token acceptance should record pairing intent, token rejection should clear stale pairing UI, and BLE/Tailscale/Near routing should be explicit.
- Modify `sonar/Core/Transport/NearTransport.swift`: add inbound invitation gating, invite de-duplication, and test hooks for decisions without requiring real Multipeer hardware.
- Modify `sonar/Core/Transport/BluetoothMeshTransport.swift`: add real bidirectional frame delivery using central writes plus peripheral notify, and expose `applyPairingToken(_:)` only if it can affect behavior.
- Modify `sonar/Core/Transport/FarTransport.swift`: make configuration/startup observable and testable; keep LiveKit data channel as the internet path.
- Modify `sonar/Core/Coordinator/SessionCoordinator.swift`: configure/start `FarTransport` when a server is available, bind transport truth into `AppState`, and remove stale comments.
- Modify `sonar/App/AppState.swift`: add pairing intent/status fields if needed, but keep `peerOnline` controlled by connected paths.
- Modify `sonar/Core/Transport/MPQUICTransport.swift`: either remove from the app target or mark as experimental/test-only; do not leave a second internet path that is not used.
- Add or modify tests in `sonarTests/PairingServiceTests.swift`, `sonarTests/NearTransportPairingTests.swift`, `sonarTests/BluetoothMeshTransportTests.swift`, `sonarTests/FarTransportTests.swift`, `sonarTests/AppStateConnectionTypeTests.swift`, and `sonarTests/E2ETransportTests.swift`.
- Modify docs in `README.md`, `docs/connection-guide.md`, and `docs/pairing.md` after the code behavior is verified.

---

### Task 1: Stop False "Connected" UI From QR Pairing

**Files:**
- Modify: `sonar/UI/PairingView.swift:216-222`
- Modify: `sonar/Core/Pairing/PairingService.swift:74-100`
- Test: `sonarTests/PairingServiceTests.swift`

- [ ] **Step 1: Write failing tests for expired token cleanup and no optimistic connection**

Add these tests to `PairingServiceTests`:

```swift
func testExpiredTokenClearsStalePeerUI() {
    let appState = AppState()
    let service = makeService()
    service.bind(appState: appState)

    appState.peerOnline = true
    appState.peerName = "Stale Peer"
    appState.peerID = "stale-id"
    appState.peerLastSeen = now

    appState.pendingPairing = makeToken(ageSeconds: 6 * 60)
    drainMain()

    XCTAssertFalse(appState.peerOnline)
    XCTAssertNil(appState.peerName)
    XCTAssertNil(appState.peerID)
    XCTAssertNil(appState.peerLastSeen)
    XCTAssertNil(appState.pendingPairing)
}

func testFreshTokenDoesNotMarkPeerOnlineBeforeTransportConnects() {
    let appState = AppState()
    let service = makeService()
    service.bind(appState: appState)

    appState.pendingPairing = makeToken(id: "peer-A", name: "Alex iPhone", ageSeconds: 10)
    drainMain()

    XCTAssertFalse(appState.peerOnline)
    XCTAssertEqual(appState.peerName, "Alex iPhone")
    XCTAssertEqual(appState.peerID, "peer-A")
    XCTAssertNil(appState.peerLastSeen)
}
```

- [ ] **Step 2: Run tests and verify they fail**

Run:

```bash
xcodebuild test -project Sonar.xcodeproj -scheme Sonar -destination 'id=DCF24978-ABA7-4DC1-9E95-D96B0CE16CD4' -only-testing:SonarTests/PairingServiceTests
```

Expected: `testExpiredTokenClearsStalePeerUI` fails because stale UI remains, and `testFreshTokenDoesNotMarkPeerOnlineBeforeTransportConnects` fails because `peerOnline` is set optimistically.

- [ ] **Step 3: Remove optimistic peer-online writes**

Change `PairingView.applyPairing(_:)` to:

```swift
private func applyPairing(_ token: PairingToken) {
    appState.pendingPairing = token
}
```

Change the accepted-token block in `PairingService.handle(_:)` to:

```swift
appState.peerName = token.name
appState.peerID = token.id
appState.peerOnline = false
appState.peerLastSeen = nil

near?.applyPairingToken(token)
bluetooth?.applyPairingToken(token)
tailscale?.applyPairingToken(token)
```

Change the expired-token block to:

```swift
if age > Self.tokenTTL {
    Log.app.warning("Pairing token expired")
    appState.pendingPairing = nil
    appState.peerName = nil
    appState.peerID = nil
    appState.peerOnline = false
    appState.peerLastSeen = nil
    return
}
```

- [ ] **Step 4: Add Bluetooth compile target method**

Add this no-op method to `BluetoothMeshTransport` for now, so Task 1 compiles and Task 3 can make it meaningful:

```swift
func applyPairingToken(_ token: PairingToken) {
    // BLE currently uses service UUID discovery only. Task 3 makes token hints meaningful.
}
```

- [ ] **Step 5: Run PairingService tests**

Run the same `xcodebuild test ... -only-testing:SonarTests/PairingServiceTests`.

Expected: all `PairingServiceTests` pass. Update existing tests that expected `peerOnline == true` on fresh QR acceptance to expect `false` until a transport path connects.

- [ ] **Step 6: Commit**

```bash
git add sonar/UI/PairingView.swift sonar/Core/Pairing/PairingService.swift sonar/Core/Transport/BluetoothMeshTransport.swift sonarTests/PairingServiceTests.swift
git commit -m "fix: make qr pairing wait for real transport connection"
```

---

### Task 2: Gate AWDL/Multipeer Invitations Both Ways

**Files:**
- Modify: `sonar/Core/Transport/NearTransport.swift:43-218`
- Test: `sonarTests/NearTransportPairingTests.swift`

- [ ] **Step 1: Write failing tests for inbound invitation decisions**

Add pure decision helpers tests to `NearTransportPairingTests`:

```swift
func testInboundInvitationWithoutPairingHintIsAcceptedForAutoDiscovery() {
    XCTAssertTrue(NearTransport.shouldAcceptInvitation(
        currentPairingHint: nil,
        displayName: "Alex iPhone",
        discoveryInfo: nil
    ))
}

func testInboundInvitationWithMismatchedPairingHintIsRejected() {
    let token = makeToken(id: "peer-A", name: "Alex iPhone", host: "alex.local")
    let hint = NearTransport.PairingHint(token: token)

    XCTAssertFalse(NearTransport.shouldAcceptInvitation(
        currentPairingHint: hint,
        displayName: "Mallory iPhone",
        discoveryInfo: ["peerID": "peer-B", "host": "mallory.local"]
    ))
}

func testInboundInvitationWithMatchingPairingHintIsAccepted() {
    let token = makeToken(id: "peer-A", name: "Alex iPhone", host: "alex.local")
    let hint = NearTransport.PairingHint(token: token)

    XCTAssertTrue(NearTransport.shouldAcceptInvitation(
        currentPairingHint: hint,
        displayName: "Anything",
        discoveryInfo: ["peerID": "peer-A"]
    ))
}
```

- [ ] **Step 2: Run tests and verify they fail to compile**

Run:

```bash
xcodebuild test -project Sonar.xcodeproj -scheme Sonar -destination 'id=DCF24978-ABA7-4DC1-9E95-D96B0CE16CD4' -only-testing:SonarTests/NearTransportPairingTests
```

Expected: compile failure because `NearTransport.shouldAcceptInvitation` does not exist.

- [ ] **Step 3: Implement invitation decision helper**

Add this inside `NearTransport`:

```swift
static func shouldAcceptInvitation(
    currentPairingHint: PairingHint?,
    displayName: String,
    discoveryInfo: [String: String]?
) -> Bool {
    guard let currentPairingHint else { return true }
    return currentPairingHint.matches(displayName: displayName, discoveryInfo: discoveryInfo)
}
```

- [ ] **Step 4: Store discovery info by stable key**

Change:

```swift
private var discoveredPeers: [String: DiscoveredPeer] = [:]
```

to:

```swift
private var discoveredPeers: [MCPeerID: DiscoveredPeer] = [:]
```

Then change found/lost peer handling to:

```swift
func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
    discoveredPeers[peerID] = DiscoveredPeer(peerID: peerID, discoveryInfo: info)
    inviteIfAllowed(peerID, discoveryInfo: info)
}

func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    discoveredPeers.removeValue(forKey: peerID)
}
```

- [ ] **Step 5: Gate inbound invitations**

Change `didReceiveInvitationFromPeer` to:

```swift
func advertiser(
    _ advertiser: MCNearbyServiceAdvertiser,
    didReceiveInvitationFromPeer peerID: MCPeerID,
    withContext context: Data?,
    invitationHandler: @escaping (Bool, MCSession?) -> Void
) {
    let discoveryInfo = discoveredPeers[peerID]?.discoveryInfo
    let accept = Self.shouldAcceptInvitation(
        currentPairingHint: currentPairingHint,
        displayName: peerID.displayName,
        discoveryInfo: discoveryInfo
    )
    invitationHandler(accept, accept ? session : nil)
}
```

- [ ] **Step 6: Avoid repeated outbound invites**

Add:

```swift
private var invitedPeerIDs = Set<MCPeerID>()
```

Change `inviteIfAllowed` to:

```swift
private func inviteIfAllowed(_ peerID: MCPeerID, discoveryInfo: [String: String]?) {
    if let hint = currentPairingHint,
       !hint.matches(displayName: peerID.displayName, discoveryInfo: discoveryInfo) {
        return
    }
    guard !invitedPeerIDs.contains(peerID) else { return }
    invitedPeerIDs.insert(peerID)
    browser.invitePeer(peerID, to: session, withContext: nil, timeout: 10)
}
```

Clear `invitedPeerIDs` in `stop()`.

- [ ] **Step 7: Run NearTransport tests**

Run the same `xcodebuild test ... -only-testing:SonarTests/NearTransportPairingTests`.

Expected: all NearTransport pairing tests pass.

- [ ] **Step 8: Commit**

```bash
git add sonar/Core/Transport/NearTransport.swift sonarTests/NearTransportPairingTests.swift
git commit -m "fix: gate multipeer invitations by pairing hint"
```

---

### Task 3: Make BLE Bidirectional Or Stop Advertising It As Working

**Files:**
- Modify: `sonar/Core/Transport/BluetoothMeshTransport.swift`
- Create or modify: `sonarTests/BluetoothMeshTransportTests.swift`
- Modify: `README.md`
- Modify: `docs/connection-guide.md`

- [ ] **Step 1: Add testable BLE packet decode/encode helper**

Create `BluetoothMeshTransportTests.swift` if missing, with:

```swift
import XCTest
@testable import Sonar

final class BluetoothMeshTransportTests: XCTestCase {
    func testBLEFrameRoundTripUsesAudioFrameWireData() {
        let frame = AudioFrame(seq: 99, payload: Data([0x01, 0x02, 0x03]), codec: .opus)

        let encoded = BluetoothMeshTransport.encodeBLEFrame(frame)
        let decoded = BluetoothMeshTransport.decodeBLEFrame(encoded)

        XCTAssertEqual(decoded?.seq, 99)
        XCTAssertEqual(decoded?.payload, Data([0x01, 0x02, 0x03]))
    }

    func testInvalidBLEFrameReturnsNil() {
        XCTAssertNil(BluetoothMeshTransport.decodeBLEFrame(Data([0x00, 0x01])))
    }
}
```

- [ ] **Step 2: Run tests and verify they fail to compile**

Run:

```bash
xcodebuild test -project Sonar.xcodeproj -scheme Sonar -destination 'id=DCF24978-ABA7-4DC1-9E95-D96B0CE16CD4' -only-testing:SonarTests/BluetoothMeshTransportTests
```

Expected: compile failure because helper methods do not exist.

- [ ] **Step 3: Add helper methods**

Add inside `BluetoothMeshTransport`:

```swift
static func encodeBLEFrame(_ frame: AudioFrame) -> Data {
    frame.wireData
}

static func decodeBLEFrame(_ data: Data) -> AudioFrame? {
    AudioFrame(wireData: data)
}
```

- [ ] **Step 4: Add central write path for outbound frames**

Add properties:

```swift
private var writableCharacteristics: [UUID: CBCharacteristic] = [:]
```

Change `send(_:)` to:

```swift
func send(_ frame: AudioFrame) async {
    let data = Self.encodeBLEFrame(frame)
    if let char = audioCharacteristic {
        peripheralManager.updateValue(data, for: char, onSubscribedCentrals: nil)
    }
    for peripheral in connectedPeripherals {
        guard let characteristic = writableCharacteristics[peripheral.identifier] else { continue }
        peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
    }
}
```

Change `didDiscoverCharacteristicsFor` to store write-capable characteristics:

```swift
for char in chars where char.uuid == Self.audioCharUUID {
    if char.properties.contains(.notify) {
        peripheral.setNotifyValue(true, for: char)
    }
    if char.properties.contains(.writeWithoutResponse) || char.properties.contains(.write) {
        writableCharacteristics[peripheral.identifier] = char
    }
}
```

Remove stored characteristic on disconnect:

```swift
writableCharacteristics.removeValue(forKey: peripheral.identifier)
```

- [ ] **Step 5: Add peripheral receive-write handling**

Implement:

```swift
func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
    for request in requests where request.characteristic.uuid == Self.audioCharUUID {
        guard let value = request.value,
              let frame = Self.decodeBLEFrame(value) else {
            peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
            continue
        }
        inboundSubject.send(frame)
        peripheral.respond(to: request, withResult: .success)
    }
}
```

- [ ] **Step 6: Make token hint meaningful or remove it from UI**

If BLE token value remains only diagnostic, update `PairingService` and docs to say BLE uses service discovery, not token targeting. If implementing targeting, add:

```swift
private var targetBLEIdentifier: String?

func applyPairingToken(_ token: PairingToken) {
    targetBLEIdentifier = token.ble
}
```

Then filter discovered peripherals only when `targetBLEIdentifier` matches a known peripheral identifier string. If iOS peripheral identifiers cannot be reliably exchanged before discovery, keep it diagnostic and remove "BLE-Erstkontakt" as a QR guarantee from docs.

- [ ] **Step 7: Run BLE tests and compile the app**

Run:

```bash
xcodebuild test -project Sonar.xcodeproj -scheme Sonar -destination 'id=DCF24978-ABA7-4DC1-9E95-D96B0CE16CD4' -only-testing:SonarTests/BluetoothMeshTransportTests
xcodebuild build -project Sonar.xcodeproj -scheme Sonar -destination 'id=DCF24978-ABA7-4DC1-9E95-D96B0CE16CD4'
```

Expected: tests pass and build succeeds. Hardware verification is still required for real BLE radio behavior.

- [ ] **Step 8: Commit**

```bash
git add sonar/Core/Transport/BluetoothMeshTransport.swift sonarTests/BluetoothMeshTransportTests.swift README.md docs/connection-guide.md
git commit -m "fix: make bluetooth mesh frame flow bidirectional"
```

---

### Task 4: Wire The Internet/LiveKit Far Path Or Hide It

**Files:**
- Modify: `sonar/Core/Transport/FarTransport.swift`
- Modify: `sonar/Core/Coordinator/SessionCoordinator.swift`
- Modify: `sonar/Core/Diagnostics/SonarTestIdentity.swift` if using environment-driven test config
- Test: `sonarTests/FarTransportTests.swift`

- [ ] **Step 1: Decide the configuration source**

Use environment/UserDefaults keys already consistent with test style:

```swift
SONAR_LIVEKIT_URL
SONAR_TOKEN_SERVER_URL
SONAR_LIVEKIT_ROOM
```

Default behavior: if either URL is empty, do not start `FarTransport` and do not list Internet as an available path.

- [ ] **Step 2: Write test for config gating**

Add to `FarTransportTests.swift`:

```swift
@MainActor
final class FarTransportConfigurationTests: XCTestCase {
    func testMissingConfigurationIsNotStartable() {
        let config = FarTransport.Configuration(liveKitURL: "", tokenServerURL: "", roomName: "sonar-main")
        XCTAssertFalse(config.isStartable)
    }

    func testCompleteConfigurationIsStartable() {
        let config = FarTransport.Configuration(
            liveKitURL: "wss://livekit.example.test",
            tokenServerURL: "https://token.example.test",
            roomName: "room-a"
        )
        XCTAssertTrue(config.isStartable)
    }
}
```

- [ ] **Step 3: Run test and verify it fails**

Run:

```bash
xcodebuild test -project Sonar.xcodeproj -scheme Sonar -destination 'id=DCF24978-ABA7-4DC1-9E95-D96B0CE16CD4' -only-testing:SonarTests/FarTransportConfigurationTests
```

Expected: compile failure because `FarTransport.Configuration` does not exist.

- [ ] **Step 4: Add configuration value type**

Add inside `FarTransport`:

```swift
struct Configuration: Equatable {
    let liveKitURL: String
    let tokenServerURL: String
    let roomName: String

    var isStartable: Bool {
        !liveKitURL.isEmpty && !tokenServerURL.isEmpty && !roomName.isEmpty
    }
}
```

Add:

```swift
func configure(_ configuration: Configuration) {
    guard configuration.isStartable else {
        lkServerURL = ""
        tokenProvider = nil
        roomName = configuration.roomName
        return
    }
    lkServerURL = configuration.liveKitURL
    tokenProvider = SonarTokenProvider(serverURL: configuration.tokenServerURL)
    roomName = configuration.roomName
}
```

- [ ] **Step 5: Load config in coordinator**

Add a private helper in `SessionCoordinator`:

```swift
private func farConfiguration() -> FarTransport.Configuration {
    let env = ProcessInfo.processInfo.environment
    let liveKitURL = env["SONAR_LIVEKIT_URL"] ?? UserDefaults.standard.string(forKey: "sonar.livekit.url") ?? ""
    let tokenServerURL = env["SONAR_TOKEN_SERVER_URL"] ?? UserDefaults.standard.string(forKey: "sonar.tokenServer.url") ?? ""
    let roomName = env["SONAR_LIVEKIT_ROOM"] ?? UserDefaults.standard.string(forKey: "sonar.livekit.room") ?? "sonar-main"
    return FarTransport.Configuration(liveKitURL: liveKitURL, tokenServerURL: tokenServerURL, roomName: roomName)
}
```

Before `bonder.addPath(far)`, configure and start only when startable:

```swift
let farConfig = farConfiguration()
far.configure(farConfig)
if farConfig.isStartable {
    Task { try? await far.start() }
    bonder.addPath(far)
}
```

Do not add `far` to the bonder when not configured.

- [ ] **Step 6: Add coordinator-level test seam if needed**

If direct coordinator testing is too coupled to audio startup, keep this covered by `FarTransport.Configuration` tests and `AppStateConnectionTypeTests`. Do not instantiate full audio hardware just to test env parsing.

- [ ] **Step 7: Run Far/connection tests**

Run:

```bash
xcodebuild test -project Sonar.xcodeproj -scheme Sonar -destination 'id=DCF24978-ABA7-4DC1-9E95-D96B0CE16CD4' -only-testing:SonarTests/FarTransportTests -only-testing:SonarTests/AppStateConnectionTypeTests
```

Expected: all selected tests pass.

- [ ] **Step 8: Commit**

```bash
git add sonar/Core/Transport/FarTransport.swift sonar/Core/Coordinator/SessionCoordinator.swift sonarTests/FarTransportTests.swift sonarTests/AppStateConnectionTypeTests.swift
git commit -m "fix: configure livekit far transport explicitly"
```

---

### Task 5: Resolve MPQUICTransport Duplication

**Files:**
- Modify: `sonar/Core/Transport/MPQUICTransport.swift`
- Modify: `README.md`
- Modify: `docs/connection-guide.md`

- [ ] **Step 1: Confirm references**

Run:

```bash
rg -n "MPQUICTransport|FarTransport|mpquic" sonar sonarTests docs README.md
```

Expected: `SessionCoordinator` uses `FarTransport`; `MPQUICTransport` is not wired into app startup.

- [ ] **Step 2: Choose one internet path**

Use LiveKit `FarTransport` as the production internet path for now. Add a header comment to `MPQUICTransport.swift`:

```swift
/// Experimental raw QUIC path.
/// Not wired into SessionCoordinator. Production internet transport is FarTransport
/// via LiveKit data channel because it provides room membership, NAT traversal,
/// and a server-side token flow.
```

If Xcode target membership allows it, exclude `MPQUICTransport.swift` from the app target. If not, leave it compiling but clearly marked experimental.

- [ ] **Step 3: Fix docs wording**

In `README.md` and `docs/connection-guide.md`, replace claims that the app currently runs "MPQUIC + LiveKit" as one path with:

```text
Internet: LiveKit data channel via FarTransport, enabled only when SONAR_LIVEKIT_URL and SONAR_TOKEN_SERVER_URL are configured.
Raw MPQUIC exists as experimental code and is not part of the default session path.
```

- [ ] **Step 4: Run reference search**

Run:

```bash
rg -n "MPQUIC \\+ LiveKit|FarTransport.*Tailscale|Raw MPQUIC" README.md docs sonar
```

Expected: no stale claim says default sessions use raw MPQUIC unless it is explicitly labelled experimental.

- [ ] **Step 5: Commit**

```bash
git add sonar/Core/Transport/MPQUICTransport.swift README.md docs/connection-guide.md
git commit -m "docs: clarify internet transport implementation"
```

---

### Task 6: Strengthen Transport Truth In AppState

**Files:**
- Modify: `sonar/App/AppState.swift`
- Test: `sonarTests/AppStateConnectionTypeTests.swift`

- [ ] **Step 1: Write priority tests**

Add:

```swift
func testNoActivePathsClearsConnectionButKeepsPairingIntentName() {
    let state = AppState()
    state.peerName = "Alex iPhone"
    state.peerID = "peer-A"
    state.peerOnline = true

    state.applyActiveTransportPaths([])

    XCTAssertFalse(state.peerOnline)
    XCTAssertEqual(state.connectionType, .none)
    XCTAssertEqual(state.peerName, "Alex iPhone")
    XCTAssertEqual(state.peerID, "peer-A")
}

func testActivePathPriorityPrefersLocalOverInternet() {
    let state = AppState()
    state.applyActiveTransportPaths([.mpquic, .tailscale, .multipeer])

    XCTAssertTrue(state.peerOnline)
    XCTAssertEqual(state.connectionType, .awdl)
}
```

- [ ] **Step 2: Run and verify current behavior**

Run:

```bash
xcodebuild test -project Sonar.xcodeproj -scheme Sonar -destination 'id=DCF24978-ABA7-4DC1-9E95-D96B0CE16CD4' -only-testing:SonarTests/AppStateConnectionTypeTests
```

Expected: first new test fails if `applyActiveTransportPaths([])` clears peer identity.

- [ ] **Step 3: Keep pairing identity separate from online truth**

Change the empty-path block in `applyActiveTransportPaths` to:

```swift
guard !paths.isEmpty else {
    peerOnline = false
    peerLastSeen = nil
    connectionType = .none
    return
}
```

Do not clear `peerName` and `peerID` here; session stop can still clear them.

- [ ] **Step 4: Run AppState tests**

Run same command.

Expected: all AppState connection type tests pass.

- [ ] **Step 5: Commit**

```bash
git add sonar/App/AppState.swift sonarTests/AppStateConnectionTypeTests.swift
git commit -m "fix: separate pairing identity from online state"
```

---

### Task 7: End-To-End Verification Gates

**Files:**
- Modify: `scripts/e2e/run-simulator-e2e.sh`
- Modify: `docs/e2e-simulator-relay.md`
- Optional test helper: `scripts/e2e/assert_relay_state.py`

- [ ] **Step 1: Add state assertion script**

Create `scripts/e2e/assert_relay_state.py`:

```python
#!/usr/bin/env python3
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    state = json.load(f)

devices = {d["id"]: d["name"] for d in state.get("devices", [])}
required = {
    "SIM-A-38D0B9": "SIM-A",
    "SIM-B-97D949": "SIM-B",
}
missing = [device_id for device_id in required if device_id not in devices]
if missing:
    raise SystemExit(f"missing devices: {missing}")

frame_count = state.get("frameCount", 0)
if frame_count < 10:
    raise SystemExit(f"expected at least 10 frames, got {frame_count}")

events = state.get("events", [])
senders = {event.get("device") for event in events if event.get("type") == "frame"}
if not {"SIM-A-38D0B9", "SIM-B-97D949"}.issubset(senders):
    raise SystemExit(f"frames must be sent by both devices, got {sorted(senders)}")

print(json.dumps({"devices": sorted(devices.values()), "frameCount": frame_count, "serverSeq": state.get("serverSeq", 0)}))
```

- [ ] **Step 2: Wire assertion into run script**

In `scripts/e2e/run-simulator-e2e.sh`, replace any inline loose state check with:

```bash
python3 scripts/e2e/assert_relay_state.py "$OUT_DIR_ABS/state.json"
```

- [ ] **Step 3: Run simulator relay E2E**

Run:

```bash
scripts/e2e/run-simulator-e2e.sh
```

Expected: command exits 0, prints JSON with `SIM-A`, `SIM-B`, and `frameCount >= 10`, writes both screenshots.

- [ ] **Step 4: Commit**

```bash
git add scripts/e2e/run-simulator-e2e.sh scripts/e2e/assert_relay_state.py docs/e2e-simulator-relay.md
git commit -m "test: enforce simulator relay e2e pass criteria"
```

---

### Task 8: Hardware Verification Checklist For Real Radios

**Files:**
- Create: `docs/hardware-connection-verification.md`
- Modify: `docs/connection-guide.md`
- Modify: `README.md`

- [ ] **Step 1: Add hardware checklist doc**

Create `docs/hardware-connection-verification.md`:

```markdown
# Hardware Connection Verification

Run this on two physical iPhones with the same build installed.

## AWDL / Multipeer

1. Turn Wi-Fi and Bluetooth on for both devices.
2. Launch Sonar on both devices.
3. Start a session on both devices.
4. Pass criteria:
   - Both devices show peer name.
   - Both devices show active path `AWDL · Lokal`.
   - Speaking into A produces remote input activity/playback on B.
   - Speaking into B produces remote input activity/playback on A.

## QR Targeting

1. On device A open Verbinden -> Anzeigen.
2. On device B open Verbinden -> Scannen and scan A.
3. Place a third Sonar device nearby.
4. Pass criteria:
   - B connects to A, not the third device.
   - Third device does not become `peerOnline` on A or B.

## BLE

1. Turn Wi-Fi off on both devices.
2. Keep Bluetooth on.
3. Launch Sonar and start a session.
4. Pass criteria:
   - Both devices show active path `Bluetooth`.
   - A-to-B and B-to-A frames/audio activity are visible.

## Tailscale

1. Put both phones in the same Tailnet.
2. Verify both have `100.64.0.0/10` Tailscale IPs.
3. Scan QR from A on B.
4. Pass criteria:
   - Active path becomes `Tailscale`.
   - A-to-B and B-to-A frames/audio activity are visible.

## Internet / LiveKit

1. Start `sonar-server` with valid LiveKit credentials.
2. Launch both apps with `SONAR_LIVEKIT_URL`, `SONAR_TOKEN_SERVER_URL`, and the same `SONAR_LIVEKIT_ROOM`.
3. Put devices on different networks.
4. Pass criteria:
   - Active path becomes `Internet`.
   - Both devices exchange `sonar.audio` data channel frames.
```

- [ ] **Step 2: Link doc from existing docs**

Add links in `README.md` and `docs/connection-guide.md`:

```markdown
For physical-device proof, run [`docs/hardware-connection-verification.md`](hardware-connection-verification.md).
```

- [ ] **Step 3: Commit**

```bash
git add docs/hardware-connection-verification.md docs/connection-guide.md README.md
git commit -m "docs: add hardware connection verification checklist"
```

---

## Final Verification

- [ ] Run targeted tests:

```bash
xcodebuild test -project Sonar.xcodeproj -scheme Sonar -destination 'id=DCF24978-ABA7-4DC1-9E95-D96B0CE16CD4' \
  -only-testing:SonarTests/PairingServiceTests \
  -only-testing:SonarTests/NearTransportPairingTests \
  -only-testing:SonarTests/BluetoothMeshTransportTests \
  -only-testing:SonarTests/FarTransportTests \
  -only-testing:SonarTests/AppStateConnectionTypeTests \
  -only-testing:SonarTests/TailscaleTransportTests \
  -only-testing:SonarTests/SimulatorRelayTransportTests \
  -only-testing:SonarTests/MultipathBonderTests \
  -only-testing:SonarTests/E2ETransportTests
```

Expected: all selected tests pass.

- [ ] Run simulator E2E:

```bash
scripts/e2e/run-simulator-e2e.sh
```

Expected: exits 0, two devices online, frames from both devices, screenshots written.

- [ ] Run full suite if time allows:

```bash
xcodebuild test -project Sonar.xcodeproj -scheme Sonar -destination 'id=DCF24978-ABA7-4DC1-9E95-D96B0CE16CD4'
```

Expected: test suite passes. If UI tests require simulator permissions, record any environment-specific failures separately from connection logic.
