import AVFoundation
import Foundation

/// Wraps libopus. Plan §10/3, RESEARCH.md §2.
/// Settings: 48 kHz / mono / 20 ms frames / 24 kbps VBR / DTX + FEC on.
final class OpusCoder {
    enum CodecError: Error { case notConfigured }

    init(sampleRate: Double = 48_000, frameMilliseconds: Int = 20, bitrate: Int = 24_000) {
        // TODO §10/3: bridge libopus encoder/decoder.
    }

    func encode(_ buffer: AVAudioPCMBuffer) throws -> Data {
        // TODO §10/3
        throw CodecError.notConfigured
    }

    func decode(_ data: Data, into buffer: AVAudioPCMBuffer) throws {
        // TODO §10/3
        throw CodecError.notConfigured
    }
}
