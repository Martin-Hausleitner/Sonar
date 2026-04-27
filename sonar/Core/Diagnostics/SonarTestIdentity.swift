import Foundation
import UIKit

struct SonarTestIdentity: Equatable, Sendable {
    let deviceID: String
    let deviceName: String
    let shortID: String
    let relayURL: URL?
    let autoStartSession: Bool

    var isSimulatorRelayEnabled: Bool {
        relayURL != nil
    }

    var displayName: String {
        "\(deviceName) · \(shortID)"
    }

    static func current(
        processInfo: ProcessInfo = .processInfo,
        vendorIdentifier: String? = UIDevice.current.identifierForVendor?.uuidString,
        fallbackDeviceName: String = UIDevice.current.name
    ) -> SonarTestIdentity {
        SonarTestIdentity(
            environment: processInfo.environment,
            arguments: processInfo.arguments,
            vendorIdentifier: vendorIdentifier,
            fallbackDeviceName: fallbackDeviceName
        )
    }

    init(
        environment: [String: String],
        arguments: [String],
        vendorIdentifier: String?,
        fallbackDeviceName: String
    ) {
        let argumentReader = ArgumentReader(arguments: arguments)
        let id = environment["SONAR_TEST_DEVICE_ID"]
            ?? argumentReader.value(for: "--sonar-test-device-id", "-SONAR_TEST_DEVICE_ID", "SONAR_TEST_DEVICE_ID")
            ?? environment["SIMULATOR_UDID"]
            ?? vendorIdentifier
            ?? UUID().uuidString

        let name = environment["SONAR_TEST_DEVICE_NAME"]
            ?? argumentReader.value(for: "--sonar-test-device-name", "-SONAR_TEST_DEVICE_NAME", "SONAR_TEST_DEVICE_NAME")
            ?? fallbackDeviceName

        let relay = environment["SONAR_SIM_RELAY_URL"]
            ?? argumentReader.value(for: "--sonar-sim-relay-url", "-SONAR_SIM_RELAY_URL", "SONAR_SIM_RELAY_URL")

        self.deviceID = id
        self.deviceName = name
        self.shortID = SonarTestIdentity.makeShortID(from: id)
        self.relayURL = relay.flatMap(URL.init(string:))
        self.autoStartSession = SonarTestIdentity.isTruthy(environment["SONAR_AUTOSTART_SESSION"])
            || argumentReader.contains("--sonar-autostart-session", "-SONAR_AUTOSTART_SESSION", "SONAR_AUTOSTART_SESSION")
    }

    private static func makeShortID(from id: String) -> String {
        let components = id.split(separator: "-").map(String.init)
        if components.first == "SIM", let last = components.last {
            let cleaned = last.filter { $0.isLetter || $0.isNumber }
            if cleaned.count >= 6 {
                return String(cleaned.prefix(6)).uppercased()
            }
        }

        let cleaned = id.filter { $0.isLetter || $0.isNumber }
        if cleaned.isEmpty { return "DEVICE" }
        return String(cleaned.prefix(6)).uppercased()
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        default:
            return false
        }
    }
}

private struct ArgumentReader {
    let arguments: [String]

    func value(for keys: String...) -> String? {
        for argument in arguments {
            for key in keys {
                let prefix = "\(key)="
                if argument.hasPrefix(prefix) {
                    return String(argument.dropFirst(prefix.count))
                }
            }
        }

        for (index, argument) in arguments.enumerated() {
            guard keys.contains(argument), arguments.indices.contains(index + 1) else { continue }
            return arguments[index + 1]
        }

        return nil
    }

    func contains(_ keys: String...) -> Bool {
        arguments.contains { argument in
            keys.contains(argument) || keys.contains { argument.hasPrefix("\($0)=") }
        }
    }
}
