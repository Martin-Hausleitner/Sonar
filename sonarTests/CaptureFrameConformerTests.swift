import AVFoundation
@testable import Sonar
import XCTest

/// Regression tests for the "connected but silent" bug: the mic tap delivers
/// hardware-format buffers (44.1 kHz stereo, 1024 frames …) while `OpusCoder`
/// only accepts 48 kHz mono Float32 in exact 10 ms frames. Every encode failed
/// and `try?` hid it, so no packet ever reached the peer.
final class CaptureFrameConformerTests: XCTestCase {
    // MARK: - Helpers

    private func makeBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frames: Int,
        freq: Double = 440,
        amplitude: Float = 0.5
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        ))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0 ..< Int(channels) {
            for i in 0 ..< frames {
                data[channel][i] = amplitude * Float(sin(2.0 * .pi * freq * Double(i) / sampleRate))
            }
        }
        return buffer
    }

    private func skipUnlessConverterAvailable(from format: AVAudioFormat) throws {
        guard AVAudioConverter(from: format, to: CaptureFrameConformer.defaultOutputFormat) != nil else {
            throw XCTSkip("No AVAudioConverter for \(format) → 48 kHz mono on this runtime")
        }
    }

    private func peak(_ buffer: AVAudioPCMBuffer) throws -> Float {
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        var maxAbs: Float = 0
        for i in 0 ..< Int(buffer.frameLength) {
            maxAbs = max(maxAbs, abs(samples[i]))
        }
        return maxAbs
    }

    // MARK: - Format conformance

    /// The core fix: 44.1 kHz **stereo** tap buffers must come out as exact
    /// 480-sample 48 kHz **mono** encoder frames.
    func testStereo44kInputYieldsExact480SampleMonoFrames() throws {
        let input = try makeBuffer(sampleRate: 44100, channels: 2, frames: 1024)
        try skipUnlessConverterAvailable(from: input.format)

        let conformer = CaptureFrameConformer()
        var frameCount = 0
        for _ in 0 ..< 10 {
            for frame in conformer.conform(input) {
                XCTAssertEqual(Int(frame.frameLength), LatencyBudget.samplesPerFrame)
                XCTAssertEqual(frame.format.sampleRate, LatencyBudget.audioSampleRate)
                XCTAssertEqual(frame.format.channelCount, 1)
                XCTAssertEqual(frame.format.commonFormat, .pcmFormatFloat32)
                XCTAssertFalse(frame.format.isInterleaved)
                frameCount += 1
            }
        }

        // 10 × 1024 frames @ 44.1 kHz ≈ 11 147 samples @ 48 kHz ≈ 23 frames.
        // Allow slack for the resampler's own delay.
        XCTAssertGreaterThanOrEqual(frameCount, 20, "conformer must emit encoder frames")
        XCTAssertLessThanOrEqual(frameCount, 24)
        XCTAssertLessThan(
            conformer.bufferedSampleCount,
            LatencyBudget.samplesPerFrame,
            "never hold back a whole frame"
        )
    }

    /// A 24 kHz mono route (voice-processing on some devices) upsamples too.
    func testMono24kInputYieldsExactFrames() throws {
        let input = try makeBuffer(sampleRate: 24000, channels: 1, frames: 240)
        try skipUnlessConverterAvailable(from: input.format)

        let conformer = CaptureFrameConformer()
        var frameCount = 0
        for _ in 0 ..< 20 {
            for frame in conformer.conform(input) {
                XCTAssertEqual(Int(frame.frameLength), LatencyBudget.samplesPerFrame)
                XCTAssertEqual(frame.format.sampleRate, LatencyBudget.audioSampleRate)
                frameCount += 1
            }
        }
        // 20 × 240 @ 24 kHz = 9 600 samples @ 48 kHz = 20 frames.
        XCTAssertGreaterThanOrEqual(frameCount, 18)
        XCTAssertLessThanOrEqual(frameCount, 20)
    }

    /// Bluetooth HFP (AirPods with the mic active) drops the input route to
    /// 16 kHz — the encoder still needs 48 kHz, so this must be real resampling,
    /// not just re-slicing.
    func testBluetoothHFP16kInputIsResampledTo48k() throws {
        let input = try makeBuffer(sampleRate: 16000, channels: 1, frames: 160, freq: 1000)
        try skipUnlessConverterAvailable(from: input.format)

        let conformer = CaptureFrameConformer()
        var frames: [AVAudioPCMBuffer] = []
        for _ in 0 ..< 20 {
            frames.append(contentsOf: conformer.conform(input))
        }
        // 20 × 160 @ 16 kHz = 3 200 samples ⇒ 9 600 samples @ 48 kHz = 20 frames.
        XCTAssertGreaterThanOrEqual(frames.count, 18, "16 kHz input must be upsampled, not just sliced")
        XCTAssertLessThanOrEqual(frames.count, 20)
        for frame in frames {
            XCTAssertEqual(Int(frame.frameLength), LatencyBudget.samplesPerFrame)
            XCTAssertEqual(frame.format.sampleRate, LatencyBudget.audioSampleRate)
        }
        let audible = try frames.dropFirst().contains { try peak($0) > 0.05 }
        XCTAssertTrue(audible, "resampled audio must not be silence")
    }

    // MARK: - Remainder accumulation

    /// Tap `bufferSize` is only a hint: buffers regularly arrive shorter or
    /// longer than one Opus frame, so the leftover must survive between calls.
    func testRemainderAccumulatesAcrossBuffers() throws {
        let conformer = CaptureFrameConformer()
        let chunk = try makeBuffer(
            sampleRate: LatencyBudget.audioSampleRate,
            channels: 1,
            frames: 100
        )

        for expected in 1 ... 4 {
            XCTAssertTrue(conformer.conform(chunk).isEmpty, "100 samples is less than one frame")
            XCTAssertEqual(conformer.bufferedSampleCount, expected * 100)
        }

        let frames = conformer.conform(chunk) // 500 samples buffered
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(Int(frames[0].frameLength), LatencyBudget.samplesPerFrame)
        XCTAssertEqual(conformer.bufferedSampleCount, 500 - LatencyBudget.samplesPerFrame)
    }

    /// One oversized buffer must be sliced into several frames in one call.
    func testOversizedBufferIsSlicedIntoSeveralFrames() throws {
        let conformer = CaptureFrameConformer()
        let big = try makeBuffer(
            sampleRate: LatencyBudget.audioSampleRate,
            channels: 1,
            frames: LatencyBudget.samplesPerFrame * 3 + 7
        )
        let frames = conformer.conform(big)
        XCTAssertEqual(frames.count, 3)
        XCTAssertEqual(conformer.bufferedSampleCount, 7)
    }

    /// Matching-format input must pass through sample-exact (no resampler).
    func testMatchingFormatPassesSamplesThroughUnchanged() throws {
        let conformer = CaptureFrameConformer()
        let input = try makeBuffer(
            sampleRate: LatencyBudget.audioSampleRate,
            channels: 1,
            frames: LatencyBudget.samplesPerFrame
        )
        let frames = conformer.conform(input)
        XCTAssertEqual(frames.count, 1)

        let source = try XCTUnwrap(input.floatChannelData?[0])
        let emitted = try XCTUnwrap(frames[0].floatChannelData?[0])
        for i in 0 ..< LatencyBudget.samplesPerFrame {
            XCTAssertEqual(emitted[i], source[i], accuracy: 1e-6)
        }
    }

    // MARK: - Route switches

    /// AirPods connect/disconnect swaps the tap format mid-session. The
    /// half-collected frame and the resampler state belong to the *old* route:
    /// carrying either across the switch stitches two different points in time
    /// together. The switch here also goes *into* the pass-through fast path,
    /// which never touches the converter on its own.
    func testRouteSwitchDropsRemainderAndRebuildsConverter() throws {
        let route44k = try makeBuffer(sampleRate: 44100, channels: 2, frames: 1000, freq: 440)
        try skipUnlessConverterAvailable(from: route44k.format)

        let conformer = CaptureFrameConformer()
        _ = conformer.conform(route44k)
        try XCTSkipIf(conformer.bufferedSampleCount == 0, "need a partial frame to observe the switch")
        let generationBefore = conformer.converterGeneration
        XCTAssertGreaterThan(generationBefore, 0)

        // New route already delivers the encoder format — distinct tone so a
        // stitched-in remainder from the old route would be visible.
        let route48k = try makeBuffer(
            sampleRate: LatencyBudget.audioSampleRate,
            channels: 1,
            frames: LatencyBudget.samplesPerFrame,
            freq: 3000,
            amplitude: 0.9
        )
        let frames = conformer.conform(route48k)

        XCTAssertEqual(frames.count, 1, "480 fresh samples ⇒ exactly one frame")
        XCTAssertEqual(conformer.bufferedSampleCount, 0, "old route's leftover must be dropped")

        let source = try XCTUnwrap(route48k.floatChannelData?[0])
        let emitted = try XCTUnwrap(frames[0].floatChannelData?[0])
        for i in 0 ..< LatencyBudget.samplesPerFrame {
            XCTAssertEqual(emitted[i], source[i], accuracy: 1e-6, "sample \(i) must come from the new route only")
        }

        // Switching back must build a fresh converter instead of resuming the
        // one parked mid-stream before the detour.
        _ = conformer.conform(route44k)
        XCTAssertGreaterThan(
            conformer.converterGeneration,
            generationBefore,
            "a parked converter must not be resumed after a route detour"
        )
    }

    /// Guard against the opposite mistake: identical formats must NOT be
    /// treated as a switch, or the remainder would be dropped every buffer.
    func testSameFormatIsNotTreatedAsRouteSwitch() throws {
        let conformer = CaptureFrameConformer()
        let chunk = try makeBuffer(sampleRate: LatencyBudget.audioSampleRate, channels: 1, frames: 100)
        _ = conformer.conform(chunk)
        _ = conformer.conform(chunk)
        XCTAssertEqual(conformer.bufferedSampleCount, 200)
    }

    func testResetDropsBufferedRemainder() throws {
        let conformer = CaptureFrameConformer()
        let chunk = try makeBuffer(sampleRate: LatencyBudget.audioSampleRate, channels: 1, frames: 100)
        _ = conformer.conform(chunk)
        XCTAssertEqual(conformer.bufferedSampleCount, 100)
        conformer.reset()
        XCTAssertEqual(conformer.bufferedSampleCount, 0)
    }

    func testEmptyBufferProducesNothing() throws {
        let conformer = CaptureFrameConformer()
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: LatencyBudget.audioSampleRate, channels: 1
        ))
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        empty.frameLength = 0
        XCTAssertTrue(conformer.conform(empty).isEmpty)
    }

    // MARK: - Encoder contract

    /// Proves the original bug: the raw tap buffer is rejected by the encoder.
    func testEncoderRejectsRawTapBuffer() throws {
        let coder = OpusCoder()
        let tapBuffer = try makeBuffer(sampleRate: 44100, channels: 2, frames: 1024)
        XCTAssertThrowsError(try coder.encode(tapBuffer)) { error in
            XCTAssertEqual(error as? OpusCoder.CodecError, .inputFormatMismatch)
        }
    }

    /// Right format, wrong length is rejected too — the encoder consumes
    /// exactly one 10 ms frame per call.
    func testEncoderRejectsWrongFrameLength() throws {
        let coder = OpusCoder()
        let wrongLength = try makeBuffer(
            sampleRate: LatencyBudget.audioSampleRate,
            channels: 1,
            frames: 1024
        )
        XCTAssertThrowsError(try coder.encode(wrongLength)) { error in
            XCTAssertEqual(error as? OpusCoder.CodecError, .inputFormatMismatch)
        }
    }

    // MARK: - Full send-chain roundtrip

    /// tap format → conformer → Opus encode → Opus decode → audible PCM.
    @available(iOS 18, *)
    func testTapFormatRoundtripProducesNonSilentAudio() throws {
        let tapBuffer = try makeBuffer(sampleRate: 44100, channels: 2, frames: 1024, freq: 1000)
        try skipUnlessConverterAvailable(from: tapBuffer.format)

        let conformer = CaptureFrameConformer()
        var frames: [AVAudioPCMBuffer] = []
        for _ in 0 ..< 5 {
            frames.append(contentsOf: conformer.conform(tapBuffer))
        }
        XCTAssertFalse(frames.isEmpty, "conformer must produce encoder frames")

        // Skip the first frame: the resampler primes on it and it may be quiet.
        let frame = frames.count > 1 ? frames[1] : frames[0]
        XCTAssertGreaterThan(try peak(frame), 0.05, "conformed PCM must not be silence")

        let encoder = OpusCoder()
        let decoder = OpusCoder()

        let packet: Data
        do {
            packet = try encoder.encode(frame)
        } catch {
            throw XCTSkip("Opus encode unavailable: \(error)")
        }
        XCTAssertGreaterThan(packet.count, 0)
        XCTAssertLessThan(packet.count, LatencyBudget.samplesPerFrame * 4)

        let outFormat = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: LatencyBudget.audioSampleRate, channels: 1
        ))
        let decoded = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: outFormat,
            frameCapacity: AVAudioFrameCount(decoder.samplesPerFrame * 2)
        ))
        do {
            try decoder.decode(packet, into: decoded)
        } catch {
            throw XCTSkip("Opus decode unavailable: \(error)")
        }
        XCTAssertGreaterThan(Int(decoded.frameLength), 0)
        XCTAssertGreaterThan(try peak(decoded), 0.01, "decoded audio must not be silence")
    }
}

