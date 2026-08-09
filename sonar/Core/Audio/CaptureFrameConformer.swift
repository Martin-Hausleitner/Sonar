import AVFoundation
import Foundation
import os

/// Coalesces repeated errors on hot audio paths down to at most one log line
/// per `interval`, remembering how many were swallowed in between.
///
/// The capture/encode path runs 100–200×/s. Logging every failure floods the
/// log (and costs latency), while logging *nothing* is exactly what hid the
/// v0.2.19 bug where no frame ever left the device.
final class AudioLogThrottle: Sendable {
    private struct State {
        var lastLog: TimeInterval = -.greatestFiniteMagnitude
        var suppressed: Int = 0
    }

    private let interval: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(intervalSec: TimeInterval = 1.0) {
        interval = intervalSec
    }

    /// Returns the number of events swallowed since the previous emitted log
    /// when the caller should log now, or `nil` while inside the quiet window.
    func shouldLog(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Int? {
        state.withLock { state in
            guard now - state.lastLog >= interval else {
                state.suppressed += 1
                return nil
            }
            let suppressed = state.suppressed
            state.suppressed = 0
            state.lastLog = now
            return suppressed
        }
    }

    func reset() {
        state.withLock { $0 = State() }
    }
}

/// Bridges the microphone tap's *hardware* format to the Opus encoder's
/// *fixed* format.
///
/// `AVAudioEngine.inputNode.inputFormat(forBus: 0)` hands us whatever the
/// current route produces — 44.1 kHz or 24 kHz, mono or stereo — and the tap's
/// `bufferSize` argument is only a hint, so buffers arrive with arbitrary frame
/// counts. `OpusCoder`, in contrast, accepts only its own PCM format
/// (48 kHz / mono / Float32, deinterleaved) in exactly `samplesPerFrame`-sized
/// chunks. Feeding it a raw tap buffer makes `AVAudioConverter` fail, and the
/// old `try?` at the call site swallowed that failure — so the send chain never
/// produced a single packet.
///
/// `conform(_:)` therefore
///  1. converts each incoming buffer with one long-lived `AVAudioConverter`
///     (kept alive across calls so the resampler stays phase-continuous — a
///     fresh converter per buffer would click and drop the tail samples), and
///  2. accumulates the converted samples, emitting 0…n buffers of exactly
///     `samplesPerFrame` frames and carrying the remainder into the next call.
///
/// Not thread-safe: drive it from one serial queue (the capture sink).
final class CaptureFrameConformer {
    /// 48 kHz mono Float32 deinterleaved — identical to `OpusCoder.pcmFormat`.
    static let defaultOutputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: LatencyBudget.audioSampleRate,
        channels: 1,
        interleaved: false
    )!

    let outputFormat: AVAudioFormat

    /// Frames per emitted buffer (10 ms @ 48 kHz = 480).
    let samplesPerFrame: Int

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    /// Format of the previous tap buffer, used to detect route switches even
    /// when the new route takes the pass-through fast path.
    private var lastInputFormat: AVAudioFormat?

    /// Number of converters built so far. Diagnostics/test hook: a route switch
    /// must build a *new* converter rather than resume a parked one.
    private(set) var converterGeneration = 0

    /// Converted-but-not-yet-emitted samples (the remainder of the previous
    /// tap buffer). Never grows beyond one frame between calls.
    private var pending: [Float] = []

    private let errorThrottle: AudioLogThrottle

    init(
        outputFormat: AVAudioFormat = CaptureFrameConformer.defaultOutputFormat,
        samplesPerFrame: Int = LatencyBudget.samplesPerFrame,
        errorThrottle: AudioLogThrottle = AudioLogThrottle()
    ) {
        self.outputFormat = outputFormat
        self.samplesPerFrame = max(1, samplesPerFrame)
        self.errorThrottle = errorThrottle
        pending.reserveCapacity(self.samplesPerFrame * 4)
    }

    /// Samples buffered for the next frame. Test/diagnostics hook.
    var bufferedSampleCount: Int { pending.count }

