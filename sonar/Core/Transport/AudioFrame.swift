import Foundation

/// A single 20ms audio frame with sequence number and routing metadata.
/// §2.4 — used by MultipathBonder to send on all paths and deduplicate on receive.
struct AudioFrame: Sendable {
    let seq: UInt32
    let timestamp: UInt64       // mach_absolute_time ticks
    let payload: Data           // Opus-encoded bytes
    let codecID: CodecID

    enum CodecID: UInt8, Sendable {
        case opus   = 0
        case lyraV2 = 1
    }

    init(seq: UInt32, timestamp: UInt64 = mach_absolute_time(), payload: Data, codec: CodecID = .opus) {
        self.seq = seq
        self.timestamp = timestamp
        self.payload = payload
        self.codecID = codec
    }
}

extension AudioFrame {
    /// Wire encoding: 4B seq + 8B ts + 1B codec + payload.
    var wireData: Data {
        var d = Data(capacity: 13 + payload.count)
        withUnsafeBytes(of: seq.bigEndian)       { d.append(contentsOf: $0) }
        withUnsafeBytes(of: timestamp.bigEndian) { d.append(contentsOf: $0) }
        d.append(codecID.rawValue)
        d.append(payload)
        return d
    }

    init?(wireData: Data) {
        guard wireData.count >= 13 else { return nil }
        self.seq       = wireData[0..<4].withUnsafeBytes { $0.load(as: UInt32.self).byteSwapped }
        self.timestamp = wireData[4..<12].withUnsafeBytes { $0.load(as: UInt64.self).byteSwapped }
        guard let codec = CodecID(rawValue: wireData[12]) else { return nil }
        self.codecID = codec
        self.payload = wireData[13...]
    }
}