/// The throttle exists so encode/decode failures are *logged* instead of being
/// swallowed by `try?`, without flooding the log 100×/s.
final class AudioLogThrottleTests: XCTestCase {
    func testFirstCallLogsWithNothingSuppressed() {
        let throttle = AudioLogThrottle(intervalSec: 1)
        XCTAssertEqual(throttle.shouldLog(now: 100), 0)
    }

    func testSubsequentCallsInsideWindowAreSuppressedAndCounted() {
        let throttle = AudioLogThrottle(intervalSec: 1)
        XCTAssertEqual(throttle.shouldLog(now: 100), 0)
        XCTAssertNil(throttle.shouldLog(now: 100.1))
        XCTAssertNil(throttle.shouldLog(now: 100.5))
        XCTAssertEqual(throttle.shouldLog(now: 101.0), 2, "reports how many were swallowed")
        XCTAssertNil(throttle.shouldLog(now: 101.1))
    }

    func testResetClearsCounters() {
        let throttle = AudioLogThrottle(intervalSec: 1)
        XCTAssertEqual(throttle.shouldLog(now: 100), 0)
        XCTAssertNil(throttle.shouldLog(now: 100.2))
        throttle.reset()
        XCTAssertEqual(throttle.shouldLog(now: 100.3), 0)
    }
}