    /// Convert `buffer` and return every complete encoder frame that became
    /// available. May return an empty array (input shorter than one frame) or
    /// several buffers (input longer, or leftovers from earlier calls).
    func conform(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        guard buffer.frameLength > 0 else { return [] }
        appendConverted(buffer)
        return drainFrames()
    }

    /// Drop converter state + leftovers. Call on session start/stop so a new
    /// session never emits a frame stitched from the previous route's audio.
    func reset() {
        discardStreamState()
        lastInputFormat = nil
        errorThrottle.reset()
    }

    // MARK: - Private

    private func appendConverted(_ buffer: AVAudioPCMBuffer) {
        // A route change (speaker → AirPods → speaker) swaps the tap format.
        // Both the resampler state and the half-collected frame belong to the
        // *old* route; carrying either across the switch would stitch two
        // different points in time together — and reusing a converter that was
        // parked mid-stream would resume it with stale filter state.
        noteInputFormat(buffer.format)

        // Fast path: the route already delivers exactly the encoder's format.
        if buffer.format == outputFormat {
            append(buffer)
            return
        }

        guard let converter = makeOrReuseConverter(for: buffer.format) else {
            discardStreamState()
            return
        }

        // Sample-rate conversion can emit slightly more frames than the naive
        // ratio suggests (filter delay flush), so add headroom — an undersized
        // output buffer would make the converter stall and drop input.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 128
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            guard !provided else {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil else {
            logError("capture conversion \(buffer.format.sampleRate) Hz/\(buffer.format.channelCount) ch → encoder format failed: \(conversionError?.localizedDescription ?? "unknown")")
            // The converter's internal state is undefined after an error and
            // the buffered remainder now predates a gap of unknown length.
            // Start the stream over rather than stitching across the hole.
            discardStreamState()
            return
        }
        append(converted)
    }

    /// Notice route/format switches — including switching *into* and out of the
    /// pass-through fast path, which never touches the converter and would
    /// otherwise leave stale resampler state parked for the way back.
    private func noteInputFormat(_ format: AVAudioFormat) {
        let previous = lastInputFormat
        lastInputFormat = format
        guard let previous, previous != format else { return }
        discardStreamState()
    }

    /// Drop everything tied to the current input stream: the half-collected
    /// frame and the converter carrying its resampler state.
    private func discardStreamState() {
        pending.removeAll(keepingCapacity: true)
        converter = nil
        converterInputFormat = nil
    }

    /// Append channel 0 of an already-conformed buffer to `pending`.
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return }
        pending.append(
            contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
        )
    }

    private func drainFrames() -> [AVAudioPCMBuffer] {
        var frames: [AVAudioPCMBuffer] = []
        while pending.count >= samplesPerFrame {
            guard
                let frame = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(samplesPerFrame)
                ),
                let destination = frame.floatChannelData?[0]
            else { break }
            frame.frameLength = AVAudioFrameCount(samplesPerFrame)
            pending.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    destination.update(from: base, count: samplesPerFrame)
                }
            }
            pending.removeFirst(samplesPerFrame)
            frames.append(frame)
        }
        return frames
    }

    private func makeOrReuseConverter(for inputFormat: AVAudioFormat) -> AVAudioConverter? {
        if let converter, let current = converterInputFormat, current == inputFormat {
            return converter
        }
        guard let created = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            logError("no AVAudioConverter for \(inputFormat.sampleRate) Hz/\(inputFormat.channelCount) ch → encoder format")
            converter = nil
            converterInputFormat = nil
            return nil
        }
        // Medium keeps the resampler's own latency and CPU cost low; the
        // difference is inaudible for 32 kbps speech.
        created.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        converter = created
        converterInputFormat = inputFormat
        converterGeneration += 1
        // Fresh converter ⇒ fresh sample timeline; drop any stale remainder.
        pending.removeAll(keepingCapacity: true)
        return created
    }

    private func logError(_ message: String) {
        guard let suppressed = errorThrottle.shouldLog() else { return }
        Log.audio.error(
            "CaptureFrameConformer: \(message, privacy: .public) (\(suppressed, privacy: .public) similar errors suppressed)"
        )
    }
}
