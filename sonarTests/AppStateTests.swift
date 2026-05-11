import Combine
import Network
import simd
@testable import Sonar
import XCTest

@MainActor
final class PermissionsManagerTests: XCTestCase {
    func testLocalNetworkBrowserWaitingWithPolicyDeniedIsDenied() {
        XCTAssertEqual(
            PermissionsManager.localNetworkPermissionState(
                for: .waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))
            ),
            .denied
        )
    }

    func testLocalNetworkBrowserWaitingWithGenericErrorKeepsPermissionUnknown() {
        XCTAssertEqual(
            PermissionsManager.localNetworkPermissionState(for: .waiting(.posix(.ENETDOWN))),
            .unknown
        )
    }

    func testLocalNetworkBrowserFailedWithGenericErrorKeepsPermissionUnknown() {
        XCTAssertEqual(
            PermissionsManager.localNetworkPermissionState(for: .failed(.posix(.ECONNREFUSED))),
            .unknown
        )
    }
}

@MainActor
final class AppStateTests: XCTestCase {
    private let localDisplayNameKey = "sonar.identity.localDisplayName"
    private let profileIDKey = AppState.profileIDKey

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: localDisplayNameKey)
        UserDefaults.standard.removeObject(forKey: profileIDKey)
        super.tearDown()
    }

    func testDefaultsToIdle() {
        let s = AppState()
        XCTAssertEqual(s.phase, .idle)
    }

    func testMicrophoneDefaultsToUnmutedWithNoInputLevel() {
        let s = AppState()
        XCTAssertFalse(s.isMuted)
        XCTAssertEqual(s.inputLevelRMS, 0, accuracy: 0.0001)
    }

    func testMicrophoneStateCanBeUpdated() {
        let s = AppState()
        s.isMuted = true
        s.inputLevelRMS = 0.42

        XCTAssertTrue(s.isMuted)
        XCTAssertEqual(s.inputLevelRMS, 0.42, accuracy: 0.0001)
    }

    func testPhaseEquality() {
        XCTAssertEqual(AppState.Phase.idle, .idle)
        XCTAssertEqual(AppState.Phase.connecting, .connecting)
        XCTAssertEqual(AppState.Phase.near(distance: 1.5), .near(distance: 1.5))
        XCTAssertNotEqual(AppState.Phase.near(distance: 1.5), .near(distance: 1.6))
        XCTAssertNotEqual(AppState.Phase.near(distance: 1.5), .far)
    }

    func testEditableDisplayNameFeedsPeerNameAndPairingToken() {
        UserDefaults.standard.removeObject(forKey: localDisplayNameKey)
        UserDefaults.standard.removeObject(forKey: "sonar.pairing.tailscaleIP")
        let identity = SonarTestIdentity(
            environment: [
                "SONAR_TEST_DEVICE_ID": "SIM-A-38D0B9",
                "SONAR_TEST_DEVICE_NAME": "SIM-A"
            ],
            arguments: [],
            vendorIdentifier: nil,
            fallbackDeviceName: "Fallback"
        )
        let state = AppState(testIdentity: identity)

        XCTAssertEqual(state.effectiveDisplayName, "SIM-A")
        XCTAssertEqual(state.localPeerName, "SIM-A")

        state.localDisplayName = "  Martin's iPhone  "

        XCTAssertEqual(state.effectiveDisplayName, "Martin's iPhone")
        XCTAssertEqual(state.localPeerName, "Martin's iPhone")
        let token = PairingTokenGenerator.makeToken(
            appState: state,
            now: Date(timeIntervalSince1970: 1_750_000_123)
        )
        XCTAssertEqual(token.name, "Martin's iPhone")

        state.localDisplayName = "   "

        XCTAssertEqual(state.effectiveDisplayName, "SIM-A")
        XCTAssertEqual(state.localPeerName, "SIM-A")
    }

    func testProfileIDPersistsAcrossAppStateInstances() {
        UserDefaults.standard.removeObject(forKey: profileIDKey)

        let first = AppState()
        XCTAssertEqual(first.profileID, "zimmer")

        first.profileID = "festival"

        let second = AppState()
        XCTAssertEqual(second.profileID, "festival")
    }

    func testPrivacyModeTracksSharedPrivacyStateChanges() {
        let mode = PrivacyMode.shared
        if mode.isActive { mode.deactivate() }
        let state = AppState()

        XCTAssertFalse(state.privacyModeActive)

        mode.activate()

        XCTAssertTrue(state.privacyModeActive)

        mode.deactivate()

        XCTAssertFalse(state.privacyModeActive)
    }

    func testPeerDirectionDefaultsToNilAndCanBeUpdated() {
        let state = AppState()

        XCTAssertNil(state.peerDirection)

        let direction = simd_float3(0.25, 0, -0.75)
        state.peerDirection = direction

        XCTAssertEqual(state.peerDirection, direction)

        state.peerDirection = nil

        XCTAssertNil(state.peerDirection)
    }
}

