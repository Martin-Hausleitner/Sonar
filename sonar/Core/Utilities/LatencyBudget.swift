import Foundation

/// All latency-related constants in one place. See `LATENCY.md` for the
/// reasoning behind each value.
enum LatencyBudget {
    // MARK: - Audio sampling

    /// Frame duration in milliseconds. Smaller = lower latency, more CPU.
    /// 10 ms is the sweet spot per Plan §10/3 + RESEARCH.md §2.
    static let audioFrameMs: Int = 10

    /// Sample rate in Hz. Mono channel.
    static let audioSampleRate: Double = 48_000

    /// Samples per frame. Computed from `audioFrameMs` and `audioSampleRate`.
    static var samplesPerFrame: Int {
        Int(audioSampleRate * Double(audioFrameMs) / 1000.0)
    }

    /// Preferred IO buffer duration in seconds. iOS may round to nearest
    /// hardware-supported value (typically 5 ms or 10 ms).
    static let preferredIOBufferDurationSec: TimeInterval = 0.005

    // MARK: - Opus codec

    /// Encoder complexity 0…10. Lower = faster encode, slightly worse quality.
    /// 5 = balanced. Apple Voice Memos uses ~5.
    static let opusComplexity: Int32 = 5

    /// Bitrate in bps. 24 kbps is plenty for mono voice at 48 kHz.
    static let opusBitrateBps: Int32 = 24_000

    /// Forward Error Correction. On for Far, off for Near (FEC adds 2–4 ms).
    static let opusFECEnabledNear: Bool = false
    static let opusFECEnabledFar: Bool = true

    /// Discontinuous Transmission — saves bandwidth during silence.
    static let opusDTXEnabled: Bool = true

    // MARK: - Jitter buffer

    /// Jitter buffer depth in milliseconds. Smaller = lower latency, more
    /// glitches when packets arrive out of order. Adapts up if loss > 2 %.
    static let jitterBufferMsNear: Int = 10
    static let jitterBufferMsFar: Int = 50

    // MARK: - Transport switching

    /// Crossfade duration when switching between Near and Far. Below 50 ms
    /// risks a click; 100 ms is the smallest tested-clean value.
    static let crossfadeMs: Int = 100

    // MARK: - Duplicate-voice suppressor

    /// Recent-fingerprint correlation window. Short = catches close-in echoes
    /// fast, longer = more robust against partial matches. 100 ms covers the
    /// AirPods round-trip plus typical room reverb.
    static let duplicateSuppressorWindowMs: Int = 100

    /// Correlation threshold above which we duck the digital stream.
    static let duplicateSuppressorThreshold: Float = 0.6

    /// Suppression gain when threshold is exceeded. -30 dB ≈ 0.0316.
    static let duplicateSuppressorGainOnDuck: Float = 0.0316

    // MARK: - Glass-to-glass alarms (Plan §11)

    static let nearTargetGlassToGlassMs: Int = 60
    static let nearAlarmGlassToGlassMs: Int = 150

    static let farTargetGlassToGlassMs: Int = 250
    static let farAlarmGlassToGlassMs: Int = 500

    // MARK: - Per-stage warnings

    static let captureToEncodeWarnMs: Double = 12
    static let encodeToWireWarnMs: Double = 8
    static let wireToDecodeWarnMs: Double = 30
    static let decodeToOutputWarnMs: Double = 12
}
