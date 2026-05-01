import XCTest

@testable import Sonar

final class NvidiaRivaASRClientTests: XCTestCase {
    func testHostedRequestUsesNvidiaGRPCGatewayNotIntegrateHTTPAudioEndpoint() throws {
        let request = try NvidiaRivaASRClient.makeHostedRecognizeRequest(
            apiKey: "nvapi-test",
            pcm16LE: Data([0x01, 0x00, 0x02, 0x00]),
            sampleRate: 16_000,
            languageCode: "en-US"
        )

        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "grpc.nvcf.nvidia.com")
        XCTAssertEqual(request.url?.path, "/nvidia.riva.asr.RivaSpeechRecognition/Recognize")
        XCTAssertFalse(request.url!.absoluteString.contains("integrate.api.nvidia.com"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer nvapi-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "function-id"), NvidiaRivaASRClient.hostedFunctionID)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/grpc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "TE"), "trailers")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testHostedRequestBodyIsGRPCFramedRecognizeRequest() throws {
        let request = try NvidiaRivaASRClient.makeHostedRecognizeRequest(
            apiKey: "nvapi-test",
            pcm16LE: Data([0x01, 0x00, 0x02, 0x00]),
            sampleRate: 16_000,
            languageCode: "en-US"
        )

        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(body.first, 0, "gRPC request must use an uncompressed frame")
        XCTAssertEqual(NvidiaRivaASRClient.grpcPayloadLength(frame: body), body.count - 5)
        XCTAssertTrue(body.contains(Data("en-US".utf8)))
    }

    func testRecognizeResponseParserExtractsTopTranscriptFromGRPCFrame() throws {
        let responsePayload = makeRecognizeResponsePayload(transcript: "hello sonar")
        let grpcFrame = NvidiaRivaASRClient.makeGRPCFrame(payload: responsePayload)

        XCTAssertEqual(try NvidiaRivaASRClient.extractTranscript(fromGRPCResponse: grpcFrame), "hello sonar")
    }

    func testRecognizeResponseParserRejectsEmptyGRPCFrame() {
        XCTAssertThrowsError(try NvidiaRivaASRClient.extractTranscript(fromGRPCResponse: Data()))
    }

    private func makeRecognizeResponsePayload(transcript: String) -> Data {
        let alternative = Data([0x0A]) + protobufLengthDelimited(Data(transcript.utf8))
        let result = Data([0x0A]) + protobufLengthDelimited(alternative)
        return Data([0x0A]) + protobufLengthDelimited(result)
    }

    private func protobufLengthDelimited(_ payload: Data) -> Data {
        var data = Data()
        var value = UInt64(payload.count)
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
        data.append(payload)
        return data
    }
}
