import AVFoundation
import XCTest
@testable import Sonar

// MARK: - RoomTokenProvider

final class SonarTokenProviderTests: XCTestCase {
    func testBadURLThrows() async {
        let p = SonarTokenProvider(serverURL: "not-a-url\u{00}")   // NUL → malformed
        do {
            _ = try await p.fetchToken(roomName: "r", participantIdentity: "i")
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    func testNetworkErrorPropagates() async {
        // Point at a port guaranteed to refuse (loopback, port 1).
        let p = SonarTokenProvider(serverURL: "http://127.0.0.1:1")
        do {
            _ = try await p.fetchToken(roomName: "r", participantIdentity: "i")
            XCTFail("expected throw")
        } catch {
            XCTAssertNotNil(error)
        }
    }
}

// MARK: - AgentConnector

@MainActor
final class AgentConnectorTests: XCTestCase {
    func testEmptyServerURLIsNoOp() async {
        let connector = AgentConnector()
        connector.serverURL = ""
        // Must not throw even with no server configured.
        try? await connector.ensureAgentInRoom(roomName: "test")
    }

    func testUtteranceWithEmptyServerURLIsNoOp() async {
        let connector = AgentConnector()
        await connector.sendUserUtterance("Hallo")   // must not crash
    }
}

// MARK: - VAD

final class VADTests: XCTestCase {
    private func makeBuffer(rms: Float, frameLength: Int = 480) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameLength))!
        buf.frameLength = AVAudioFrameCount(frameLength)
        // Fill with sine amplitude so RMS == rms.
        let amp = rms * Float(2).squareRoot()  // sine peak = rms * sqrt(2)
        let ptr = buf.floatChannelData![0]
        for i in 0..<frameLength {
            ptr[i] = amp * sin(2 * .pi * Float(i) / Float(frameLength))
        }
        return buf
    }

    func testSilenceDoesNotTrigger() {
        let vad = VAD()
        let buf = makeBuffer(rms: 0.001)
        XCTAssertFalse(vad.feed(buf))
        XCTAssertFalse(vad.isSpeaking)
    }

    func testLoudSignalTriggers() {
        let vad = VAD()
        let buf = makeBuffer(rms: 0.05)
        XCTAssertTrue(vad.feed(buf))
        XCTAssertTrue(vad.isSpeaking)
    }

    func testHysteresisStaysOnUntilFarBelowThreshold() {
        let vad = VAD()
        // Bring up.
        _ = vad.feed(makeBuffer(rms: 0.05))
        XCTAssertTrue(vad.isSpeaking)
        // Moderate — above off-threshold but below on-threshold: stays on.
        _ = vad.feed(makeBuffer(rms: 0.012))
        XCTAssertTrue(vad.isSpeaking)
        // Below off-threshold: turns off.
        _ = vad.feed(makeBuffer(rms: 0.005))
        XCTAssertFalse(vad.isSpeaking)
    }

    func testResetClearsSpeakingState() {
        let vad = VAD()
        _ = vad.feed(makeBuffer(rms: 0.05))
        XCTAssertTrue(vad.isSpeaking)
        vad.reset()
        XCTAssertFalse(vad.isSpeaking)
    }
}
