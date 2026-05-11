@testable import Sonar
import XCTest

final class PairingTokenTests: XCTestCase {
    func testEncodeDecodeRoundTripPreservesAllFields() throws {
        let token = PairingToken(
            id: "SIM-A-38D0B9",
            name: "iPhone von Martin",
            bonjour: PairingToken.mpcBonjourServiceName,
            host: "martin-iphone.local",
            tsIP: "100.64.1.42",
            ble: "B8C9D0E1-1234-5678-9ABC-DEF012345678",
            ts: 1_750_000_000
        )

        let encoded = token.encodedString()
        XCTAssertFalse(encoded.isEmpty, "Encoded token must not be empty")

        let decoded = try XCTUnwrap(PairingToken.decode(encoded), "Round-trip decode must succeed")

        XCTAssertEqual(decoded, token)
        XCTAssertEqual(decoded.v, PairingToken.currentVersion)
        XCTAssertEqual(decoded.id, "SIM-A-38D0B9")
        XCTAssertEqual(decoded.name, "iPhone von Martin")
        XCTAssertEqual(decoded.bonjour, PairingToken.mpcBonjourServiceName)
        XCTAssertEqual(decoded.host, "martin-iphone.local")
        XCTAssertEqual(decoded.tsIP, "100.64.1.42")
        XCTAssertEqual(decoded.ble, "B8C9D0E1-1234-5678-9ABC-DEF012345678")
        XCTAssertEqual(decoded.ts, 1_750_000_000)
    }

    func testEncodeRoundTripWithOptionalFieldsNil() throws {
        let token = PairingToken(
            id: "SIM-B-97D949",
            name: "Sim B",
            host: "",
            tsIP: nil,
            ble: nil,
            ts: 1_750_000_001
        )
        let payload = token.encodedString()
        let decoded = try XCTUnwrap(PairingToken.decode(payload))
        XCTAssertEqual(decoded, token)
        XCTAssertNil(decoded.tsIP)
        XCTAssertNil(decoded.ble)
    }

    func testDefaultBonjourUsesMPCServiceName() {
        let token = PairingToken(
            id: "SIM-C-A1B2C3",
            name: "Sim C",
            host: "sim-c.local",
            ts: 1_750_000_002
        )

        XCTAssertEqual(token.bonjour, "_sonar-mpc._tcp")
    }

    @MainActor
    func testGeneratedTokenUsesMPCBonjourServiceName() {
        let appState = AppState()
        appState.localDisplayName = "Generated Sim"

        let token = PairingTokenGenerator.makeToken(
            appState: appState,
            now: Date(timeIntervalSince1970: 1_750_000_003)
        )

        XCTAssertEqual(token.bonjour, "_sonar-mpc._tcp")
    }

    func testQRCodeHostRejectsLocalhostAndLoopbackValues() {
        XCTAssertNil(PairingTokenGenerator.qrReachableHost(fromBonjourHostname: "localhost"))
        XCTAssertNil(PairingTokenGenerator.qrReachableHost(fromBonjourHostname: "localhost.local"))
        XCTAssertNil(PairingTokenGenerator.qrReachableHost(fromBonjourHostname: "127.0.0.1"))
        XCTAssertNil(PairingTokenGenerator.qrReachableHost(fromBonjourHostname: "::1"))
    }

    func testQRCodeHostKeepsReachableBonjourAndLANValues() {
        XCTAssertEqual(
            PairingTokenGenerator.qrReachableHost(fromBonjourHostname: "Martins-iPhone"),
            "Martins-iPhone.local"
        )
        XCTAssertEqual(
            PairingTokenGenerator.qrReachableHost(fromBonjourHostname: "Martins-iPhone.local"),
            "Martins-iPhone.local"
        )
        XCTAssertEqual(
            PairingTokenGenerator.qrReachableHost(fromBonjourHostname: "192.168.1.42"),
            "192.168.1.42"
        )
    }

    func testQRTailscaleIPKeepsOnlyTailscaleCGNATAddresses() {
        XCTAssertEqual(PairingTokenGenerator.qrReachableTailscaleIP("100.96.1.42"), "100.96.1.42")
        XCTAssertNil(PairingTokenGenerator.qrReachableTailscaleIP("127.0.0.1"))
        XCTAssertNil(PairingTokenGenerator.qrReachableTailscaleIP("localhost"))
        XCTAssertNil(PairingTokenGenerator.qrReachableTailscaleIP("192.168.1.42"))
    }

    func testDecodeRejectsUnsupportedVersion() {
        // Construct a v=99 token by hand and base64url-encode it, then try
        // to decode through the public API — should be rejected.
        let json = #"{"v":99,"id":"X","name":"X","bonjour":"_sonar-mpc._tcp","host":"h","ts":1}"#
        let b64 = Data(json.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertNil(
            PairingToken.decode(b64),
            "v=99 must be rejected as unsupported schema version"
        )
    }

    func testDecodeRejectsMalformedJSON() {
        // Garbage base64 → not valid JSON after decoding.
        let garbage = "this-is-not-base64-or-json!!!"
        XCTAssertNil(
            PairingToken.decode(garbage),
            "Malformed payload must decode to nil"
        )
    }

    func testDecodeRejectsEmptyString() {
        XCTAssertNil(PairingToken.decode(""))
    }

    func testDecodeRejectsTruncatedJSON() {
        // Valid base64url but invalid JSON body → must reject.
        let truncated = Data(#"{"v":1,"id":"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertNil(PairingToken.decode(truncated))
    }
}
