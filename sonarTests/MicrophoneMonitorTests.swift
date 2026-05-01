import AVFoundation
import XCTest

@testable import Sonar

final class MicrophoneMonitorTests: XCTestCase {
    func testRMSIsZeroForSilentBuffer() {
        let buffer = makeBuffer(samples: Array(repeating: 0, count: 160))

        XCTAssertEqual(MicrophoneMonitor.rms(buffer), 0, accuracy: 0.0001)
    }

    func testRMSReflectsSignalEnergy() {
        let buffer = makeBuffer(samples: Array(repeating: 0.5, count: 160))

        XCTAssertEqual(MicrophoneMonitor.rms(buffer), 0.5, accuracy: 0.0001)
    }

    func testMutedMicrophoneDoesNotForwardCapturedAudio() {
        XCTAssertFalse(MicrophoneMonitor.shouldForwardCapturedAudio(isMuted: true))
        XCTAssertTrue(MicrophoneMonitor.shouldForwardCapturedAudio(isMuted: false))
    }

    func testLevelMeterMapsRMSIntoFiveStableBars() {
        XCTAssertEqual(AudioLevelMeter.activeBarCount(for: 0), 0)
        XCTAssertEqual(AudioLevelMeter.activeBarCount(for: 0.02), 1)
        XCTAssertEqual(AudioLevelMeter.activeBarCount(for: 0.20), 3)
        XCTAssertEqual(AudioLevelMeter.activeBarCount(for: 0.90), 5)
    }

    private func makeBuffer(samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }
        return buffer
    }
}
