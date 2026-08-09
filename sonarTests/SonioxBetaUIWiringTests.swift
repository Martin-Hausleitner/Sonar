import AVFoundation
import Combine
@testable import Sonar
import XCTest

/// Soniox Beta M8 — the UI wiring: `SessionCoordinator` mirrors the engine's
/// transcript and quality metrics into `AppState`, the in-call preview shows
/// the live (partial) tail, and the Live-Daten sheet formats the metrics.
/// No network: the Soniox transcriber is replaced by an inert spy.
@MainActor
final class SonioxBetaUIWiringTests: XCTestCase {
    override func setUp() async throws {
        if PrivacyMode.shared.isActive { PrivacyMode.shared.deactivate() }
    }

    override func tearDown() async throws {
        if PrivacyMode.shared.isActive { PrivacyMode.shared.deactivate() }
    }

    // MARK: - Coordinator → AppState mirroring

    func testCoordinatorMirrorsSonioxMetricsIntoAppState() async throws {
        let spy = SpySonioxTranscriber()
        let engine = makeSonioxEngine(spy: spy)
        try await engine.start()
        XCTAssertEqual(engine.currentEngine, .soniox)

        let appState = AppState()
        let coordinator = SessionCoordinator(far: StubFarTransport(), transcription: engine)
        coordinator.appState = appState
        coordinator.bindTranscriptionToAppState()

        var metrics = SonioxQualityMetrics()
        metrics.recordSessionStarted()
        metrics.recordStreamedAudio(seconds: 12)
        metrics.recordSuppressedSilence(seconds: 30)
        metrics.recordFirstTokenLatency(0.4)
        spy.onMetricsChange?(metrics)

        try await waitUntil { appState.sonioxMetrics.sessionsStarted == 1 }
        XCTAssertEqual(appState.sonioxMetrics.streamedAudioSeconds, 12, accuracy: 0.001)
        XCTAssertEqual(appState.sonioxMetrics.suppressedSilenceSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(appState.sonioxMetrics.firstTokenLatencyEMA ?? -1, 0.4, accuracy: 0.001)
    }

    func testCoordinatorMirrorsLiveTranscriptIntoAppState() async throws {
        let spy = SpySonioxTranscriber()
        let engine = makeSonioxEngine(spy: spy)
        try await engine.start()

        let appState = AppState()
        let coordinator = SessionCoordinator(far: StubFarTransport(), transcription: engine)
        coordinator.appState = appState
        coordinator.bindTranscriptionToAppState()

        spy.onSegment?("hallo", "spk:1", false)
        try await waitUntil { appState.transcriptSegments.count == 1 }
        XCTAssertEqual(appState.transcriptSegments.first?.text, "hallo")
        XCTAssertEqual(appState.transcriptSegments.first?.speakerID, "spk:1")
        XCTAssertEqual(appState.transcriptSegments.first?.isFinal, false)

        spy.onSegment?("hallo welt", "spk:1", true)
        try await waitUntil { appState.transcriptSegments.first?.isFinal == true }
        XCTAssertEqual(appState.transcriptSegments.count, 1)
        XCTAssertEqual(appState.transcriptSegments.first?.text, "hallo welt")
    }

    // MARK: - In-call transcript preview (SessionView)

    func testTranscriptPreviewShowsLastFinalsAndPartialTail() {
        let segments: [LiveTranscriptionEngine.Segment] = [
            segment("eins", isFinal: true),
            segment("zwei", isFinal: true),
            segment("drei", isFinal: true),
            segment("vier unterweg", isFinal: false),
        ]

        let preview = SessionView.transcriptPreview(from: segments)

        XCTAssertEqual(preview.finals.map(\.text), ["zwei", "drei"])
        XCTAssertEqual(preview.partial?.text, "vier unterweg")
    }

    func testTranscriptPreviewHasNoPartialWhenTailIsFinalOrBlank() {
        let allFinal = SessionView.transcriptPreview(from: [segment("fertig", isFinal: true)])
        XCTAssertNil(allFinal.partial)
        XCTAssertEqual(allFinal.finals.map(\.text), ["fertig"])

        let blankTail = SessionView.transcriptPreview(from: [
            segment("fertig", isFinal: true),
            segment("   ", isFinal: false),
        ])
        XCTAssertNil(blankTail.partial)

        let empty = SessionView.transcriptPreview(from: [])
        XCTAssertTrue(empty.finals.isEmpty)
        XCTAssertNil(empty.partial)
    }

    // MARK: - Live-Daten sheet formatting

    func testLatencyLabelFormatsEMAOrPlaceholder() {
        XCTAssertEqual(LiveDataSheet.latencyLabel(nil), "—")
        XCTAssertEqual(LiveDataSheet.latencyLabel(0.234), "234 ms")
        XCTAssertEqual(LiveDataSheet.latencyLabel(1.5), "1500 ms")
    }

    func testPercentLabelClampsAndRounds() {
        XCTAssertEqual(LiveDataSheet.percentLabel(0.62), "62 %")
        XCTAssertEqual(LiveDataSheet.percentLabel(0), "0 %")
        XCTAssertEqual(LiveDataSheet.percentLabel(1.7), "100 %")
        XCTAssertEqual(LiveDataSheet.percentLabel(-0.2), "0 %")
        XCTAssertEqual(LiveDataSheet.percentLabel(.nan), "0 %")
    }

    func testSecondsLabelSwitchesToMinutes() {
        XCTAssertEqual(LiveDataSheet.secondsLabel(42), "42 s")
        XCTAssertEqual(LiveDataSheet.secondsLabel(0), "0 s")
        XCTAssertEqual(LiveDataSheet.secondsLabel(90), "1.5 min")
        XCTAssertEqual(LiveDataSheet.secondsLabel(-3), "0 s")
    }

    // MARK: - Helpers

    private func makeSonioxEngine(spy: SpySonioxTranscriber) -> LiveTranscriptionEngine {
        let defaults = UserDefaults(suiteName: "soniox.ui.wiring.tests")!
        defaults.removePersistentDomain(forName: "soniox.ui.wiring.tests")
        let configuration = SonioxConfiguration.resolved(
            environment: ["SONAR_SONIOX_API_KEY": "unit-test-placeholder"],
            defaults: defaults
        )
        return LiveTranscriptionEngine(
            sonioxFactory: { _, onSegment in
                spy.onSegment = onSegment
                return spy
            },
            sonioxConfigurationProvider: { configuration }
        )
    }

    private func segment(_ text: String, isFinal: Bool) -> LiveTranscriptionEngine.Segment {
        LiveTranscriptionEngine.Segment(text: text, speakerID: nil, timestamp: Date(), isFinal: isFinal)
    }

    /// Polls the main actor until `condition` holds (the coordinator sinks hop
    /// through `DispatchQueue.main`, so one turn of the run loop is needed).
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                return XCTFail("condition not met within \(timeout)s")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - Test doubles

/// Inert Soniox transcriber: records calls, never touches the network.
private final class SpySonioxTranscriber: SonioxRealtimeTranscribing {
    /// The engine's diarized segment callback, captured by the factory.
    var onSegment: ((String, String?, Bool) -> Void)?
    var onMetricsChange: ((SonioxQualityMetrics) -> Void)?
    var qualityMetrics = SonioxQualityMetrics()

    private(set) var connectCount = 0
    private(set) var appendCount = 0
    private(set) var finishCount = 0
    private(set) var abortCount = 0

    func connect() { connectCount += 1 }
    func append(_ buffer: AVAudioPCMBuffer) { appendCount += 1 }
    func finish() { finishCount += 1 }
    func abort() { abortCount += 1 }
}

/// Far transport that does nothing — the coordinator only needs a value.
private final class StubFarTransport: @preconcurrency FarTransporting, @unchecked Sendable {
    let id: MultipathBonder.PathID = .mpquic
    let estimatedCostPerByte = 1.0
    private let connectedSubject = CurrentValueSubject<Bool, Never>(false)
    private let inboundSubject = PassthroughSubject<AudioFrame, Never>()

    var isConnected: AnyPublisher<Bool, Never> { connectedSubject.eraseToAnyPublisher() }
    var inboundFrames: AnyPublisher<AudioFrame, Never> { inboundSubject.eraseToAnyPublisher() }

    func configure(_ configuration: FarTransport.Configuration) {}
    func start() async throws { connectedSubject.send(true) }
    func stop() async { connectedSubject.send(false) }
    func send(_ frame: AudioFrame) async {}
}
