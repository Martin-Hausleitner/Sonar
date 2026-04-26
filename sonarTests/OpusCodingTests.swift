import AVFoundation
import XCTest
@testable import Sonar

final class OpusCodingTests: XCTestCase {
    func testCoderInitialises() {
        _ = OpusCoder()
    }

    func testDefaultsMatchLatencyBudget() {
        let c = OpusCoder()
        XCTAssertEqual(c.frameMs, LatencyBudget.audioFrameMs)
        XCTAssertEqual(c.sampleRate, LatencyBudget.audioSampleRate)
    }

    /// Verifies that real Opus compression works end-to-end.
    ///
    /// We do NOT compare sample-by-sample values: Opus is a perceptual lossy codec,
    /// so the decoded waveform will differ from the input even at 24 kbps.
    /// What we verify instead:
    ///   1. encode() produces a packet smaller than raw Float32 PCM
    ///   2. decode() produces non-empty, non-silent audio
    ///   3. The codec can be skipped gracefully if not available on this runtime
    @available(iOS 18, *)
    func testEncodeDecodesRoundtrip() throws {
        let coder = OpusCoder()
        let sampleRate = Double(coder.sampleRate)
        let frameCount = coder.samplesPerFrame

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let src = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        src.frameLength = AVAudioFrameCount(frameCount)

        // 1 kHz sine at half amplitude — well above codec noise floor.
        let ptr = src.floatChannelData![0]
        for i in 0..<frameCount {
            ptr[i] = 0.5 * sin(2 * .pi * 1_000 * Float(i) / Float(sampleRate))
        }

        // Encode — skip if Opus codec is unavailable on this simulator.
        let encoded: Data
        do {
            encoded = try coder.encode(src)
        } catch {
            throw XCTSkip("Opus encode unavailable: \(error)")
        }
        // Real compression: 24 kbps / 10 ms ≈ 30 bytes vs. 480 × 4 = 1920 bytes raw.
        XCTAssertGreaterThan(encoded.count, 0)
        XCTAssertLessThan(encoded.count, frameCount * 4, "packet must be smaller than raw Float32")

        // Decode — the iOS Opus codec may choose a different internal frame size
        // (e.g. 7.5 ms = 360 samples instead of the 10 ms = 480 we requested).
        // Allocate 2× headroom so the buffer is never too small.
        let dst = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount * 2)
        )!
        do {
            try coder.decode(encoded, into: dst)
        } catch {
            throw XCTSkip("Opus decode unavailable: \(error)")
        }
        XCTAssertGreaterThan(Int(dst.frameLength), 0, "decoder must produce at least one frame")

        // Decoded audio must not be silence (Opus priming delay is < 80 samples,
        // so most of the decoded frame should contain the input sine wave).
        let decoded = dst.floatChannelData![0]
        var maxAbs: Float = 0
        for i in 0..<Int(dst.frameLength) { maxAbs = max(maxAbs, abs(decoded[i])) }
        XCTAssertGreaterThan(maxAbs, 0.01, "decoded audio must not be silence")
    }
}
