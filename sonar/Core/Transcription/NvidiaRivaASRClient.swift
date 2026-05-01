import Foundation

enum NvidiaRivaASRClient {
    enum ClientError: Error {
        case invalidRequest
        case invalidGRPCFrame
        case noTranscript
        case httpStatus(Int)
    }

    static let hostedFunctionID = "d3fe9151-442b-4204-a70d-5fcc597fd610"

    private static let hostedURL = URL(
        string: "https://grpc.nvcf.nvidia.com:443/nvidia.riva.asr.RivaSpeechRecognition/Recognize"
    )!

    static func transcribeHosted(
        apiKey: String,
        pcm16LE: Data,
        sampleRate: Int,
        languageCode: String = "en-US"
    ) async throws -> String {
        let request = try makeHostedRecognizeRequest(
            apiKey: apiKey,
            pcm16LE: pcm16LE,
            sampleRate: sampleRate,
            languageCode: languageCode
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.httpStatus(http.statusCode)
        }
        return try extractTranscript(fromGRPCResponse: data)
    }

    static func makeHostedRecognizeRequest(
        apiKey: String,
        pcm16LE: Data,
        sampleRate: Int,
        languageCode: String
    ) throws -> URLRequest {
        guard !apiKey.isEmpty, !pcm16LE.isEmpty, sampleRate > 0 else {
            throw ClientError.invalidRequest
        }

        var request = URLRequest(url: hostedURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(hostedFunctionID, forHTTPHeaderField: "function-id")
        request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
        request.setValue("trailers", forHTTPHeaderField: "TE")
        request.httpBody = makeGRPCFrame(
            payload: makeRecognizeRequestPayload(
                pcm16LE: pcm16LE,
                sampleRate: sampleRate,
                languageCode: languageCode
            )
        )
        return request
    }

    static func makeGRPCFrame(payload: Data) -> Data {
        var frame = Data([0])
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    static func grpcPayloadLength(frame: Data) -> Int {
        guard frame.count >= 5 else { return -1 }
        var length: UInt32 = 0
        for byte in frame[1..<5] {
            length = (length << 8) | UInt32(byte)
        }
        return Int(length)
    }

    static func extractTranscript(fromGRPCResponse data: Data) throws -> String {
        var offset = data.startIndex
        while offset < data.endIndex {
            guard data.distance(from: offset, to: data.endIndex) >= 5 else {
                throw ClientError.invalidGRPCFrame
            }
            let compressed = data[offset]
            guard compressed == 0 else { throw ClientError.invalidGRPCFrame }
            let lengthStart = data.index(after: offset)
            let lengthEnd = data.index(lengthStart, offsetBy: 4)
            var length: UInt32 = 0
            for byte in data[lengthStart..<lengthEnd] {
                length = (length << 8) | UInt32(byte)
            }

            let payloadStart = lengthEnd
            let payloadEnd = data.index(payloadStart, offsetBy: Int(length), limitedBy: data.endIndex)
            guard let payloadEnd else { throw ClientError.invalidGRPCFrame }
            let payload = data[payloadStart..<payloadEnd]

            if let text = firstTranscript(in: Data(payload)), !text.isEmpty {
                return text
            }
            offset = payloadEnd
        }
        throw ClientError.noTranscript
    }

    private static func makeRecognizeRequestPayload(
        pcm16LE: Data,
        sampleRate: Int,
        languageCode: String
    ) -> Data {
        var config = Data()
        config.append(Proto.varint(field: 1, value: 1)) // LINEAR_PCM
        config.append(Proto.varint(field: 2, value: UInt64(sampleRate)))
        config.append(Proto.string(field: 3, value: languageCode))
        config.append(Proto.varint(field: 4, value: 1))
        config.append(Proto.varint(field: 7, value: 1))
        config.append(Proto.bool(field: 8, value: true))
        config.append(Proto.bool(field: 11, value: true))

        var request = Data()
        request.append(Proto.lengthDelimited(field: 1, payload: config))
        request.append(Proto.lengthDelimited(field: 2, payload: pcm16LE))
        return request
    }

    private static func firstTranscript(in recognizeResponse: Data) -> String? {
        for result in Proto.lengthDelimitedFields(number: 1, in: recognizeResponse) {
            for alternative in Proto.lengthDelimitedFields(number: 1, in: result) {
                for transcript in Proto.lengthDelimitedFields(number: 1, in: alternative) {
                    if let text = String(data: transcript, encoding: .utf8), !text.isEmpty {
                        return text
                    }
                }
            }
        }
        return nil
    }
}

private enum Proto {
    static func varint(field: Int, value: UInt64) -> Data {
        key(field: field, wireType: 0) + encodeVarint(value)
    }

    static func bool(field: Int, value: Bool) -> Data {
        varint(field: field, value: value ? 1 : 0)
    }

    static func string(field: Int, value: String) -> Data {
        lengthDelimited(field: field, payload: Data(value.utf8))
    }

    static func lengthDelimited(field: Int, payload: Data) -> Data {
        key(field: field, wireType: 2) + encodeVarint(UInt64(payload.count)) + payload
    }

    static func lengthDelimitedFields(number: Int, in data: Data) -> [Data] {
        var matches: [Data] = []
        var index = data.startIndex

        while index < data.endIndex {
            guard let key = readVarint(from: data, index: &index) else { break }
            let fieldNumber = Int(key >> 3)
            let wireType = Int(key & 0x07)

            switch wireType {
            case 0:
                _ = readVarint(from: data, index: &index)
            case 1:
                guard let next = data.index(index, offsetBy: 8, limitedBy: data.endIndex) else { return matches }
                index = next
            case 2:
                guard let length = readVarint(from: data, index: &index),
                      let end = data.index(index, offsetBy: Int(length), limitedBy: data.endIndex) else {
                    return matches
                }
                if fieldNumber == number {
                    matches.append(Data(data[index..<end]))
                }
                index = end
            case 5:
                guard let next = data.index(index, offsetBy: 4, limitedBy: data.endIndex) else { return matches }
                index = next
            default:
                return matches
            }
        }

        return matches
    }

    private static func key(field: Int, wireType: Int) -> Data {
        encodeVarint(UInt64((field << 3) | wireType))
    }

    private static func encodeVarint(_ value: UInt64) -> Data {
        var data = Data()
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
        return data
    }

    private static func readVarint(from data: Data, index: inout Data.Index) -> UInt64? {
        var shift: UInt64 = 0
        var value: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index = data.index(after: index)
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}
