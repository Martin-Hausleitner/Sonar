import XCTest

@testable import Sonar

final class SonarTestIdentityTests: XCTestCase {

    func testEnvironmentConfiguresStableDeviceAndRelay() throws {
        let identity = SonarTestIdentity(
            environment: [
                "SONAR_TEST_DEVICE_ID": "SIM-A-38D0B9",
                "SONAR_TEST_DEVICE_NAME": "SIM-A",
                "SONAR_SIM_RELAY_URL": "http://127.0.0.1:8787",
                "SONAR_AUTOSTART_SESSION": "1"
            ],
            arguments: [],
            vendorIdentifier: "SHOULD-NOT-WIN",
            fallbackDeviceName: "Fallback iPhone"
        )

        XCTAssertEqual(identity.deviceID, "SIM-A-38D0B9")
        XCTAssertEqual(identity.deviceName, "SIM-A")
        XCTAssertEqual(identity.shortID, "38D0B9")
        XCTAssertEqual(identity.displayName, "SIM-A · 38D0B9")
        XCTAssertEqual(identity.relayURL?.absoluteString, "http://127.0.0.1:8787")
        XCTAssertTrue(identity.isSimulatorRelayEnabled)
        XCTAssertTrue(identity.autoStartSession)
    }

    func testArgumentsConfigureWhenEnvironmentAbsent() throws {
        let identity = SonarTestIdentity(
            environment: [:],
            arguments: [
                "--sonar-test-device-id=SIM-B-97D949",
                "--sonar-test-device-name=SIM-B",
                "--sonar-sim-relay-url=http://127.0.0.1:8787",
                "--sonar-autostart-session"
            ],
            vendorIdentifier: "SHOULD-NOT-WIN",
            fallbackDeviceName: "Fallback iPhone"
        )

        XCTAssertEqual(identity.deviceID, "SIM-B-97D949")
        XCTAssertEqual(identity.deviceName, "SIM-B")
        XCTAssertEqual(identity.shortID, "97D949")
        XCTAssertEqual(identity.relayURL?.absoluteString, "http://127.0.0.1:8787")
        XCTAssertTrue(identity.autoStartSession)
    }

    func testFallbackUsesDeviceNameAndVendorIdentifier() throws {
        let identity = SonarTestIdentity(
            environment: [:],
            arguments: [],
            vendorIdentifier: "12345678-ABCD-EF00-9999-000000000000",
            fallbackDeviceName: "iPhone 17 Pro"
        )

        XCTAssertEqual(identity.deviceID, "12345678-ABCD-EF00-9999-000000000000")
        XCTAssertEqual(identity.deviceName, "iPhone 17 Pro")
        XCTAssertEqual(identity.shortID, "123456")
        XCTAssertEqual(identity.displayName, "iPhone 17 Pro · 123456")
        XCTAssertNil(identity.relayURL)
        XCTAssertFalse(identity.isSimulatorRelayEnabled)
        XCTAssertFalse(identity.autoStartSession)
    }

    @MainActor
    func testAppStateExposesLocalTestIdentity() throws {
        let identity = SonarTestIdentity(
            environment: [
                "SONAR_TEST_DEVICE_ID": "SIM-A-38D0B9",
                "SONAR_TEST_DEVICE_NAME": "SIM-A",
                "SONAR_SIM_RELAY_URL": "http://127.0.0.1:8787"
            ],
            arguments: [],
            vendorIdentifier: nil,
            fallbackDeviceName: "Fallback"
        )

        let state = AppState(testIdentity: identity)

        XCTAssertEqual(state.localPeerName, "SIM-A")
        XCTAssertEqual(state.localPeerID, "SIM-A-38D0B9")
        XCTAssertTrue(state.connectionIsSimulated)
        XCTAssertEqual(state.testIdentity.displayName, "SIM-A · 38D0B9")
    }
}
