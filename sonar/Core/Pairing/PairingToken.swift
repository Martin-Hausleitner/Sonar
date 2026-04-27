import Foundation

/// Compact, JSON-encoded handshake payload exchanged via QR code so that a
/// peer can locate this device on the local network and over Bluetooth.
///
/// The token is intentionally minimal — only the fields a remote peer needs to
/// kick off a connection attempt (Bonjour service name, last known host /
/// LAN IP, optional Tailscale IP, and the BLE peripheral identifier).
///
/// Wire format: JSON → UTF-8 bytes → base64url (no padding) — small enough to
/// fit comfortably into a `CIQRCodeGenerator` payload at high error correction.
struct PairingToken: Codable, Equatable {
    /// Schema version. Bump when fields change in an incompatible way.
    /// MVP only accepts `v == 1`.
    static let currentVersion: Int = 1

    let v: Int
    let id: String
    let name: String
    let bonjour: String
    let host: String
    let tsIP: String?
    let ble: String?
    let ts: Int64

    init(
        v: Int = PairingToken.currentVersion,
        id: String,
        name: String,
        bonjour: String = "_sonar._tcp",
        host: String,
        tsIP: String? = nil,
        ble: String? = nil,
        ts: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.v = v
        self.id = id
        self.name = name
        self.bonjour = bonjour
        self.host = host
        self.tsIP = tsIP
        self.ble = ble
        self.ts = ts
    }

    // MARK: - Encode / Decode

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder = JSONDecoder()

    /// Encode to base64url-encoded JSON bytes (no padding) — suitable for QR.
    func encoded() -> Data {
        let json = (try? PairingToken.encoder.encode(self)) ?? Data()
        return Data(PairingToken.base64url(json).utf8)
    }

    /// Convenience string form used directly as the QR payload.
    func encodedString() -> String {
        guard let json = try? PairingToken.encoder.encode(self) else { return "" }
        return PairingToken.base64url(json)
    }

    /// Decode a base64url JSON token. Returns `nil` for malformed input or
    /// unsupported schema versions.
    static func decode(_ payload: String) -> PairingToken? {
        guard let json = base64urlDecode(payload) else { return nil }
        guard let token = try? decoder.decode(PairingToken.self, from: json) else { return nil }
        guard token.v == currentVersion else { return nil }
        return token
    }

    /// Decode raw `Data` (UTF-8 base64url) — convenience overload.
    static func decode(_ data: Data) -> PairingToken? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        return decode(s)
    }

    // MARK: - base64url helpers

    private static func base64url(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var padded = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = padded.count % 4
        if rem > 0 { padded.append(String(repeating: "=", count: 4 - rem)) }
        return Data(base64Encoded: padded)
    }
}
