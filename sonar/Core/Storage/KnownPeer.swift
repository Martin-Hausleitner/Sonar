import Foundation

/// One paired peer in the contact book. Mirrors the connection-relevant
/// fields of `PairingToken` plus bookkeeping (`pairedAt`, `lastSeenAt`) and
/// optional UI overrides (`customName`).
///
/// Identity is `id == PairingToken.id == SonarTestIdentity.deviceID` of the
/// remote device — stable across reinstalls of the *remote* app for as long
/// as the device's identity persists.
struct KnownPeer: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var host: String
    var bonjour: String
    var tsIP: String?
    var tsPort: UInt16?
    var ble: String?
    var pairedAt: Date
    var lastSeenAt: Date?
    /// User-overridden display label; falls back to `name` when `nil`.
    var customName: String?

    var displayName: String {
        if let custom = customName?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            return custom
        }
        return name
    }

    /// Convert back into a `PairingToken` for replay through the existing
    /// transport `addPairingToken` API. `ts` is set to `now` so any TTL check
    /// downstream treats this as a fresh, locally-trusted token.
    func asReplayToken(now: Date = Date()) -> PairingToken {
        PairingToken(
            id: id,
            name: name,
            bonjour: bonjour,
            host: host,
            tsIP: tsIP,
            tsPort: tsPort,
            ble: ble,
            ts: Int64(now.timeIntervalSince1970)
        )
    }
}