@MainActor
final class SessionCoordinatorTests: XCTestCase {
    private final class SpyFarTransport: FarTransporting, @unchecked Sendable {
        let id: MultipathBonder.PathID = .mpquic
        let estimatedCostPerByte = 1.0
        private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
        private let inboundSubject = PassthroughSubject<AudioFrame, Never>()
        private(set) var stopCallCount = 0

        var isConnected: AnyPublisher<Bool, Never> {
            connectedSubject.eraseToAnyPublisher()
        }

        var inboundFrames: AnyPublisher<AudioFrame, Never> {
            inboundSubject.eraseToAnyPublisher()
        }

        func configure(_ configuration: FarTransport.Configuration) {}

        func start() async throws {}

        func stop() async {
            stopCallCount += 1
        }

        func send(_ frame: AudioFrame) async {}
    }

    func testStartsIdle() {
        let c = SessionCoordinator()
        XCTAssertEqual(c.phase, .idle)
    }

    func testStartLiftsToConnecting() {
        let c = SessionCoordinator()
        c.start()
        XCTAssertEqual(c.phase, .connecting)
        c.stop() // cancel background task to avoid leaking transcription into later tests
    }

    func testStopReturnsToIdle() {
        let c = SessionCoordinator()
        c.start()
        c.stop()
        XCTAssertEqual(c.phase, .idle)
    }

    func testNilDistanceWithoutActivePathMovesCoordinatorAndAppStateFromNearToConnecting() {
        let appState = AppState()
        let c = SessionCoordinator()
        c.appState = appState

        c.handleDistanceUpdate(1.2)

        XCTAssertEqual(c.phase, .near(distance: 1.2))
        XCTAssertEqual(appState.phase, .near(distance: 1.2))

        c.handleDistanceUpdate(nil)

        XCTAssertEqual(c.phase, .connecting)
        XCTAssertEqual(appState.phase, .connecting)
    }

    func testPeerDirectionUpdateMirrorsIntoAppStateAndClears() {
        let appState = AppState()
        let c = SessionCoordinator()
        c.appState = appState
        let direction = simd_float3(-0.4, 0.1, -0.8)

        c.handlePeerDirectionUpdate(direction)

        XCTAssertEqual(appState.peerDirection, direction)

        c.handlePeerDirectionUpdate(nil)

        XCTAssertNil(appState.peerDirection)
    }

    func testPrivacyActiveBlocksFarTransportStartup() {
        let config = FarTransport.Configuration(
            liveKitURL: "wss://livekit.example.test",
            tokenServerURL: "https://token.example.test",
            roomName: "sonar-main"
        )

        XCTAssertFalse(SessionCoordinator.shouldStartFarTransport(privacyActive: true, configuration: config))
    }

    func testPrivacyActivationStopsFarTransport() async {
        let far = SpyFarTransport()
        let c = SessionCoordinator(far: far)

        await c.handlePrivacyModeActivated()

        XCTAssertEqual(far.stopCallCount, 1)
    }
}
