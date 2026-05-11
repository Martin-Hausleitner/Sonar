import AVFoundation
import Combine
@testable import Sonar
import XCTest

@MainActor
final class SessionCoordinatorPrivacyTests: XCTestCase {
    private final class SpyFarTransport: @preconcurrency FarTransporting, @unchecked Sendable {
        let id: MultipathBonder.PathID = .mpquic
        let estimatedCostPerByte = 1.0
        private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
        private let inboundSubject = PassthroughSubject<AudioFrame, Never>()
        private var startContinuation: CheckedContinuation<Void, Error>?
        var suspendStart = false
        private(set) var startCallCount = 0
        private(set) var stopCallCount = 0

        var isConnected: AnyPublisher<Bool, Never> {
            connectedSubject.eraseToAnyPublisher()
        }

        var inboundFrames: AnyPublisher<AudioFrame, Never> {
            inboundSubject.eraseToAnyPublisher()
        }

        func configure(_ configuration: FarTransport.Configuration) {}

        func start() async throws {
            startCallCount += 1
            if suspendStart {
                try await withCheckedThrowingContinuation { continuation in
                    startContinuation = continuation
                }
            }
            connectedSubject.send(true)
        }

        func stop() async {
            stopCallCount += 1
            connectedSubject.send(false)
        }

        func completeStart() {
            startContinuation?.resume()
            startContinuation = nil
        }

        func send(_ frame: AudioFrame) async {}
    }

    override func setUp() {
        super.setUp()
        if PrivacyMode.shared.isActive { PrivacyMode.shared.deactivate() }
        UserDefaults.standard.removeObject(forKey: "sonar.parakeet.apiKey")
    }

    override func tearDown() {
        if PrivacyMode.shared.isActive { PrivacyMode.shared.deactivate() }
        UserDefaults.standard.removeObject(forKey: "sonar.parakeet.apiKey")
        super.tearDown()
    }

    func testPrivacyActiveBlocksFarTransportStartup() {
        let config = FarTransport.Configuration(
            liveKitURL: "wss://livekit.example.test",
            tokenServerURL: "https://token.example.test",
            roomName: "sonar-main"
        )

        XCTAssertFalse(SessionCoordinator.shouldStartFarTransport(privacyActive: true, configuration: config))
    }

    func testPrivacyActiveBlocksTailscaleTransportStartup() {
        XCTAssertFalse(SessionCoordinator.shouldStartTailscaleTransport(privacyActive: true))
        XCTAssertTrue(SessionCoordinator.shouldStartTailscaleTransport(privacyActive: false))
    }

    func testPrivacyActivationStopsFarTransport() async {
        let far = SpyFarTransport()
        let coordinator = SessionCoordinator(far: far)

        await coordinator.handlePrivacyModeActivated()

        XCTAssertEqual(far.stopCallCount, 1)
    }

    func testPrivacyActivationAbortsCloudTranscriptionWithoutFinishing() async throws {
        UserDefaults.standard.set("nvapi-fake", forKey: "sonar.parakeet.apiKey")
        let cloud = SpyCloudTranscriber()
        let transcription = LiveTranscriptionEngine(
            parakeetFactory: { _, onSegment in
                cloud.onSegment = onSegment
                return cloud
            }
        )
        try await transcription.start()
        XCTAssertEqual(transcription.currentEngine, .parakeet)

        let coordinator = SessionCoordinator(far: SpyFarTransport(), transcription: transcription)

        await coordinator.handlePrivacyModeActivated()

        XCTAssertEqual(cloud.abortCount, 1)
        XCTAssertEqual(cloud.finishCount, 0)
    }

    func testPrivacyActivationCancelsInFlightFarTransportStartup() async {
        let far = SpyFarTransport()
        far.suspendStart = true
        let coordinator = SessionCoordinator(far: far)
        let config = FarTransport.Configuration(
            liveKitURL: "wss://livekit.example.test",
            tokenServerURL: "https://token.example.test",
            roomName: "sonar-main"
        )

        coordinator.startFarTransportIfAllowed(configuration: config)
        await Task.yield()

        XCTAssertEqual(far.startCallCount, 1)

        PrivacyMode.shared.activate()
        await coordinator.handlePrivacyModeActivated()
        far.completeStart()
        for _ in 0 ..< 50 where far.stopCallCount < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertGreaterThanOrEqual(far.stopCallCount, 2)
    }

    func testCancelledFarStartupIsNotKeptAfterStartReturns() {
        let config = FarTransport.Configuration(
            liveKitURL: "wss://livekit.example.test",
            tokenServerURL: "https://token.example.test",
            roomName: "sonar-main"
        )

        XCTAssertFalse(
            SessionCoordinator.shouldKeepStartedFarTransport(
                privacyActive: false,
                startupTaskCancelled: true,
                configuration: config
            )
        )
    }
}

private final class SpyCloudTranscriber: CloudTranscribing {
    private(set) var appendCount = 0
    private(set) var finishCount = 0
    private(set) var abortCount = 0
    var onSegment: ((String) -> Void)?

    func append(_ buffer: AVAudioPCMBuffer) {
        appendCount += 1
    }

    func finish() {
        finishCount += 1
    }

    func abort() {
        abortCount += 1
    }
}
