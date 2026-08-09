import AVFoundation
import Foundation

/// Real Opus codec via iOS-native AVAudioConverter (kAudioFormatOpus, iOS 16+).
/// Plan §10/3, RESEARCH.md §2, LATENCY.md.
///
/// Settings from LatencyBudget:
///   48 kHz / mono / 10 ms frames / 24 kbps VBR / complexity 5
///
/// Converters are created lazily and reused; creating one per frame would add
/// ~2 ms of setup overhead to every encode/decode call.
final class OpusCoder {
    enum CodecError: Error, Equatable {
        case notConfigured
        case encodeFailed
        case decodeFailed
        /// The PCM buffer handed to `encode` is not exactly the encoder's
        /// format / frame size. Feed it through `CaptureFrameConformer` first.
        case inputFormatMismatch
    }

    /// Apple's AVAudioConverter Opus encoder does not expose libopus'
    /// OPUS_SET_INBAND_FEC / OPUS_SET_PACKET_LOSS_PERC controls.
    static let supportsForwardErrorCorrection = false

    let sampleRate: Double
    let frameMs: Int
    let bitrate: Int32
    let complexity: Int32

    private let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat
    private var _encoder: AVAudioConverter?
    private var _decoder: AVAudioConverter?

    init(
        sampleRate: Double = LatencyBudget.audioSampleRate,
        frameMs: Int = LatencyBudget.audioFrameMs,
        bitrate: Int32 = LatencyBudget.opusBitrateBps,
        complexity: Int32 = LatencyBudget.opusComplexity
    ) {
        self.sampleRate = sampleRate
        self.frameMs = frameMs
        self.bitrate = bitrate
        self.complexity = complexity

        pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        // kAudioFormatOpus is available on iOS 16+ (project min: iOS 18).
        // mFramesPerPacket = PCM samples per Opus frame (10 ms × 48 kHz = 480).
        var desc = AudioStreamBasicDescription()
        desc.mSampleRate = sampleRate
        desc.mFormatID = kAudioFormatOpus
        desc.mChannelsPerFrame = 1
        desc.mFramesPerPacket = UInt32(sampleRate * Double(frameMs) / 1000.0)
        opusFormat = AVAudioFormat(streamDescription: &desc)!
    }

    /// PCM samples consumed per encode call.
    var samplesPerFrame: Int {
        Int(sampleRate * Double(frameMs) / 1000.0)
    }

    /// Codec's contribution to glass-to-glass latency, in ms.
    var theoreticalEncodeLatencyMs: Double {
        Double(frameMs)
    }

    // MARK: - Encode (PCM Float32 → Opus bytes)

    /// The exact PCM format `encode` accepts: 48 kHz / mono / Float32,
    /// deinterleaved. Exposed so capture-side components can conform to it.
    var encoderInputFormat: AVAudioFormat { pcmFormat }

    func encode(_ buffer: AVAudioPCMBuffer) throws -> Data {
        // AVAudioConverter silently errors out when the source buffer is not in
        // the format the converter was created with, or when it does not hold a
        // whole Opus frame. Reject it up front with a diagnosable error instead
        // of letting it look like a generic encode failure.
        guard buffer.format == pcmFormat, Int(buffer.frameLength) == samplesPerFrame else {
            throw CodecError.inputFormatMismatch
        }

        let enc = try encoder()

        // 512 bytes is comfortably above the Opus packet ceiling at 24 kbps / 10 ms (~30 B).
        let out = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: 512
        )

        var provided = false
        var convErr: NSError?
        let status = enc.convert(to: out, error: &convErr) { _, outStatus in
            guard !provided else { outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, convErr == nil, out.byteLength > 0 else {
            throw CodecError.encodeFailed
        }
        return Data(bytes: out.data, count: Int(out.byteLength))
    }

    // MARK: - Decode (Opus bytes → PCM Float32)

    func decode(_ data: Data, into buffer: AVAudioPCMBuffer) throws {
        let dec = try decoder()
        // Empty payload would force-unwrap-crash on baseAddress below, and
        // AVAudioCompressedBuffer rejects maximumPacketSize == 0 anyway.
        guard !data.isEmpty else { throw CodecError.decodeFailed }

        let inp = AVAudioCompressedBuffer(
            format: opusFormat,
            packetCapacity: 1,
            maximumPacketSize: data.count
        )
        let copied: Bool = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            inp.data.copyMemory(from: base, byteCount: data.count)
            return true
        }
        guard copied else { throw CodecError.decodeFailed }
        inp.byteLength = UInt32(data.count)
        inp.packetCount = 1
        inp.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(data.count)
        )

        // The converter writes `frameLength` itself, but only ever *up to*
        // `frameCapacity`. Reset it first so a recycled output buffer can never
        // be mistaken for freshly decoded audio when the conversion yields
        // nothing.
        buffer.frameLength = 0

        var provided = false
        var convErr: NSError?
        let status = dec.convert(to: buffer, error: &convErr) { _, outStatus in
            guard !provided else { outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return inp
        }
        guard status != .error, convErr == nil else { throw CodecError.decodeFailed }
        // Zero decoded frames means the packet produced no audio — scheduling
        // that buffer would be an inaudible no-op, so surface it as an error.
        guard buffer.frameLength > 0 else { throw CodecError.decodeFailed }
    }

    // MARK: - Private

    private func encoder() throws -> AVAudioConverter {
        if let e = _encoder { return e }
        guard let e = AVAudioConverter(from: pcmFormat, to: opusFormat) else {
            throw CodecError.notConfigured
        }
        e.bitRate = Int(bitrate)
        _encoder = e
        return e
    }

    private func decoder() throws -> AVAudioConverter {
        if let d = _decoder { return d }
        guard let d = AVAudioConverter(from: opusFormat, to: pcmFormat) else {
            throw CodecError.notConfigured
        }
        _decoder = d
        return d
    }
}
