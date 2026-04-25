import Combine
import Foundation
import Network

/// V30 — Big Red Button: kills all cloud / cellular connections immediately.
/// Local BLE + WLAN Multipeer are unaffected (peer-to-peer, no internet).
@MainActor
final class PrivacyMode: ObservableObject {
    static let shared = PrivacyMode()

    @Published private(set) var isActive: Bool = false

    private init() {}

    func activate() {
        isActive = true
        NotificationCenter.default.post(name: .sonarPrivacyModeActivated, object: nil)
    }

    func deactivate() {
        isActive = false
        NotificationCenter.default.post(name: .sonarPrivacyModeDeactivated, object: nil)
    }

    func toggle() {
        isActive ? deactivate() : activate()
    }
}

extension Notification.Name {
    static let sonarPrivacyModeActivated   = Notification.Name("sonar.privacyMode.activated")
    static let sonarPrivacyModeDeactivated = Notification.Name("sonar.privacyMode.deactivated")
}
